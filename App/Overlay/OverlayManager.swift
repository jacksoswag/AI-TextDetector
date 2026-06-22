import AppKit
import ApplicationServices
import FilterCore

/// Owns every highlight annotation on screen. Layers are keyed per source:
///
///   "ax:<pid>" — one layer per scanned app, anchored to live AX elements and
///     z-ordered directly above their content window, so a highlight on a
///     background window correctly hides beneath whatever covers it.
///   "ocr" — whole-screen OCR layer at floating level: it represents the
///     topmost visible pixels, so floating is correct.
///
/// AUTHORITATIVE UPDATE PATHS (the stability contract):
///   `present(...)` creates, restyles, and destroys panels: it diffs the incoming
///   blocks against what is on screen and applies the difference in one pass. The
///   5 Hz `cullTimer` additionally MOVES live panels (see below). Those are the
///   only two writers; there is no per-frame tracker beyond the 5 Hz cull.
///
///   A highlight is valid ONLY for the text state that produced it, but its
///   POSITION is allowed to follow the content. When an anchor rigidly translates
///   (same size, same text — a scroll or reflow that just shifts the block), the
///   cull slides the panel to the anchor's live frame in place: the bracket stays
///   glued to its text instead of hiding and waiting for a rescan. When position
///   becomes untrackable instead (anchor gone, or moved AND reflowed) the layer is
///   invalidated (hidden) immediately and the next settled scan re-presents it.
///   Highlights therefore follow their content, or are absent — never stale-wrong.
///
///   This is PARTLY event-driven: `windowEventOccurred(pid:)` fires the instant an
///   app emits an AX window-move/resize or text-value-changed notification. But
///   some apps reposition on-screen text WITHOUT emitting one (canvas/Metal
///   renderers like Google Docs, apps that update AX geometry asynchronously). The
///   5 Hz cull is the backstop: it re-reads each anchored panel and follows a
///   rigid move, or invalidates on a vanished/non-rigid one.
///
/// Panels are CONTENT-keyed: identity is the block's text hash, not its
/// position. A rescan that returns the same text repositions the existing
/// panel in place; changed text yields a new key, so the old panel is removed
/// by the diff and a new one created — never a stale annotation left behind.
@MainActor
final class OverlayManager {

    static let ocrKey = "ocr"
    static func axKey(_ pid: pid_t) -> String { "ax:\(pid)" }

    struct Block {
        let id: String
        let rect: CGRect
        let state: DetectionState
        let finalScore: Double
        let words: Int
        let anchor: AXUIElement?
        let domain: String
        let route: String
        let result: FinalDetectionResult
        /// The block's full source text as acquired from the accessibility tree or OCR.
        let text: String
    }

    var requestRescan: ((TimeInterval) -> Void)?
    var onActiveBlocksChanged: (([Block]) -> Void)?

    private struct Tracked {
        var state: DetectionState
        var anchor: AXUIElement?
        var rect: CGRect
        var finalScore: Double
        var words: Int
        var route: String
        var result: FinalDetectionResult
        /// The anchor element's live AX frame (Cocoa space) captured at paint
        /// time, used by the 5 Hz drift-check to detect async on-screen moves
        /// that emit no AX notification. nil for OCR blocks (no anchor).
        var anchorRefRect: CGRect? = nil
        /// The anchor's text "edit signature" captured at paint time — its
        /// character count where the element exposes one, else a hash of its value
        /// string (see `editSignature`). The drift cull re-reads it to detect an
        /// in-place text edit (e.g. a Google Docs change) that moves nothing and
        /// fires no AX notification. nil for OCR (no anchor).
        var anchorRefEditSig: Int? = nil
        /// A short, normalized prefix of the block's first line (see `leadKey`).
        /// The cull's content-presence probe hit-tests this panel's rect and
        /// confirms this signature is still the text rendered there — catching
        /// removal/replacement that leaves the anchor's frame untouched and emits
        /// no AX notification (a reused list row, a stable container's contents).
        var leadText: String = ""
    }

