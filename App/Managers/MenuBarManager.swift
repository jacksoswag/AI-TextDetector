import AppKit
import Combine
import FilterCore
import ServiceManagement
import os.log

/// Top-level orchestrator for the menu bar app. Owns the FilterCore managers,
/// wires the acquisition → engine → highlight pipeline, drives the per-block
/// mascots off the overlay's active-block events, and exposes the few pieces
/// of state the panel shows.
///
/// Status philosophy: silence when healthy. The panel surfaces exactly two
/// conditions — "Watching N AI-likely block(s) here" while highlights are up,
/// and a permission call-to-action when Accessibility is missing. Scores, scan
/// telemetry, and per-layer detail live in os_log (`subsystem dev.aicf`),
/// not in the consumer UI.
@MainActor
final class MenuBarManager: ObservableObject {

    static let shared = MenuBarManager()

    // Shared core.
    let settings = SettingsManager()
    let trust = DomainTrustManager()
    let stats = StatisticsManager()
    // An owner build (OWNER_BUILD, set by scripts/install.sh) flips the override
    // before LicenseManager.shared is first touched, so the owner's own builds
    // are always fully unlocked. The public release build never sets it.
    let license: LicenseManager = {
        #if OWNER_BUILD
        LicenseManager.ownerOverride = true
        #endif
        return .shared
    }()
    lazy var engine = DetectionEngine(licenseGate: { LicenseManager.isCurrentlyActive() })

    // Pipeline.
    let acquisition = TextAcquisitionService()
    let overlays = OverlayManager()
    let extensionServer = ExtensionServer()

    // Mascot layer. The registry is the selection source of truth (the panel
    // and library bind to it); the windows coordinator owns the aux windows;
    // the mascot coordinator turns flagged blocks into per-block instances.
    let petRegistry = PetRegistry()
    lazy var petWindows = PetWindowsCoordinator(registry: petRegistry)
    lazy var mascots = MascotCoordinator(registry: petRegistry)

