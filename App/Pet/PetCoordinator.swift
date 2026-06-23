import AppKit
import FilterCore

/// Per-block pet lifecycle. The pet is a verdict marker with a face —
/// not a desktop pet: nothing is on screen while nothing is flagged, one
/// instance appears beside EACH flagged AI block (peeking out from behind its
/// bracket line), it comments on its own block on hover via a click-through speech
/// bubble, and leaves the moment its block stops being flagged. No idle dock,
/// no screen-corner companion, no presence at all on clean pages. Nothing it
/// draws ever intercepts a click: the pet, the bracket, and the bubble are
/// all pure pass-through annotation (clicking the bubble fades it, but the
/// click still reaches the content underneath).
///
/// Driven entirely by overlay events: `sync` runs on every present/clear diff,
/// `setScrolling` fades the swarm during a scroll burst. No timers of its own
/// beyond the fixed fly-in/out one-shots, no per-frame work. Determinism
/// carries over from the old presenter: behavior and speech are pure
/// functions of (block, pet, state) via PetCoordinator + PetSpeechEngine,
/// and instance adds/removes follow a deterministic order (score, then id).
@MainActor
final class PetCoordinator {

    enum PetState: Equatable {
        case idle
        case entering
        case attached
    }

    struct PetUIState: Equatable {
        var state: PetState
        var blockRect: CGRect
        var blockState: DetectionState
        var petID: String
        var isHovered: Bool
        /// Word count of the marked block — feeds the shared line-height clamp
        /// so the pet anchors to the line's true drawn bottom.
        var words: Int
    }

    /// Everything a pet needs to know about the block it marks. `domain` and
    /// `route` ride along to mirror OverlayManager.Block one-to-one.
    struct FlaggedBlock {
        let id: String
        let rect: CGRect
        let state: DetectionState
        let finalScore: Double
        let words: Int
        let domain: String
        let route: String
        let result: FinalDetectionResult
    }

    // MARK: - Tunables

    /// A page can flag dozens of blocks; more than this many pets is a
    /// swarm, not an annotation. Highest-scoring blocks win, deterministically.
    static let maxInstances = 12
    /// Resting opacity of the pet. Every "shown" alpha funnels through this;
    /// only scroll-hide (0) overrides it. (The bracket line is drawn at 0.60.)
    static let restAlpha: CGFloat = 0.80
    /// Gap between stacked cluster elements (line ↔ text box ↔ pet).
    /// 6.7 = 10 × 0.67 (spacings reduced 33%).
    private static let clusterGap: CGFloat = 6.7
    /// Small horizontal gap so the text box doesn't touch the bracket line in the
    /// default (left-of-bar) placement. 4 ≈ 6 × 0.67 (spacings reduced 33%).
    private static let boxLineSpacing: CGFloat = 4
    /// Gap between the box and the pet in the side-by-side row — tighter than
    /// `clusterGap` so the box sits a little closer to the pet.
    private static let sideBoxGap: CGFloat = 3
    /// Box width assumed when CHOOSING the placement, so the choice is identical
    /// whether or not the box is currently shown (it caps at maxContentWidth).
    private static let assumedBoxWidth = SpeechBubblePanel.maxContentWidth
    /// Let the bracket line finish drawing at full height before the pet
    /// peeks out from behind it — the entrance reads as "the pet emerges from
    /// behind the wall once the wall is there", not "both appear at once".
    /// Matches the bar's expand animation in HighlightPanel.expandLine (0.15s).
    private static let barSettleDelay: TimeInterval = 0.16
    /// How long the peek-out-from-behind-the-line entrance takes.
    private static let emergeDuration: TimeInterval = 0.24
    private static let moveDuration: TimeInterval = 0.35
    private static let moveDeadband: CGFloat = 2

    // MARK: - State

    private struct RenderedPet {
        let panel: PetPanel
        let bubble: SpeechBubblePanel
    }

    private let registry: PetRegistry
    private var activePanels: [String: RenderedPet] = [:]
    