    /// Lowercase, keep letters/digits, collapse every other run to one space,
    /// drop leading space, cap at `max`. Both the stored lead signature and the
    /// probed on-screen value pass through this so they compare on equal footing.
    private static func normalize(_ s: String, max: Int) -> String {
        var out = ""
        var pendingSpace = false
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber {
                if pendingSpace, !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(ch)
                if out.count >= max { break }
            } else {
                pendingSpace = true
            }
        }
        return out
    }

    /// A short, normalized signature of a block's leading text, capped so it
    /// stays inside the block's first rendered line — short enough that a
    /// still-present block never fails the probe, long enough to be distinctive.
    private static let leadChars = 12
    private static func leadKey(_ text: String) -> String { normalize(text, max: leadChars) }

    /// Is `lead`'s text still rendered at `rect` in `pid`'s app? Hit-tests the
    /// first line's interior and reads whatever element sits there. Returns true
    /// when the lead still matches OR when presence can't be read cheaply (no
    /// element, no readable value, or a large editable we won't whole-read) —
    /// indeterminate must never be treated as "gone". Only a positive mismatch
    /// returns false. The probe is scoped to the owner app, so our own overlay
    /// panels are invisible to it.
    private static func textPresent(rect: CGRect, pid: pid_t, lead: String, primaryHeight: CGFloat) -> Bool {
        // Cocoa rect (bottom-left) → AX point (top-left), nudged inside line 1.
        let axPoint = CGPoint(x: rect.minX + 6, y: primaryHeight - (rect.maxY - 8))
        guard let hit = AX.elementAt(pid: pid, axPoint: axPoint) else { return true }
        if let chars = AX.int(hit, kAXNumberOfCharactersAttribute as String), chars > 4000 {
            return true
        }
        guard let raw = AX.valueText(hit), !raw.isEmpty else { return true }
        let v = normalize(raw, max: 160)
        // contains(): paragraph/line elements expose the lead at their start.
        // hasPrefix(): apps that expose per-word AXStaticText return a fragment
        // shorter than the lead — a real prefix of it still confirms presence.
        // Require a 4-char fragment so a common 3-letter word (the/and/for) that
        // happens to prefix the lead can't spuriously confirm a different block.
        return v.contains(lead) || (lead.count >= 4 && v.count >= 4 && lead.hasPrefix(v))
    }

    /// A cheap, change-detecting signature of an anchor's text. Character count
    /// (one Int read — cheap even for a whole document) where the element exposes
    /// it, else a hash of the value string (anchors without a char count are short
    /// static-text fragments, so hashing those is cheap too). Captured at paint
    /// and re-read in the cull; identical input ⇒ identical signature within a run.
    private static func editSignature(_ anchor: AXUIElement) -> Int? {
        if let chars = AX.int(anchor, kAXNumberOfCharactersAttribute as String) { return chars }
        return AX.string(anchor, kAXValueAttribute as String)?.hashValue
    }

    private struct LayerState {
        var panels: [String: Tracked] = [:]
        var domain = ""
        var ownerPID: pid_t = 0
        var isOCR = false
        var windowNumber: Int?
        /// The focused window's AX title captured at paint time. A browser tab
        /// switch / navigation retitles the window without moving or destroying
        /// the old tab's AX elements, so the frame-drift check can't see it; the
        /// 5 Hz cull compares this title to detect it.
        var windowTitle: String?
    }

    private var layers: [String: LayerState] = [:]
    private var activePanels: [String: HighlightPanel] = [:]
    
    struct OverlayUIState: Equatable {
        var id: String
        var rect: CGRect
        var state: DetectionState
        var words: Int
        var floating: Bool
        var windowNumber: Int?
    }
    private var previousUIState: [String: OverlayUIState] = [:]

    /// Consecutive content-probe misses per panel (global id). The cull clears a
    /// layer only after a panel misses `contentMissLimit` ticks in a row, so a
    /// single transient AX read can never tear down a correct highlight. Pruned in
    /// `commitUI` to the panels currently on screen.
    private var contentMissStreak: [String: Int] = [:]
    private static let contentMissLimit = 2

    private static let maxPanelsPerLayer = 30
    private static let maxAXLayers = 6

    var hasAnyPanels: Bool {
        layers.contains { !$0.value.panels.isEmpty }
    }

    // MARK: - Presentation (Observation)

    func present(layerKey: String, blocks: [Block], domain: String, ownerPID: pid_t) {
        // Drop any result that resolved mid-scroll. Its rects were captured
        // before the scroll moved the content, so painting them now would flash
        // the highlights at stale positions (the classic "old frame reappears").
        // The scroll-settle scan re-presents at correct coordinates.
        guard !scrolling else { return }

        // Never paint a background app's highlights. Evaluation is async, so by
        // the time a result resolves the user may have switched away from the app
        // it describes — and painting it now would float that app's brackets on
        // top of whatever is frontmost. (Our own app frontmost just means the
        // menu is open; that's fine, so keep showing the underlying app.)
        if let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           frontPID != ownerPID,
           frontPID != ProcessInfo.processInfo.processIdentifier {
            return
        }

        let isOCR = layerKey == Self.ocrKey
        if !isOCR, layers[layerKey] == nil,
           layers.filter({ !$0.value.isOCR && !$0.value.panels.isEmpty }).count >= Self.maxAXLayers {
            return
        }

        var state = layers[layerKey] ?? LayerState()
        state.domain = domain
        state.ownerPID = ownerPID
        state.isOCR = isOCR
        if !isOCR, let firstRect = blocks.first?.rect {
            state.windowNumber = WindowResolver.windowNumber(pid: ownerPID, containing: firstRect)
        }
        if !isOCR {
            state.windowTitle = Self.focusedWindowTitle(pid: ownerPID)
        }

        var incoming: [String: Block] = [:]
        for block in blocks.prefix(Self.maxPanelsPerLayer) {
            guard block.rect.width > 30, block.rect.height > 12 else { continue }
            guard block.state == .suspicious || block.state == .high || block.state == .veryHigh else { continue }
            incoming[block.id] = block
        }

        var updatedPanels: [String: Tracked] = [:]
        for (key, block) in incoming {
            updatedPanels[key] = Tracked(
                state: block.state,
                anchor: block.anchor,
                rect: block.rect,
                finalScore: block.finalScore,
                words: block.words,
                route: block.route,
                result: block.result,
                anchorRefRect: block.anchor.flatMap { AX.frame($0)?.axToCocoa },
                anchorRefEditSig: block.anchor.flatMap { Self.editSignature($0) },
                leadText: Self.leadKey(block.text)
            )
        }

        state.panels = updatedPanels
        layers[layerKey] = state
        commitUI()
    }

    // MARK: - Central Reconciliation Loop

    private func commitUI() {
        var nextUIState: [String: OverlayUIState] = [:]
        for (layerKey, layerState) in layers {
            let floating = layerState.isOCR
            let winNum = layerState.windowNumber
            for (key, tracked) in layerState.panels {
                let globalID = "\(layerKey)::\(key)"
                nextUIState[globalID] = OverlayUIState(id: globalID, rect: tracked.rect, state: tracked.state, words: tracked.words, floating: floating, windowNumber: winNum)
            }
        }
        
        applyOverlayDiff(previous: previousUIState, next: nextUIState)
        previousUIState = nextUIState

        // Drop miss-streaks for panels that are no longer on screen.
        contentMissStreak = contentMissStreak.filter { nextUIState[$0.key] != nil }

        // Pets ride the active-block union, so they must be re-fanned on EVERY
        // reconciliation — not just `present`. Any clear path (the cull,
        // app-switch, window event) removes panels here without a following
        // present(); fanning out from this single point is what makes a pet leave
        // in lockstep with its highlight instead of lingering after it.
        //
        // The one exception is a scroll burst: it clears panels transiently and
        // the settle scan re-presents them, while pets are merely faded (not
        // retired) for the duration. Re-fanning the empty set here would make
        // every scroll flush and replay the pets, so skip it — the settle scan's
        // present() re-notifies with the correct union.
        if !scrolling { notifyActiveBlocks() }
    }

    private func applyOverlayDiff(previous: [String: OverlayUIState], next: [String: OverlayUIState]) {
        for (id, _) in previous where next[id] == nil {
            if let panel = activePanels[id] {
                panel.dismiss()
                activePanels.removeValue(forKey: id)
            }
        }
        for (id, curr) in next {
            let prev = previous[id]
            let panel = activePanels[id] ?? HighlightPanel(rect: curr.rect, state: curr.state, words: curr.words, floating: curr.floating)
            activePanels[id] = panel

            if prev == nil {
                panel.update(rect: curr.rect, state: curr.state, words: curr.words)
                panel.show(isScrolling: self.scrolling)
                panel.orderAbove(windowNumber: curr.windowNumber)
            } else {
                if prev?.rect != curr.rect || prev?.state != curr.state || prev?.words != curr.words {
                    panel.update(rect: curr.rect, state: curr.state, words: curr.words)
                }
                if prev?.windowNumber != curr.windowNumber {
                    panel.orderAbove(windowNumber: curr.windowNumber)
                }
            }
        }
    }

    private var scrolling = false

    /// Scroll start hides every highlight instantly; scroll end leaves them
    /// hidden until the settle scan re-presents them at correct coordinates.
    /// Holding `scrolling == true` also makes `present` a no-op, so an ML
    /// result that resolves mid-scroll can't paint a stale frame.
    func setScrolling(_ scrolling: Bool) {
        guard self.scrolling != scrolling else { return }
        self.scrolling = scrolling

        if scrolling {
            clearAll()
        }
    }

    // MARK: - 5 Hz cull pass

    private var cullTimer: Timer?
    /// Global key-event monitor used ONLY to learn that *a* key was pressed and
    /// when — never its content. Drives the typing heartbeat below.
    private var keyMonitor: Any?
    private var lastKeyDownAt: Date?
    private var heartbeatTicks = 0
    /// While a key was pressed within this window, the user is "actively typing".
    private static let typingWindow: TimeInterval = 2.5
    /// Re-acquire every this many 0.2 s ticks while actively typing (≈0.6 s).
    private static let heartbeatTicksInterval = 3
    /// Settle delay before the heartbeat's re-acquire. Canvas a11y renderers
    /// (Google Docs) update AX element positions LAZILY — they sit at stale /
    /// transitional coordinates for ~200-500 ms after a reflow (the same reason
    /// the scroll path waits 750 ms). Reading at 0.0 would re-capture the stale Y;
    /// this lets the frames transition first. Invisible while typing.
    private static let heartbeatSettle: TimeInterval = 0.4

    /// Set by the orchestrator: true while an acquisition scan is mid-flight. The
    /// heartbeat skips when one is already running so its re-acquires don't stack
    /// overlapping (uncancellable) AX tree walks on a heavy page.
    var isScanInProgress: (() -> Bool)?

    /// Start a 5 Hz timer that runs `cullPass()`:
    ///   • a scroll safety net that force-clears all panels while scrolling
    ///     (catches non-wheel scrolls such as arrow-key and scrollbar-drag that
    ///     the global NSEvent monitor never sees), and
    ///   • an anchor-drift cull that re-reads each non-OCR layer's anchored panels
    ///     and invalidates the layer if an anchor vanished (text removed), moved or
    ///     resized (reflow / streaming text), or its text value changed (an
    ///     in-place edit) — so stale highlights left by apps that update content
    ///     WITHOUT emitting an AX notification (the canvas a11y layer in Google
    ///     Docs, chat output) are culled within one 200 ms tick.
    func startCulling() {
        stopCulling()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.cullPass() }
        }
        RunLoop.main.add(t, forMode: .common)
        cullTimer = t
        // Learn WHEN the user is typing (timing only — the event's characters are
        // never read), so the cull's heartbeat re-acquires while a doc/chat is
        // being edited. Global monitor: the edited app is frontmost, not us.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastKeyDownAt = Date() }
        }
    }

    func stopCulling() {
        cullTimer?.invalidate()
        cullTimer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        lastKeyDownAt = nil
        heartbeatTicks = 0
    }

    private func cullPass() {
        // (a) Scroll safety net for non-wheel scrolls (scrollbar drag, arrow
        // keys) that never reach the NSEvent.scrollWheel monitor. For wheel
        // scroll the synchronous NSEvent handler already called clearAll()
        // before any queued Task can run, so this path is rarely needed there.
        if scrolling {
            if hasAnyPanels { clearAll() }
            return
        }

        // (b) Nothing on screen → nothing to drift-check.
        guard hasAnyPanels else { return }

        // (c) Anchor-drift cull. For each non-OCR layer, re-read its anchored
        // panels and react to any change the app made WITHOUT emitting an AX
        // notification (the canvas a11y layer in Google Docs, chat output). Two
        // outcomes, so we never show a positionally-WRONG highlight yet don't
        // blink on in-place edits:
        //   • rigid translation (anchor moved, same size + text) → the bracket is
        //     simply in a new place → FOLLOW it: slide the panel to the live frame
        //     in place, no clear and no rescan (the cheap, smooth path that keeps
        //     a highlight glued to content that scrolls or reflows rigidly).
        //   • geometry stale (anchor gone, or moved AND reflowed) → its coordinates
        //     are wrong and untrackable → clear the layer NOW, then rescan.
        //   • content drift (same origin, but the element resized or its text
        //     changed) → still positionally correct → DON'T clear; just rescan so
        //     present() updates/removes it once the change settles. Keeps brackets
        //     steady through streaming/typing instead of tearing them down.
        // Collect first, act after the loop — invalidate()/commitUI() and the panel
        // moves must not mutate `layers` mid-iteration. (contentMissStreak is a
        // separate dict, so the probe below may update it inside the loop.)
        var staleKeys: [String] = []
        var contentRescanNeeded = false
        // layerKey → panels that rigidly translated this tick (slide + repaint).
        var movesByLayer: [String: [(key: String, rect: CGRect, ref: CGRect)]] = [:]
        // Gating for the (c3) content probe, evaluated once: only the FRONTMOST
        // app's layers, and only while the user is neither typing nor mid-scan, so
        // we never hit-test a covered background app or read transient reflow
        // frames. typingNow is reused by the heartbeat below.
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let typingNow = lastKeyDownAt.map { Date().timeIntervalSince($0) < Self.typingWindow } ?? false
        let probeOK = !typingNow && !(isScanInProgress?() ?? false)
        let primaryHeight = NSScreen.primaryHeight
        for (layerKey, layerState) in layers where !layerState.isOCR {
            // (c1) Tab switch / navigation. A browser retitles its window when
            // the active tab changes, but it KEEPS the background tab's AX
            // elements alive at unchanged frames — so the frame-drift check below
            // can't see it and the old highlights float over the new tab. Compare
            // the focused window's title to the one captured at paint time; a
            // confirmed change means the page under these highlights is gone.
            if let was = layerState.windowTitle,
               let now = Self.focusedWindowTitle(pid: layerState.ownerPID),
               now != was {
                staleKeys.append(layerKey)
                continue
            }

            // (c2) Re-read each anchored panel. The AX text read is short-
            // circuited: it runs only when the frame is fully stable (a move or
            // resize already proves drift), and uses a cheap char-count signature
            // where possible (editSignature), so a big editable doesn't pay a
            // whole-value read every tick. Break out the instant we know the
            // layer's position is wrong; content drift only needs a rescan.
            var layerGeomStale = false
            var layerContentStale = false
            var moves: [(key: String, rect: CGRect, ref: CGRect)] = []
            for (key, tracked) in layerState.panels {
                guard let anchor = tracked.anchor, let ref = tracked.anchorRefRect else { continue }
                guard let live = AX.frame(anchor)?.axToCocoa else {
                    layerGeomStale = true; break               // anchor gone → clear + rescan
                }
                let resized = abs(live.width - ref.width) > 4 || abs(live.height - ref.height) > 4
                let dx = live.minX - ref.minX, dy = live.minY - ref.minY
                let movedOrigin = abs(dx) > 4 || abs(dy) > 4
                if resized {
                    // A reflow that ALSO shifted the origin is no longer a rigid
                    // translation, so the old coordinates are wrong → clear now.
                    if movedOrigin { layerGeomStale = true; break }
                    layerContentStale = true; continue         // grew/shrank in place → rescan only
                }
                if movedOrigin {
                    // (c2a) Rigid translation, same size and text: FOLLOW the anchor
                    // in place rather than hiding and waiting for a rescan. Slides
                    // the bracket to its live position within one tick, no re-score.
                    moves.append((key, tracked.rect.offsetBy(dx: dx, dy: dy), live))
                    continue
                }
                if Self.editSignature(anchor) != tracked.anchorRefEditSig {
                    layerContentStale = true                   // in-place text edit → rescan only
                }
            }

            // (c3) Content-presence probe — the position check (c2) cannot do:
            // it validates the ANCHOR element, not that the bracketed TEXT is
            // still rendered at the rect. Hit-test each panel's first line in the
            // owner app's AX tree and confirm its lead signature is still there.
            // Catches removal/replacement that leaves the anchor frame untouched
            // and fires no AX notification (a reused row, a stable container whose
            // contents changed, an anchorless block). Debounced by contentMissLimit
            // so one stray read never tears down a correct highlight. Skipped while
            // the layer is following a move (its rects are mid-update this tick).
            if !layerGeomStale, moves.isEmpty, probeOK, layerState.ownerPID == frontPID,
               contentProbeFindsStale(layerKey: layerKey, layerState: layerState, primaryHeight: primaryHeight) {
                layerGeomStale = true
            }

            if layerGeomStale { staleKeys.append(layerKey) }
            else {
                if !moves.isEmpty { movesByLayer[layerKey] = moves }
                if layerContentStale { contentRescanNeeded = true }
            }
        }

        // Apply the rigid-translation follows: slide each moved panel to its live
        // frame and repaint in place. Pets ride the same commitUI fan-out, so a
        // bracket and its pet move together within the tick — no clear, no rescan.
        if !movesByLayer.isEmpty {
            for (layerKey, moves) in movesByLayer {
                guard var st = layers[layerKey] else { continue }
                for m in moves {
                    guard var t = st.panels[m.key] else { continue }
                    t.rect = m.rect
                    t.anchorRefRect = m.ref
                    st.panels[m.key] = t
                }
                layers[layerKey] = st
            }
            commitUI()
        }

        // Geometry-stale layers are cleared now (their coordinates are wrong);
        // content-stale layers stay on screen (still positionally correct).
        let driftRescan = !staleKeys.isEmpty || contentRescanNeeded
        for key in staleKeys {
            invalidate(layerKey: key)
        }

        // (d) Typing heartbeat. The anchor checks above are cheap but BLIND to
        // apps that reflow content without updating their AX element frames — the
        // canvas a11y layer in Google Docs being the worst offender (add a line
        // above a highlighted block and the text moves but its anchor frame does
        // not). So while the user is actively typing (any app), force a low-rate
        // re-acquire: a fresh scan reads the CURRENT positions and present()
        // repositions/removes panels. The detection cache makes the re-score
        // nearly free and the AX walk runs off the main thread. Gated on recent
        // typing (`typingNow`, computed once above), so passive reading pays
        // nothing.
        heartbeatTicks = typingNow ? heartbeatTicks + 1 : 0
        // Skip the heartbeat while a scan is already running — its walk will
        // deliver fresh positions anyway, and stacking walks just burns battery.
        let heartbeatDue = typingNow
            && heartbeatTicks >= Self.heartbeatTicksInterval
            && !(isScanInProgress?() ?? false)
        if heartbeatDue { heartbeatTicks = 0 }

        guard driftRescan || heartbeatDue else { return }
        // One coalesced rescan re-presents/updates — the same path the
        // event-driven `windowEventOccurred` uses. The heartbeat waits a settle
        // delay so lazy canvas a11y (Google Docs) reports its POST-reflow frames.
        requestRescan?(driftRescan ? 0.25 : Self.heartbeatSettle)
    }

    /// Probe every panel of `layerState` for content presence and update its
    /// consecutive-miss streak. Returns true once any panel has missed
    /// `contentMissLimit` ticks in a row — its bracketed text is gone from the
    /// rect, so the layer must be cleared and rescanned. A panel whose text is
    /// confirmed present, or can't be read, resets to zero (indeterminate ≠ gone).
    private func contentProbeFindsStale(layerKey: String, layerState: LayerState, primaryHeight: CGFloat) -> Bool {
        for (key, tracked) in layerState.panels {
            guard !tracked.leadText.isEmpty else { continue }
            let globalID = "\(layerKey)::\(key)"
            if Self.textPresent(rect: tracked.rect, pid: layerState.ownerPID,
                                lead: tracked.leadText, primaryHeight: primaryHeight) {
                contentMissStreak[globalID] = 0
            } else {
                let n = (contentMissStreak[globalID] ?? 0) + 1
                contentMissStreak[globalID] = n
                // The whole layer is invalidated on the first confirmed miss, so
                // stop probing — no point paying more AX hit-tests this tick.
                if n >= Self.contentMissLimit { return true }
            }
        }
        return false
    }

    /// The focused window's AX title for `pid` — the browser tab-switch /
    /// navigation signal. A tab switch retitles the window without moving or
    /// destroying the old tab's AX elements, so this is the only cheap thing the
    /// cull pass can compare to notice it.
    private static func focusedWindowTitle(pid: pid_t) -> String? {
        AX.focusedWindow(pid: pid).flatMap { AX.string($0, kAXTitleAttribute as String) }
    }

    func clearAll() {
        for key in layers.keys {
            invalidate(layerKey: key)
        }
    }

    private func invalidate(layerKey: String) {
        guard var state = layers[layerKey] else { return }
        state.panels.removeAll()
        layers[layerKey] = state
        commitUI()
    }

    /// A tracked app changed in a way that can invalidate highlight positions:
    /// a window moved/resized/miniaturized, or a watched text element's value
    /// changed. Hide the affected layer NOW (its coordinates are no longer
    /// trustworthy) and request one settled rescan to re-present correctly.
    /// This is the only stale-removal mechanism — event-driven, no polling.
    func windowEventOccurred(pid: pid_t) {
        var needsRescan = false
        if let ocr = layers[Self.ocrKey], !ocr.panels.isEmpty, ocr.ownerPID == pid {
            invalidate(layerKey: Self.ocrKey)
            needsRescan = true
        }
        let key = Self.axKey(pid)
        if let state = layers[key], !state.panels.isEmpty {
            invalidate(layerKey: key)
            needsRescan = true
        }
        guard needsRescan else { return }
        requestRescan?(0.25)
    }

    func reassertZOrder() {
        for (layerKey, layerState) in layers where !layerState.isOCR {
            for key in layerState.panels.keys {
                let globalID = "\(layerKey)::\(key)"
                activePanels[globalID]?.orderAbove(windowNumber: layerState.windowNumber)
            }
        }
    }

    /// The frontmost app changed. Hide every highlight layer that does NOT
    /// belong to the new frontmost app — OCR and per-app AX alike. A background
    /// app's annotations must never sit on top of the app the user is now
    /// looking at, which is exactly what happened: a window full of AI text
    /// (e.g. a chat app) kept its brackets painted, and they floated over
    /// whatever app was switched to. The old design left AX layers up and relied
    /// on z-ordering them beneath the covering window, but that does not hold for
    /// every app's windows, so they leaked on top.
    ///
    /// Switching back to an app re-scans and re-presents its highlights. Our own
    /// menu activating is filtered out by the caller, so opening the panel never
    /// clears anything.
    func frontmostAppChanged(pid: pid_t) {
        let staleKeys = layers
            .filter { !$0.value.panels.isEmpty && $0.value.ownerPID != pid }
            .map(\.key)
        for key in staleKeys {
            invalidate(layerKey: key)
        }
    }

    // MARK: - Active-block fan-out

    private func activeBlocksUnion() -> [Block] {
        var union: [Block] = []
        for layerState in layers.values {
            for (key, tracked) in layerState.panels {
                union.append(Block(
                    id: key,
                    rect: tracked.rect,
                    state: tracked.state,
                    finalScore: tracked.finalScore,
                    words: tracked.words,
                    anchor: tracked.anchor,
                    domain: layerState.domain,
                    route: tracked.route,
                    result: tracked.result,
                    text: tracked.leadText
                ))
            }
        }
        return union
    }

    private func notifyActiveBlocks() {
        guard let onActiveBlocksChanged else { return }
        onActiveBlocksChanged(activeBlocksUnion())
    }
}