    /// Calm, human one-liner ("Watching 3 AI-likely blocks in Safari") or nothing.
    @Published var statusMessage: String?
    /// States that need the user. Accessibility blocks everything; Screen
    /// Recording only surfaces if OCR was actually needed and was declined.
    @Published var needsAccessibility = false
    @Published var needsScreenRecording = false
    /// True when scoring runs without the bundled model (heuristics only).
    @Published var modelDegraded = false
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet { updateLoginItem() }
    }
    /// Developer/support affordance: mascots speak their raw score+state and
    /// the AX role-histogram logging turns on. One switch, two effects —
    /// `debug.mode` is read here and `debug.axDump` rides the same write so
    /// the acquisition layer's role dump follows the same toggle.
    @Published var debugMode: Bool = false {
        didSet {
            UserDefaults.appGroup.set(debugMode, forKey: "debug.mode")
            UserDefaults.appGroup.set(debugMode, forKey: "debug.axDump")
            mascots.debugMode = debugMode
        }
    }

    private static let log = Logger(subsystem: "dev.aicf", category: "verdict")

    private var cancellables: Set<AnyCancellable> = []
    /// Text hashes already counted in statistics recently (rescans of the
    /// same window must not inflate the counters).
    private var countedHashes: [String: Date] = [:]

    /// Tracks the active ML inference pass. Canceled if a new scan arrives
    /// before completion to prevent stale coordinates from hitting the UI.
    private var evaluationTask: Task<Void, Never>?

    /// Maps browser-extension DOM rects to screen coordinates (AXWebArea-anchored).
    private let webAreaAnchor = WebAreaAnchor()
    /// tab id (extension layerKey) → owning browser pid, so a CLEAR/FALLBACK that
    /// arrives once the browser is no longer frontmost still resolves the layer.
    private var extOwnerByTab: [String: pid_t] = [:]
    /// The most recent extension payload, kept so it can be re-mapped to screen
    /// space without a round-trip: to upgrade approach A → B once the AXWebArea
    /// builds, and to reposition on a browser window move.
    private var lastExt: ExtSnapshot?
    private var extRemapTask: Task<Void, Never>?
    /// Serial presentation of extension posts: the latest pending snapshot, and
    /// whether the drain loop is active. A flood of position re-posts must never
    /// cancel the in-flight detection (that starves the cold first inference).
    private var extQueued: ExtSnapshot?
    private var extDraining = false

    private struct ExtSnapshot {
        let layerKey: String
        let pid: pid_t
        let app: RunningApp
        let domain: String
        let viewport: WebAreaAnchor.Viewport
        let texts: [String]
        let domRects: [WebAreaAnchor.DOMRect]
    }

    private init() {
        // Ensure debug mode starts off on launch
        UserDefaults.appGroup.set(false, forKey: "debug.mode")
        UserDefaults.appGroup.set(false, forKey: "debug.axDump")
    }

    func bootstrap() {
        // Load + ANE-compile BOTH models off the main thread at launch, so the
        // first detection of a session doesn't pay the load inline.
        let engine = self.engine
        Task.detached(priority: .userInitiated) {
            await engine.preload()
            await MainActor.run {
                MenuBarManager.shared.modelDegraded = false
            }
        }

        // Launch at login: register automatically only when running from a
        // stable location. Registering a transient build path would leave a
        // broken login item behind — the opposite of dependable.
        if !UserDefaults.appGroup.bool(forKey: SettingsKey.launchAtLoginDone),
           Bundle.main.bundlePath.hasPrefix("/Applications") {
            UserDefaults.appGroup.set(true, forKey: SettingsKey.launchAtLoginDone)
            try? SMAppService.mainApp.register()
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }

        acquisition.onBlocks = { [weak self] blocks, app, domain, source in
            Task { @MainActor in self?.handleAcquired(blocks, from: app, domain: domain, source: source) }
        }
        acquisition.onPermissionState = { [weak self] ax, sc in
            self?.needsAccessibility = ax
            self?.needsScreenRecording = sc
        }
        acquisition.onScrollActivity = { [weak self] scrolling in
            self?.mascots.setScrolling(scrolling)
            self?.overlays.setScrolling(scrolling)
            // Kill any in-flight evaluation the instant scrolling starts so an
            // ML result from before the scroll can't re-paint stale highlights
            // after the overlay has been cleared.
            if scrolling {
                self?.evaluationTask?.cancel()
                self?.evaluationTask = nil
            }
        }
        acquisition.onAppActivated = { [weak self] in
            guard let self else { return }
            self.overlays.reassertZOrder()
            // Drop stale screen-level OCR annotations when a different app
            // takes the front (its windows now cover the captured pixels).
            // Our own activation — opening the menu panel — doesn't count.
            if let front = NSWorkspace.shared.frontmostApplication,
               front.bundleIdentifier != Bundle.main.bundleIdentifier {
                self.overlays.frontmostAppChanged(pid: front.processIdentifier)
                // Cancel any in-flight evaluation so a refinement from the app we
                // just left can't repaint after its layer was cleared.
                self.evaluationTask?.cancel()
                self.evaluationTask = nil
            }
        }
        acquisition.onWindowEvent = { [weak self] pid in
            guard let self else { return }
            self.overlays.windowEventOccurred(pid: pid)
            // A browser window move/resize moves the AXWebArea but fires no DOM
            // event, and the ext layer is cull-excluded — so re-map the last
            // extension payload against the moved frame to reposition in place.
            self.remapBrowserIfOwned(pid: pid)
        }
        overlays.requestRescan = { [weak self] delay in
            self?.acquisition.requestConfirmScan(after: delay)
        }
        overlays.isScanInProgress = { [weak self] in self?.acquisition.isScanning ?? false }

        extensionServer?.onEvaluateRequest = { [weak self] text, domain in
            guard let self = self else { return nil }
            let inputs = [BlockInput(id: TextMetrics.cacheKey(text, detectorID: "block"), text: text, leadingContext: nil)]
            // Stage-1 only: a single JS request needs one fast number, not a
            // ~144ms ANE Stage-2 pass. deferStage2 returns the e5 score immediately.
            let results = await self.engine.evaluate(blocks: inputs, domain: domain, source: .browser, deferStage2: true)
            return results.first.map { Double($0.result.p_ai_final) }
        }
        // The companion extension is the browser text SOURCE: it streams the
        // active tab's visible paragraphs + viewport rects (POST /blocks), an
        // explicit CLEAR when the tab goes away, a FALLBACK signal for canvas
        // editors (Google Docs), and a HEARTBEAT to keep the AX-suppression gate
        // warm on a static page.
        extensionServer?.onBrowserBlocks = { [weak self] payload in
            self?.handleBrowserBlocks(payload)
        }
        extensionServer?.onBrowserClear = { [weak self] payload in
            self?.handleBrowserClear(payload)
        }
        extensionServer?.onBrowserFallback = { [weak self] payload in
            self?.handleBrowserFallback(payload)
        }
        extensionServer?.onBrowserHeartbeat = { [weak self] _ in
            self?.handleBrowserHeartbeat()
        }
        extensionServer?.start()

        // MASCOTS ride the overlay union: one instance per flagged block,
        // appearing with its highlight and leaving with it. There is no
        // persistent pet — a clean page shows nothing at all.
        overlays.onActiveBlocksChanged = { [weak self] blocks in
            self?.mascots.sync(blocks: blocks.map(Self.mascotBlock))
        }
        mascots.debugMode = debugMode

        // Mascot size: push the stored/slider value in now and on every change so
        // live mascots resize immediately as the user drags the slider.
        mascots.setMascotSize(CGFloat(settings.mascotSize))
        settings.$mascotSize
            .receive(on: DispatchQueue.main)
            .sink { [weak self] size in
                self?.mascots.setMascotSize(CGFloat(size))
            }
            .store(in: &cancellables)

        // One master switch controls everything, including every mascot. The
        // license gate is folded in via applyRunState: detection runs only while
        // enabled AND the trial/license is active, so an expired trial pauses
        // scanning the same way switching the master off does.
        settings.$isEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyRunState() }
            .store(in: &cancellables)

        license.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyRunState() }
            .store(in: &cancellables)

        // Re-skin live mascots the instant the active selection changes.
        petRegistry.$activePetID
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.mascots.activePetDidChange()
            }
            .store(in: &cancellables)

        needsAccessibility = !AX.isTrusted
    }

    /// Detection runs only while the master switch is on AND the license/trial
    /// is active. Re-applied whenever either changes.
    private func applyRunState() {
        if settings.isEnabled && license.isActive {
            acquisition.start()
            overlays.startCulling()
        } else {
            acquisition.stop()
            overlays.stopCulling()
            overlays.clearAll()
            mascots.removeAll()
            statusMessage = nil
        }
    }

    // MARK: - Acquisition → engine → highlights + mascots

    private func handleAcquired(_ blocks: [AcquiredBlock], from app: RunningApp,
                                domain: String, source: TextSource,
                                layerKeyOverride: String? = nil) {
        guard settings.isEnabled else { return }

        // Highlight stability comes from the overlay's invalidate-on-event
        // contract, not a content-confirmation gate here: every block this scan
        // returns is scored and presented. Stale highlights are removed by the
        // event that invalidates them (scroll / window / text change), not by
        // deferring new ones.
        guard !blocks.isEmpty else { return }

        let stableBlocks = blocks

        let inputs = stableBlocks.map {
            BlockInput(id: TextMetrics.cacheKey($0.text, detectorID: "block"), text: $0.text, leadingContext: nil)
        }
        // The AX path keys layers by pid (ax:/ocr:); the extension path overrides
        // with ext:<pid> so its anchorless blocks land in a cull-excluded layer
        // distinct from any concurrent AX scan of the same browser.
        let layerKey = layerKeyOverride
            ?? (source == .ocr ? OverlayManager.ocrKey : OverlayManager.axKey(app.pid))

        evaluationTask?.cancel()

        // TWO-PHASE so Stage-2 never blocks the fast highlights. Phase 1 paints
        // every Stage-1 call immediately. Phase 2 re-scores the borderline blocks
        // with the Stage-2 ModernBERT model (~144ms/window on the Neural Engine)
        // off the hot path — ONE BLOCK AT A TIME, re-presenting after each so
        // authoritative highlights stream in rather than waiting on the slowest.
        // The cache makes each Stage-1 re-score free; confident and
        // persistent-confirmed highlights stay stable, and only a genuine
        // Stage-1/Stage-2 disagreement moves a bracket.
        evaluationTask = Task { [weak self] in
            guard let self = self else { return }

            let s1Start = DispatchTime.now()
            let fast = await self.engine.evaluate(blocks: inputs, domain: domain,
                                                  source: source, deferStage2: true)
            let stage1Ms = Int(Double(DispatchTime.now().uptimeNanoseconds - s1Start.uptimeNanoseconds) / 1_000_000)
            if Task.isCancelled { return }

            let scored = Array(zip(stableBlocks, fast).filter { $0.1.skipReason == nil })
            let pending = scored.filter { $0.1.needsRefinement }
            let confidentFlagged = scored.filter {
                !$0.1.needsRefinement && Self.isFlagState($0.1.result.state) && $0.1.shouldHighlight
            }
            let pendingFlagged = pending.filter {
                Self.isFlagState($0.1.result.state) && $0.1.shouldHighlight
            }

            // PHASE 1 — confident highlights + Stage-1's tentative call on
            // borderline blocks, painted now.
            self.presentFlagged(confidentFlagged + pendingFlagged, layerKey: layerKey, domain: domain, app: app)
            Self.log.notice("app=\(app.name, privacy: .public) domain=\(domain, privacy: .public) scored=\(scored.count) flagged=\(confidentFlagged.count + pendingFlagged.count) pending=\(pending.count) stage1Ms=\(stage1Ms) stage=1")

            guard !pending.isEmpty, !Task.isCancelled else { return }

            // PHASE 2 — refine borderline blocks ONE AT A TIME and re-present
            // after each, so authoritative highlights stream in (~144ms/window on
            // the ANE) instead of the whole set waiting on the slowest. Keyed by
            // content so each block can be confirmed (Stage-2 agrees), dropped
            // (Stage-2 rejects), or left as its Stage-1 tentative (Stage-2
            // unavailable). Not-yet-refined blocks keep showing their tentative.
            var flaggedByText: [String: (AcquiredBlock, BlockVerdict)] = [:]
            for pair in confidentFlagged + pendingFlagged { flaggedByText[pair.0.text] = pair }

            var stage2TotalMs = 0
            for (block, _) in pending {
                if Task.isCancelled { return }
                let input = BlockInput(id: TextMetrics.cacheKey(block.text, detectorID: "block"),
                                       text: block.text, leadingContext: nil)
                let s2Start = DispatchTime.now()
                let refined = await self.engine.refine(blocks: [input], domain: domain, source: source)
                stage2TotalMs += Int(Double(DispatchTime.now().uptimeNanoseconds - s2Start.uptimeNanoseconds) / 1_000_000)
                if Task.isCancelled { return }
                guard let verdict = refined.first, verdict.skipReason == nil else {
                    continue   // Stage-2 unavailable for this block — keep its Stage-1 tentative
                }
                if Self.isFlagState(verdict.result.state) && verdict.shouldHighlight {
                    flaggedByText[block.text] = (block, verdict)   // Stage-2 confirms
                } else {
                    flaggedByText[block.text] = nil                // Stage-2 rejects
                }
                self.presentFlagged(Array(flaggedByText.values), layerKey: layerKey, domain: domain, app: app)
            }
            Self.log.notice("app=\(app.name, privacy: .public) refined=\(pending.count) flagged=\(flaggedByText.count) stage2TotalMs=\(stage2TotalMs) stage=2")
        }
    }

    // MARK: - Browser extension source

    /// The companion extension posted the active tab's visible text + viewport
    /// rects. Snapshot it, map to screen space, and route through the SAME scoring
    /// + overlay pipeline the AX path uses — the extension only swaps the source.
    private func handleBrowserBlocks(_ p: ExtensionServer.BlocksPayload) {
        guard settings.isEnabled, p.focused,
              let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier,
              acquisition.isBrowserBundle(bundleID) else { return }

        let pid = front.processIdentifier
        let tab = p.layerKey
        let layerKey = OverlayManager.extKey(pid, tab)

        acquisition.markExtensionOwned(bundleID)
        extOwnerByTab[tab] = pid
        // Clear any lingering AX-scan layer for this browser so the handoff from
        // the AX path to the extension never double-paints.
        overlays.dropLayer(OverlayManager.axKey(pid))

        // A legitimately empty page (no qualifying text) clears the layer. Canvas
        // editors and shadow/iframe pages take the /fallback path instead, so an
        // empty payload here always means "nothing to highlight".
        guard !p.blocks.isEmpty else {
            overlays.dropLayer(layerKey)
            if lastExt?.layerKey == layerKey { lastExt = nil }
            return
        }

        let app = RunningApp(pid: pid, bundleID: bundleID, name: front.localizedName ?? bundleID)
        let viewport = WebAreaAnchor.Viewport(
            innerWidth: p.viewport.innerWidth, innerHeight: p.viewport.innerHeight,
            outerWidth: p.viewport.outerWidth, outerHeight: p.viewport.outerHeight,
            screenX: p.viewport.screenX, screenY: p.viewport.screenY)
        let snapshot = ExtSnapshot(
            layerKey: layerKey, pid: pid, app: app, domain: p.host, viewport: viewport,
            texts: p.blocks.map(\.text),
            domRects: p.blocks.map { WebAreaAnchor.DOMRect(x: $0.rect.x, y: $0.rect.y, w: $0.rect.w, h: $0.rect.h) })
        // Process serially, run-to-completion: a flood of position re-posts (a page
        // still settling its layout after load) must NOT cancel the cold first
        // inference, or it never finishes and highlights stall for seconds. The
        // queue keeps only the latest pending payload; the detection cache makes
        // every re-post after the first essentially free.
        enqueueExt(snapshot)
        // One delayed re-map to upgrade the window-geometry first paint to the
        // accurate AXWebArea path once Chromium's tree finishes building.
        scheduleExtRemap()
    }

    /// Queue a snapshot for serial presentation. Never cancels an in-flight
    /// detection — the latest queued snapshot is processed once the current one
    /// finishes, so a burst of re-posts can't starve the first inference.
    private func enqueueExt(_ snap: ExtSnapshot) {
        lastExt = snap
        extQueued = snap
        guard !extDraining else { return }
        extDraining = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            while let next = self.extQueued {
                self.extQueued = nil
                await self.presentBrowserAwaiting(next)
            }
            self.extDraining = false
        }
    }

    /// Map a snapshot to screen coordinates, score Stage-1, and present — awaiting
    /// completion so the serial drain never overlaps two detections. Stage-1 only:
    /// the extension path favors a fast, stable first paint over Stage-2 refinement.
    private func presentBrowserAwaiting(_ snap: ExtSnapshot) async {
        guard settings.isEnabled else { return }
        let mapped = webAreaAnchor.map(pid: snap.pid, viewport: snap.viewport, rects: snap.domRects)
        guard mapped.rects.count == snap.texts.count else {
            overlays.dropLayer(snap.layerKey)   // degenerate viewport → nothing trustworthy to paint
            return
        }
        let acquired = zip(snap.texts, mapped.rects).map { text, rect in
            AcquiredBlock(text: text, screenRect: rect, source: .accessibility, anchor: nil)
        }
        let inputs = acquired.map {
            BlockInput(id: TextMetrics.cacheKey($0.text, detectorID: "block"), text: $0.text, leadingContext: nil)
        }
        let verdicts = await engine.evaluate(blocks: inputs, domain: snap.domain,
                                             source: .browser, deferStage2: true)
        let flagged = Array(zip(acquired, verdicts)).filter {
            $0.1.skipReason == nil && Self.isFlagState($0.1.result.state) && $0.1.shouldHighlight
        }
        presentFlagged(flagged, layerKey: snap.layerKey, domain: snap.domain, app: snap.app)
    }

    /// One-shot upgrade from the window-geometry estimate to the AXWebArea path
    /// once the lazily-built tree appears. Bounded; re-runs only the cheap map.
    private func scheduleExtRemap() {
        extRemapTask?.cancel()
        extRemapTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, let self, let snap = self.lastExt,
                  let front = NSWorkspace.shared.frontmostApplication,
                  front.processIdentifier == snap.pid else { return }
            self.enqueueExt(snap)
        }
    }

    /// Reposition the current extension highlights after a browser window move.
    private func remapBrowserIfOwned(pid: pid_t) {
        guard let snap = lastExt, snap.pid == pid else { return }
        enqueueExt(snap)
    }

    /// The active tab went away (hidden / navigated / unloaded / closed). Drop its
    /// highlights, resolved from the tab id in the payload (the browser may no
    /// longer be frontmost). Ownership is NOT relinquished here — the heartbeat
    /// TTL handles that, so a tab switch (old tab clears, new tab re-posts) does
    /// not briefly re-expose the slow AX path.
    private func handleBrowserClear(_ p: ExtensionServer.ClearPayload) {
        let tab = p.layerKey
        guard let pid = extOwnerByTab[tab] else { return }
        let layerKey = OverlayManager.extKey(pid, tab)
        overlays.dropLayer(layerKey)
        extOwnerByTab[tab] = nil
        if lastExt?.layerKey == layerKey { lastExt = nil }
    }

    /// A canvas editor (Google Docs) or a page whose text lives where the DOM walk
    /// can't reach. Relinquish ownership so the native AX path reclaims the surface
    /// (Chrome exposes Docs' off-screen a11y layer once nudged), and clear any
    /// extension highlights we were showing.
    private func handleBrowserFallback(_ p: ExtensionServer.FallbackPayload) {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier,
              acquisition.isBrowserBundle(bundleID) else { return }
        let pid = front.processIdentifier
        let tab = p.layerKey
        let layerKey = OverlayManager.extKey(pid, tab)
        overlays.dropLayer(layerKey)
        extOwnerByTab[tab] = nil
        if lastExt?.layerKey == layerKey { lastExt = nil }
        webAreaAnchor.invalidate(pid: pid)
        acquisition.clearExtensionOwned(bundleID)
        acquisition.requestConfirmScan(after: 0.3)   // let AX pick up the editor
    }

    /// Keep the AX-suppression gate warm for a static but covered page.
    private func handleBrowserHeartbeat() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier,
              acquisition.isBrowserBundle(bundleID) else { return }
        acquisition.markExtensionOwned(bundleID)
    }

    /// Paint exactly `flagged` as the highlight set for `layerKey`, refresh the
    /// stats counters and the calm status line. Re-presents diff in place
    /// (panels are content-keyed), so phase 2 can re-present the union without
    /// disturbing the highlights phase 1 already drew. Mascots follow via the
    /// overlay's `onActiveBlocksChanged` fan-out.
    private func presentFlagged(_ flagged: [(AcquiredBlock, BlockVerdict)],
                                layerKey: String, domain: String, app: RunningApp) {
        overlays.present(
            layerKey: layerKey,
            blocks: flagged.map { pair in
                OverlayManager.Block(
                    id: TextMetrics.cacheKey(pair.0.text, detectorID: "overlay"),
                    rect: pair.0.screenRect,
                    state: pair.1.result.state,
                    finalScore: Double(pair.1.result.p_ai_final),
                    words: TextMetrics.wordCount(pair.0.text),
                    anchor: pair.0.anchor,
                    domain: domain,
                    route: domain,
                    result: pair.1.result
                )
            },
            domain: domain,
            ownerPID: app.pid
        )
        recordNativeStats(flagged.map { (TextMetrics.cacheKey($0.0.text, detectorID: "stats"), TextMetrics.wordCount($0.0.text)) })
        statusMessage = flagged.isEmpty
            ? nil
            : "Watching \(flagged.count) AI-likely block\(flagged.count == 1 ? "" : "s") in \(app.name)"
    }

    /// OverlayManager.Block → the mascot layer's block shape.
    private static func mascotBlock(_ block: OverlayManager.Block) -> MascotCoordinator.FlaggedBlock {
        MascotCoordinator.FlaggedBlock(
            id: block.id,
            rect: block.rect,
            state: block.state,
            finalScore: block.finalScore,
            words: block.words,
            domain: block.domain,
            route: block.route,
            result: block.result
        )
    }

    /// The bands that may draw a highlight and that get a mascot.
    /// safe never flags; uncertain never flags by the §12 fail-safe.
    private static func isFlagState(_ state: DetectionState) -> Bool {
        state == .suspicious || state == .high || state == .veryHigh
    }

    private func recordNativeStats(_ entries: [(hash: String, words: Int)]) {
        let now = Date()
        countedHashes = countedHashes.filter { now.timeIntervalSince($0.value) < 600 }
        var words = 0, blocks = 0
        for entry in entries where countedHashes[entry.hash] == nil {
            countedHashes[entry.hash] = now
            words += entry.words
            blocks += 1
        }
        stats.recordFiltered(words: words, blocks: blocks)
    }

    // MARK: - Actions

    func openAccessibilitySettings() {
        AX.promptForTrust()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshPermissionState() {
        needsAccessibility = !AX.isTrusted
    }

    private func updateLoginItem() {
        do {
            if launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            Self.log.notice("login item: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Open the manual check window (paste text → human-vs-AI verdict). The
    /// engine lives here, so the coordinator borrows it for the window's view.
    func openTextCheck() {
        petWindows.openTextCheck(engine: engine)
    }

    func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Licensing / web

    @discardableResult
    func activateLicense(_ key: String) -> Bool { license.activate(key) }

    func openPurchase() { open(Brand.purchaseURL) }
    func openWebsite() { open(Brand.siteURL) }
    func openPrivacyPage() { open(Brand.privacyURL) }
    func openTermsPage() { open(Brand.termsURL) }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }
}