    private var logicalBlocks: [String: FlaggedBlock] = [:]
    private var logicalStates: [String: PetState] = [:]
    private var hoverStates: [String: Bool] = [:]
    private var previousUIState: [String: PetUIState] = [:]
    /// Per-block commentary dismissal level. A first click soft-dismisses
    /// (level 1): hidden for now, but allowed back when the verdict (or pet)
    /// changes. A SECOND click — or a double-click the first time — hard-dismisses
    /// (level 2): gone for good for the life of this flagged block. The level is
    /// history and persists across verdict changes (so the next click escalates);
    /// `softSuppressed` is the level-1 "hidden right now" flag, which a verdict/pet
    /// change clears so a fresh line can resurface. Both are forgotten when the
    /// pet leaves (block unflagged).
    private var dismissLevel: [String: Int] = [:]
    private var softSuppressed: Set<String> = []

    private var transitionWorkItems: [String: DispatchWorkItem] = [:]
    private var scrolling = false

    /// Debug builds append "· 0.87 high" to speech lines.
    var debugMode = false

    /// Current pet edge length in points, driven by the menu bar size slider
    /// via `setPetSize`. Defaults to PetPanel.defaultSize until the setting is
    /// pushed in at launch.
    private(set) var petSize: CGFloat = PetPanel.defaultSize.width
    private var petPanelSize: NSSize { NSSize(width: petSize, height: petSize) }

    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalMouseDownMonitor: Any?
    private var localMouseDownMonitor: Any?

    init(registry: PetRegistry) {
        self.registry = registry

        // Hover drives which bubble (if any) is showing.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleMouseMove(NSEvent.mouseLocation)
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleMouseMove(NSEvent.mouseLocation)
            return event
        }
        // A click that lands on a visible bubble fades it. The bubble is
        // click-through, so the click ALSO passes to the app below: the global
        // monitor only observes (it can't consume), and the local monitor
        // returns the event unchanged. Neither ever blocks the click.
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handleMouseDown(NSEvent.mouseLocation, clickCount: event.clickCount)
        }
        localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handleMouseDown(NSEvent.mouseLocation, clickCount: event.clickCount)
            return event
        }
    }

    deinit {
        for monitor in [globalMouseMonitor, localMouseMonitor,
                        globalMouseDownMonitor, localMouseDownMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }

    // MARK: - Driving API (what integration calls)

    func sync(blocks: [FlaggedBlock]) {
        let wanted = Self.electedBlocks(blocks)

        // Mark missing as idle
        for id in logicalBlocks.keys {
            if wanted[id] == nil {
                logicalStates[id] = .idle
            }
        }

        for block in wanted.values {
            logicalBlocks[block.id] = block
            if logicalStates[block.id] == nil {
                logicalStates[block.id] = .entering
            } else if logicalStates[block.id] == .idle {
                logicalStates[block.id] = .attached
            }
        }
        
        commitUI()
    }

    func setScrolling(_ scrolling: Bool) {
        guard scrolling != self.scrolling else { return }
        self.scrolling = scrolling
        
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let alpha: CGFloat = scrolling ? 0.0 : Self.restAlpha
            for (id, rendered) in activePanels {
                rendered.panel.animator().alphaValue = alpha
                if scrolling {
                    rendered.bubble.hideNow()
                } else {
                    // Re-showing after a scroll snaps the art back to its resting
                    // peeked-out position. A scroll that overlapped an entrance or
                    // exit left a transform animation mid-flight under alpha 0;
                    // pinning identity here means a live pet always reappears
                    // fully peeked out — never stuck behind the wall, never popping
                    // mid-slide. (`commitResting` runs instantly via its own
                    // disabled-actions transaction, so the alpha still fades in.)
                    if let state = logicalStates[id], state != .idle {
                        commitResting(rendered)
                    }
                    if hoverStates[id] == true {
                        revealBubble(for: id)
                    }
                }
            }
        })
    }

    func activePetDidChange() {
        commitUI()
        // A new pet is a new voice, so soft dismissals no longer apply. Hard
        // dismissals (level 2) are deliberate "gone for good", so they stay.
        softSuppressed.removeAll()
        // Re-skin only the bubbles currently open (hovered); the rest stay hidden
        // until hovered again.
        for id in logicalStates.keys where (hoverStates[id] ?? false) && logicalStates[id] != .idle {
            revealBubble(for: id)
        }
    }

    func removeAll() {
        for id in logicalBlocks.keys {
            logicalStates[id] = .idle
        }
        commitUI()
    }

    /// Live-resize every pet to a new edge length (driven by the size slider).
    /// Each panel is re-anchored so it stays correctly placed relative to its
    /// line and box; the art fills the resized panel via its autoresizing mask.
    func setPetSize(_ newSize: CGFloat) {
        let lo = CGFloat(SettingsManager.petSizeRange.lowerBound)
        let hi = CGFloat(SettingsManager.petSizeRange.upperBound)
        let clamped = max(lo, min(hi, newSize))
        guard abs(clamped - petSize) > 0.5 else { return }
        petSize = clamped
        for (id, rendered) in activePanels {
            let origin = anchorOrigin(forBlockID: id)
            rendered.panel.setFrame(NSRect(origin: origin, size: petPanelSize), display: true)
            repositionBubble(for: id)
        }
    }

    // MARK: - Election

    /// Deterministic choice of which blocks get a pet when a page flags
    /// more than `maxInstances`: score descending, then id ascending — the
    /// same page always elects the same blocks.
    static func electedBlocks(_ blocks: [FlaggedBlock]) -> [String: FlaggedBlock] {
        let elected = blocks
            .sorted { lhs, rhs in
                if lhs.finalScore != rhs.finalScore { return lhs.finalScore > rhs.finalScore }
                return lhs.id < rhs.id
            }
            .prefix(maxInstances)
        var result: [String: FlaggedBlock] = [:]
        for block in elected { result[block.id] = block }
        return result
    }

    // MARK: - Centralized UI Rendering

    private func commitUI() {
        var nextUIState: [String: PetUIState] = [:]
        let petID = registry.activePet?.id ?? "none"

        for (id, state) in logicalStates {
            guard let block = logicalBlocks[id] else { continue }
            let hovered = hoverStates[id] ?? false
            nextUIState[id] = PetUIState(state: state, blockRect: block.rect, blockState: block.state, petID: petID, isHovered: hovered, words: block.words)
        }

        applyDiff(previous: previousUIState, next: nextUIState)
        previousUIState = nextUIState
    }

    private func getOrCreateRendered(id: String) -> RenderedPet {
        if let existing = activePanels[id] { return existing }
        let panel = PetPanel(size: petPanelSize)
        let bubble = SpeechBubblePanel()

        let rendered = RenderedPet(panel: panel, bubble: bubble)
        activePanels[id] = rendered
        return rendered
    }

    private func applyDiff(previous: [String: PetUIState], next: [String: PetUIState]) {
        // Exits
        for (id, prev) in previous where next[id] == nil || next[id]?.state == .idle {
            if prev.state != .idle {
                exitPet(id: id)
            }
        }

        // Entries and Updates
        for (id, curr) in next {
            guard curr.state != .idle else { continue }
            let prev = previous[id]
            let rendered = getOrCreateRendered(id: id)

            if prev == nil || prev?.state == .idle {
                if curr.state == .entering {
                    enterPet(id: id, state: curr)
                } else if curr.state == .attached {
                    // Revived from idle: park behind the line and peek back out,
                    // the same wall-emerge as a fresh entrance.
                    transitionWorkItems[id]?.cancel()
                    transitionWorkItems.removeValue(forKey: id)
                    parkBehindWall(rendered)
                    peekOut(rendered, duration: Self.emergeDuration)
                    mountGIF(for: curr.blockState, on: rendered.panel, force: false)
                }
            } else {
                if prev?.petID != curr.petID || prev?.blockState != curr.blockState {
                    mountGIF(for: curr.blockState, on: rendered.panel, force: prev?.petID != curr.petID)
                    // A new verdict (or a new pet's voice) is worth saying again,
                    // so a SOFT-dismissed bubble is allowed back. A hard dismissal
                    // (level 2) is left untouched — it stays gone for good.
                    softSuppressed.remove(id)
                }
            }

            // Movement update
            if curr.state == .attached {
                if prev?.blockRect.origin != curr.blockRect.origin {
                    animatePanel(rendered.panel, to: anchorOrigin(forBlockID: id), blockID: id)
                }
            }

            // Hover state updates. The commentary bubble appears ONLY while the
            // block / bracket / pet is hovered, and retires the moment the
            // pointer leaves. Never by default — and never while the reader has
            // click-dismissed it (revealBubble honors dismissLevel/softSuppressed).
            if prev?.isHovered != curr.isHovered {
                rendered.bubble.isGloballyHovered = curr.isHovered
                if curr.isHovered {
                    revealBubble(for: id)
                } else {
                    rendered.bubble.hideNow()
                }
            }
        }
    }

    private func enterPet(id: String, state: PetUIState) {
        let rendered = getOrCreateRendered(id: id)
        let origin = anchorOrigin(forBlockID: id)

        rendered.panel.setFrame(NSRect(origin: origin, size: petPanelSize), display: false)
        rendered.panel.alphaValue = 0
        rendered.panel.contentView?.wantsLayer = true
        // Start fully hidden BEHIND the line. The panel's right edge sits exactly
        // on the bar, so shoving the art one whole panel-width right parks every
        // pixel past that edge — and the window only paints within its own frame,
        // so the line's x doubles as a hard wall that clips the art away. The pet
        // then peeks out to the LEFT of the line (slides back to identity) once
        // the bar has drawn. Purely horizontal: a downward nudge could dip the
        // art below the line's bottom, which is forbidden.
        parkBehindWall(rendered)
        rendered.panel.orderFrontRegardless()

        mountGIF(for: state.blockState, on: rendered.panel, force: true)
        // No commentary by default — the bubble appears only on hover (see
        // handleMouseMove / applyDiff). The pet peeks out silently.

        // The entrance runs in two scheduled stages, and `transitionWorkItems[id]`
        // always holds the CURRENTLY pending one — so a single
        // `transitionWorkItems[id]?.cancel()` from exit/revive (or a fresh
        // enter) aborts whichever stage is outstanding. Stage 2 (the attach)
        // being a real cancellable work item in that slot is what closes the
        // rapid disappear→reappear race: if the block flickers, the stale attach
        // is cancelled instead of stamping `.attached` onto the next instance.
        //
        // Stage 1 — after the bracket bar finishes expanding, peek out from behind it.
        let emerge = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.logicalStates[id] == .entering else { return }
                self.peekOut(rendered, duration: Self.emergeDuration)
                // Stage 2 — once the peek finishes, settle into .attached. (The
                // peek animation itself isn't cancellable, but exit's fade just
                // overrides the same alpha/transform; only this state change needs
                // to be abortable, and it is.)
                let attach = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.logicalStates[id] == .entering else { return }
                        // The peek has played out; pin the resting transform so an
                        // interrupted emerge can never leave the art stuck behind the
                        // wall. From here on, ".attached" definitionally means the
                        // transform is identity (fully peeked out).
                        if let rendered = self.activePanels[id] { self.commitResting(rendered) }
                        self.logicalStates[id] = .attached
                        self.transitionWorkItems.removeValue(forKey: id)
                        self.commitUI()
                    }
                }
                self.transitionWorkItems[id] = attach
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.emergeDuration, execute: attach)
            }
        }
        transitionWorkItems[id] = emerge
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.barSettleDelay, execute: emerge)
    }

    private func exitPet(id: String) {
        guard let rendered = activePanels[id] else { return }
        rendered.bubble.hideNow()
        transitionWorkItems[id]?.cancel()
        
        let work = DispatchWorkItem { [weak self] in
            self?.activePanels[id]?.panel.orderOut(nil)
            self?.activePanels.removeValue(forKey: id)
            self?.logicalStates.removeValue(forKey: id)
            self?.logicalBlocks.removeValue(forKey: id)
            self?.hoverStates.removeValue(forKey: id)
            self?.previousUIState.removeValue(forKey: id)
            self?.dismissLevel.removeValue(forKey: id)
            self?.softSuppressed.remove(id)
            // Drop our own entry too, or transitionWorkItems grows forever:
            // block ids are page/text-derived and almost never recur.
            self?.transitionWorkItems.removeValue(forKey: id)
        }
        transitionWorkItems[id] = work

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            rendered.panel.animator().alphaValue = 0
            // Duck straight back behind the line — the exact reverse of the
            // peek-out entrance (slide right, no vertical move).
            rendered.panel.imageView.animator().layer?.transform =
                Self.behindWallTransform(width: petSize)
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
    
    private func handleMouseMove(_ location: NSPoint) {
        for (id, rendered) in activePanels {
            // Hover trigger is ONLY the pet and its open bubble — NOT the
            // highlighted text block. The commentary appears when the pointer is on
            // the pet, and stays up while the pointer travels between the pet
            // and the bubble. Hovering the flagged text itself does nothing.
            let isInsidePet = rendered.panel.frame.contains(location)
            let isInsideBubble = rendered.bubble.isVisible && rendered.bubble.frame.contains(location)
            let isInside = isInsidePet || isInsideBubble

            if isInside && !(hoverStates[id] ?? false) {
                hoverStates[id] = true
                commitUI()
            } else if !isInside && (hoverStates[id] ?? false) {
                hoverStates[id] = false
                commitUI()
            }
        }
    }

    /// The exact one-liner the bubble would show for this block — DETERMINISTIC:
    /// the pet's speech template (plus the debug score suffix when debug mode is
    /// on), with a non-empty fallback. Shared by `revealBubble` (what is shown)
    /// and `speechCardHeight` (so the pet can predict the box's height and sit
    /// snug below it before the box is ever shown).
    private func speechLine(for id: String) -> String {
        guard let block = logicalBlocks[id] else { return "..." }
        let pet = registry.activePet
        // No pet (or "none" selected) speaks the AI percentage instead of a
        // template line — the verdict with the character stripped off.
        var line = (pet?.id ?? "none") == "none"
            ? PetRegistry.noneSpeechLine(forAIProbability: block.finalScore)
            : PetSpeechEngine.line(
                blockID: id,
                petID: pet?.id ?? "none",
                stateKey: block.state.rawValue,
                templates: pet?.speechTemplates ?? [:]
            )
        let sourceTag = block.result.calibration_source == "ocr" ? " [OCR]" : " [AX]"
        if debugMode, let spoken = line {
            line = spoken + " · " + String(format: "%.2f %@", block.finalScore, block.state.rawValue) + sourceTag
        } else if debugMode {
            line = String(format: "%.2f %@", block.finalScore, block.state.rawValue) + sourceTag
        }
        if let line, !line.isEmpty { return line }
        return "..." // Fallback so there's always a surface to show
    }

    /// Rendered height of the text box for this block's line — lets the pet
    /// dynamically sit just below the box without waiting for it to be shown.
    ///
    /// Memoized by the line TEXT: `cardSize` depends only on the string (the font
    /// and wrap width are fixed), so the key is the exact input and never goes
    /// stale — a new verdict/pet yields a new line, hence a new key. This keeps a
    /// slider drag (which re-anchors every panel per tick, but never changes the
    /// line) from re-allocating a measuring NSTextField on every tick.
    private var cardHeightByLine: [String: CGFloat] = [:]
    private func speechCardHeight(for id: String) -> CGFloat {
        let line = speechLine(for: id)
        if let h = cardHeightByLine[line] { return h }
        let h = SpeechBubblePanel.cardSize(for: line).height
        cardHeightByLine[line] = h
        return h
    }

    private func revealBubble(for id: String) {
        // Respect a click-dismissal. A hard dismissal (level 2) stays gone for
        // good; a soft one (softSuppressed) stays gone until the verdict/pet
        // changes or the pet is recreated.
        guard dismissLevel[id] != 2, !softSuppressed.contains(id) else { return }
        guard let rendered = activePanels[id], logicalBlocks[id] != nil else { return }
        rendered.bubble.show(speechLine(for: id))
        rendered.bubble.orderFrontRegardless()
        repositionBubble(for: id)
    }

    /// A pass-through click that landed on a bubble's VISIBLE card (the frame
    /// minus its invisible blur margin) fades that bubble away. The click itself
    /// is never consumed — it reaches the content underneath — so this dismisses
    /// the commentary without ever blocking the user.
    ///
    /// Escalating dismissal: the first click soft-dismisses (level 1, comes back
    /// on a verdict change); a second click — or a double-click the first time —
    /// hard-dismisses (level 2, gone for good until the block unflags).
    private func handleMouseDown(_ location: NSPoint, clickCount: Int) {
        let inset = SpeechBubblePanel.blurMargin
        for (id, rendered) in activePanels {
            let level = dismissLevel[id] ?? 0
            // The 2nd event of a double-click can arrive after the 1st already
            // faded the bubble, so once a click has landed (level >= 1) a
            // double-click still counts even when the bubble is no longer visible.
            let eligible = rendered.bubble.isVisible || (clickCount >= 2 && level >= 1)
            guard eligible else { continue }
            let card = rendered.bubble.frame.insetBy(dx: inset, dy: inset)
            guard card.contains(location) else { continue }

            // Hard if this is a double-click, or if the block was already
            // dismissed at least once (this is the "second time").
            let hard = clickCount >= 2 || level >= 1
            dismissLevel[id] = hard ? 2 : 1
            if hard {
                softSuppressed.remove(id)   // suppression now rides on level == 2
            } else {
                softSuppressed.insert(id)
            }
            rendered.bubble.fadeOut()       // idempotent if already fading/hidden
        }

        // Pet clicks pass straight through (the panel is click-through), but
        // we still detect them so a future click-reaction animation can hook in.
        for (id, rendered) in activePanels where rendered.panel.alphaValue > 0.01 {
            if rendered.panel.frame.contains(location) {
                handlePetClick(id: id, clickCount: clickCount)
            }
        }
    }

    /// A pass-through click landed on the pet. Clicking the pet does
    /// nothing today — there is intentionally nothing to "open" — but the click
    /// IS observed here (the panel itself stays `ignoresMouseEvents = true`, so
    /// the click still reaches the content below). This is the hook for a future
    /// click-reaction animation (e.g. a wiggle/wave on poke); wire it in here.
    private func handlePetClick(id: String, clickCount: Int) {
        // TODO(future): trigger a pet click-reaction animation for `id`.
    }

    // MARK: - GIF resolution

    /// state → which animation-profile slot → which gif key. Flag-state
    /// pets only ever track or alert; idle/fallback don't exist here
    /// because a pet without a flagged block doesn't exist either.
    private func gifKey(for state: DetectionState) -> String {
        guard let profile = registry.activePet?.animationProfile else { return "idle" }
        switch state {
        case .high, .veryHigh: return profile.alert
        default:               return profile.track
        }
    }

    private func mountGIF(for state: DetectionState, on panel: PetPanel, force: Bool = false) {
        guard let pet = registry.activePet, pet.id != "none" else {
            panel.imageView.stop()
            panel.imageView.image = nil
            return
        }
        let key = gifKey(for: state)
        if !force, panel.imageView.currentGIFKey == key { return }
        if let data = pet.assets.gifData(key) {
            panel.imageView.play(gifData: data, key: key)
        } else if let png = pet.assets.basePNGData() {
            panel.imageView.showStatic(pngData: png, key: key)
        }
    }



    // MARK: - Wall-peek animation

    /// The transform that hides the art entirely behind the bracket line. The
    /// pet panel's right edge is welded to the bar (anchorOrigin), so shoving
    /// the art one full panel-width to the right pushes every pixel past that
    /// edge; the panel's `masksToBounds` clipping container (PetPanel) then clips
    /// everything past the right edge, so the line's x acts as a solid wall the
    /// art hides behind. Translation is horizontal ONLY — any vertical component
    /// would risk the art dipping below the line's bottom.
    static func behindWallTransform(width: CGFloat) -> CATransform3D {
        CATransform3DMakeTranslation(width, 0, 0)
    }

    /// Instantly park the art behind the line (no animation), so the next
    /// `peekOut` reads as emerging from a standing start. The transform is on the
    /// imageView, which the panel's clipping container hides past the line edge.
    /// Any in-flight transform animation (a still-running exit/peek) is removed
    /// first so it can't keep driving the presentation after this reset.
    private func parkBehindWall(_ rendered: RenderedPet) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rendered.panel.imageView.layer?.removeAnimation(forKey: "transform")
        rendered.panel.imageView.layer?.transform =
            Self.behindWallTransform(width: petSize)
        CATransaction.commit()
    }

    /// Pin the art to its resting, fully-peeked-out position (transform ==
    /// identity) with NO animation — the authoritative "attached & at rest"
    /// commit. Removing any in-flight transform animation first and setting the
    /// model under a disabled-actions transaction guarantees that whenever a
    /// pet is settled, its transform is exactly identity, regardless of how an
    /// interrupted entrance/exit/scroll left the animation. Called at the attach
    /// step and on scroll re-show, so the pet can never be left stuck behind the
    /// wall (invisible) while logically present.
    private func commitResting(_ rendered: RenderedPet) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rendered.panel.imageView.layer?.removeAnimation(forKey: "transform")
        rendered.panel.imageView.layer?.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    /// Peek out to the LEFT of the line: slide the art back to identity. The
    /// window clips whatever is still past the line, so the pet emerges from
    /// behind the wall edge.
    ///
    /// Alpha is set INSTANTLY, not faded: while parked behind the wall the art
    /// is fully clipped (invisible even at full opacity), so letting the wall
    /// edge alone do the reveal makes the pet emerge solid — like a real object
    /// coming out from behind the line, not a translucent fade-in. The only
    /// alpha case that matters is the scroll-hide (0), honored here.
    private func peekOut(_ rendered: RenderedPet, duration: TimeInterval) {
        rendered.panel.alphaValue = self.scrolling ? 0.0 : Self.restAlpha
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            rendered.panel.imageView.animator().layer?.transform = CATransform3DIdentity
        }
    }

    // MARK: - Positioning (same anchor math the single pet used)

    /// Where the text box + pet cluster sits, in priority order:
    ///   .sideBySide — preferred: a horizontal ROW to the LEFT of the bar —
    ///                 [box] [pet] |line|. Used whenever the box AND pet
    ///                 both fit side-by-side left of the bar.
    ///   .left       — not enough width for the row, but room for the box alone:
    ///                 stack to the LEFT of the bar, box's top on the bar top,
    ///                 pet underneath it.
    ///   .below      — bar too far left for either → drop BELOW the line, left edge
    ///                 ON the bar (nothing left of the line). Pet just below the
    ///                 line, box UNDER the pet.
    ///   .above      — also no room below (bar low + left) → rise ABOVE the line,
    ///                 left edge ON the bar. Pet just above the line, box above it.
    /// The always-visible pet stays nearest the line; the hover-only box sits on
    /// its far side, so the pet's position never depends on whether the box shows.
    private enum Placement { case sideBySide, left, below, above }

    /// Which placement to use, from geometry + the (predicted) box height so the
    /// pet and its box always agree.
    private func placement(rect: CGRect, words: Int, boxHeight: CGFloat, vf: CGRect) -> Placement {
        let barX = HighlightPanel.barX(textMinX: rect.minX)
        // 1. Side-by-side row: room for [box][gap][pet] all LEFT of the bar.
        if barX - petSize - Self.sideBoxGap - Self.assumedBoxWidth >= vf.minX { return .sideBySide }
        // 2. Vertical stack: room for just the box (the wider element) left of the bar.
        if barX - Self.assumedBoxWidth >= vf.minX { return .left }
        // 3/4. Too far left → below the line if the stacked pet+box clears the
        // screen bottom, otherwise above it.
        let lineBottom = rect.maxY - HighlightPanel.drawnLineHeight(rectHeight: rect.height, words: words)
        let stackHeight = Self.clusterGap + petSize + Self.clusterGap + boxHeight
        return (lineBottom - stackHeight >= vf.minY) ? .below : .above
    }

    private func clampX(_ x: CGFloat, width: CGFloat, in vf: CGRect) -> CGFloat {
        min(max(x, vf.minX), vf.maxX - width)
    }
    private func clampY(_ y: CGFloat, height: CGFloat, in vf: CGRect) -> CGFloat {
        min(max(y, vf.minY), vf.maxY - height)
    }

    /// Origin (bottom-left) of the pet panel for a block, always fully
    /// on-screen. Looks the block up and uses its DETERMINISTIC box height, so
    /// the pet sits dynamically just below the box (and the result is stable
    /// whether or not the hover-only box is currently shown).
    private func anchorOrigin(forBlockID id: String) -> CGPoint {
        guard let block = logicalBlocks[id] else { return .zero }
        return anchorOrigin(rect: block.rect, words: block.words, boxHeight: speechCardHeight(for: id))
    }

    /// Origin (bottom-left) of the pet panel, always fully on-screen.
    private func anchorOrigin(rect: CGRect, words: Int, boxHeight: CGFloat) -> CGPoint {
        let size = petPanelSize
        let vf = currentScreen(for: rect).visibleFrame
        let barX = HighlightPanel.barX(textMinX: rect.minX)
        let lineTop = rect.maxY
        let lineBottom = rect.maxY - HighlightPanel.drawnLineHeight(rectHeight: rect.height, words: words)
        let g = Self.clusterGap

        switch placement(rect: rect, words: words, boxHeight: boxHeight, vf: vf) {
        case .sideBySide:
            // A row to the left of the bar: pet's right edge on the bar, top
            // aligned with the bar top. The box sits to its LEFT (repositionBubble),
            // so the pet's position is independent of the box height.
            let x = clampX(barX - size.width, width: size.width, in: vf)
            let y = clampY(lineTop - size.height, height: size.height, in: vf)
            return CGPoint(x: x, y: y)
        case .left:
            // Left of the bar (right edge on it). The box's top is pinned to the
            // bar top and grows DOWN; the pet sits dynamically one gap below the
            // box's bottom (so the spacing is exact for a 1-line or a 2-line quip).
            let x = clampX(barX - size.width, width: size.width, in: vf)
            let y = clampY(lineTop - boxHeight - g - size.height, height: size.height, in: vf)
            return CGPoint(x: x, y: y)
        case .below:
            // Below the line, left edge ON the bar. The always-visible pet sits
            // just below the line; the hover box drops UNDERNEATH it.
            let x = clampX(barX, width: size.width, in: vf)
            let y = clampY(lineBottom - g - size.height, height: size.height, in: vf)
            return CGPoint(x: x, y: y)
        case .above:
            // Above the line, left edge ON the bar; pet just above the line,
            // box stacked above it.
            let x = clampX(barX, width: size.width, in: vf)
            let y = clampY(lineTop + g, height: size.height, in: vf)
            return CGPoint(x: x, y: y)
        }
    }

    private func currentScreen(for rect: CGRect?) -> NSScreen {
        if let rect {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            if let s = NSScreen.screens.first(where: { $0.frame.contains(center) }) { return s }
        }
        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }

    // MARK: - Movement

    /// Core Animation glide (easeInEaseOut, fixed 0.35s), bubble dragged in
    /// lockstep. Tiny deltas snap — sub-2pt moves would just be jitter.
    private func animatePanel(_ panel: PetPanel, to origin: CGPoint, blockID: String) {
        let current = panel.frame.origin
        let target = NSRect(origin: origin, size: petPanelSize)
        if abs(current.x - origin.x) < Self.moveDeadband,
           abs(current.y - origin.y) < Self.moveDeadband {
            panel.setFrame(target, display: false)
            repositionBubble(for: blockID)
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.moveDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.repositionBubble(for: blockID) }
        }
        repositionBubble(for: blockID, petFrame: target)
    }

    /// The text box sits on the pet's FAR side from the line, per placement:
    /// to its LEFT in `.sideBySide`, ABOVE it in `.left`/`.above`, UNDER it in
    /// `.below`. Clamped fully on-screen. The box window carries `blur` points of
    /// invisible margin on every side, so the window origin is the visible-card
    /// target backed out by `blur`.
    private func repositionBubble(for blockID: String, petFrame: NSRect? = nil) {
        guard let rendered = activePanels[blockID], rendered.bubble.isVisible,
              let block = logicalBlocks[blockID] else { return }
        let vf = currentScreen(for: block.rect).visibleFrame
        let blur = SpeechBubblePanel.blurMargin
        // Visible card size = window size minus the invisible blur margin all round.
        let winSize = rendered.bubble.frame.size
        let cardW = winSize.width - blur * 2
        let cardH = winSize.height - blur * 2
        let g = Self.clusterGap

        // Anchor to the pet's live target while gliding, else its resting origin.
        let petOrigin = petFrame?.origin ?? anchorOrigin(forBlockID: blockID)
        let petFrame = NSRect(origin: petOrigin, size: petPanelSize)
        let lineTop = block.rect.maxY

        let cardLeft: CGFloat
        let cardTop: CGFloat   // y of the visible card's TOP edge
        switch placement(rect: block.rect, words: block.words, boxHeight: cardH, vf: vf) {
        case .sideBySide:
            cardLeft = petFrame.minX - Self.sideBoxGap - cardW  // snug to the LEFT of the pet
            cardTop = lineTop                             // top aligned with the bar top
        case .left:
            cardLeft = petFrame.maxX - cardW - Self.boxLineSpacing  // spaced a little off the bar
            cardTop = lineTop                            // top on the bar top; grows down, pet sits below
        case .below:
            cardLeft = petFrame.minX                  // left edge on the bar (== pet left edge)
            cardTop = petFrame.minY - g               // box drops one gap UNDER the pet
        case .above:
            cardLeft = petFrame.minX                  // left edge on the bar
            cardTop = petFrame.maxY + g + cardH       // stacked directly above the pet
        }

        let x = clampX(cardLeft, width: cardW, in: vf)
        let y = clampY(cardTop - cardH, height: cardH, in: vf)
        rendered.bubble.setFrameOrigin(CGPoint(x: x - blur, y: y - blur))
    }


}
