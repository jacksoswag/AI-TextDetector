import AppKit
import Combine
import FilterCore
import ServiceManagement
import os.log

/// Top-level orchestrator for the menu bar app. Owns the FilterCore managers,
/// wires the acquisition → engine → highlight pipeline, drives the per-block
/// pets off the overlay's active-block events, and exposes the few pieces
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

    // Pet layer. The registry is the selection source of truth (the panel
    // and library bind to it); the windows coordinator owns the aux windows;
    // the pet coordinator turns flagged blocks into per-block instances.
    let petRegistry = PetRegistry()
    lazy var petWindows = PetWindowsCoordinator(registry: petRegistry)
    lazy var pets = PetCoordinator(registry: petRegistry)

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
    /// Developer/support affordance: pets speak their raw score+state and
    /// the AX role-histogram logging turns on. One switch, two effects —
    /// `debug.mode` is read here and `debug.axDump` rides the same write so
    /// the acquisition layer's role dump follows the same toggle.
    @Published var debugMode: Bool = false {
        didSet {
            UserDefaults.appGroup.set(debugMode, forKey: "debug.mode")
            UserDefaults.appGroup.set(debugMode, forKey: "debug.axDump")
            pets.debugMode = debugMode
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
            self?.pets.setScrolling(scrolling)
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
            self?.overlays.windowEventOccurred(pid: pid)
        }
        overlays.requestRescan = { [weak self] delay in
            self?.acquisition.requestConfirmScan(after: delay)
        }
        overlays.isScanInProgress = { [weak self] in self?.acquisition.isScanning ?? false }

        // PETS ride the overlay union: one instance per flagged block,
        // appearing with its highlight and leaving with it. There is no
        // persistent pet — a clean page shows nothing at all.
        overlays.onActiveBlocksChanged = { [weak self] blocks in
            self?.pets.sync(blocks: blocks.map(Self.petBlock))
        }
        pets.debugMode = debugMode

        // Pet size: push the stored/slider value in now and on every change so
        // live pets resize immediately as the user drags the slider.
        pets.setPetSize(CGFloat(settings.petSize))
        settings.$petSize
            .receive(on: DispatchQueue.main)
            .sink { [weak self] size in
                self?.pets.setPetSize(CGFloat(size))
            }
            .store(in: &cancellables)

        // One master switch controls everything, including every pet. The
        // license gate is folded in via applyRunState: detection runs only while
        // enabled AND a license is active, so an unlicensed app pauses scanning
        // the same way switching the master off does.
        settings.$isEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyRunState() }
            .store(in: &cancellables)

        license.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyRunState() }
            .store(in: &cancellables)

        // Re-skin live pets the instant the active selection changes.
        petRegistry.$activePetID
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.pets.activePetDidChange()
            }
            .store(in: &cancellables)

        needsAccessibility = !AX.isTrusted
    }

    /// Detection runs only while the master switch is on AND a license is
    /// active. Re-applied whenever either changes.
    private func applyRunState() {
        if settings.isEnabled && license.isActive {
            acquisition.start()
            overlays.startCulling()
        } else {
            acquisition.stop()
            overlays.stopCulling()
            overlays.clearAll()
            pets.removeAll()
            statusMessage = nil
        }
    }

    // MARK: - Acquisition → engine → highlights + pets

    private func handleAcquired(_ blocks: [AcquiredBlock], from app: RunningApp,
                                domain: String, source: TextSource) {
        guard settings.isEnabled else { return }

        // Highlight stability comes from the overlay's invalidate-on-event
        // contract, not a content-confirmation gate here: every block this scan
        // returns is scored and presented. Stale highlights are removed by the
        // event that invalidates them (scroll / window / text change), not by
        // deferring new ones.
        guard !blocks.isEmpty else { return }

        let stableBlocks = blocks

        // detectorID sentinels namespace the content-hash so unrelated layers
        // never collide on a shared key: "block" for engine inputs (and the
        // score cache, where the real Stage-1/Stage-2 model id is what actually
        // keys entries inside the engine), "overlay" for highlight-panel ids, and
        // "stats" for the dedup set. They are intentionally DIFFERENT namespaces;
        // the overlay correlates a flagged block to its verdict by `block.text`,
        // not by id, so the namespaces never need to match. Unify them only if
        // id-based correlation is ever introduced.
        let inputs = stableBlocks.map {
            BlockInput(id: TextMetrics.cacheKey($0.text, detectorID: "block"), text: $0.text)
        }
        // OCR blocks share a single floating layer; all other sources key their layer by pid.
        let layerKey = source == .ocr ? OverlayManager.ocrKey : OverlayManager.axKey(app.pid)

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
            for (block, verdict) in pending {
                if Task.isCancelled { return }
                // Reuse the Stage-1 verdict's id (already the detectorID:"block"
                // cache key for this text) instead of re-hashing the block.
                let input = BlockInput(id: verdict.id, text: block.text)
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

    /// Paint exactly `flagged` as the highlight set for `layerKey`, refresh the
    /// stats counters and the calm status line. Re-presents diff in place
    /// (panels are content-keyed), so phase 2 can re-present the union without
    /// disturbing the highlights phase 1 already drew. Pets follow via the
    /// overlay's `onActiveBlocksChanged` fan-out.
    private func presentFlagged(_ flagged: [(AcquiredBlock, BlockVerdict)],
                                layerKey: String, domain: String, app: RunningApp) {
        // wordCount is computed once per flagged block and reused for both the
        // overlay block and the stats entry. The overlay/stats cache keys use
        // distinct detectorIDs by design, so those stay separate.
        var overlayBlocks: [OverlayManager.Block] = []
        var statsEntries: [(hash: String, words: Int)] = []
        overlayBlocks.reserveCapacity(flagged.count)
        statsEntries.reserveCapacity(flagged.count)
        for (block, verdict) in flagged {
            let words = TextMetrics.wordCount(block.text)
            overlayBlocks.append(OverlayManager.Block(
                id: TextMetrics.cacheKey(block.text, detectorID: "overlay"),
                rect: block.screenRect,
                state: verdict.result.state,
                finalScore: Double(verdict.result.p_ai_final),
                words: words,
                anchor: block.anchor,
                domain: domain,
                route: domain,
                result: verdict.result,
                text: block.text
            ))
            statsEntries.append((TextMetrics.cacheKey(block.text, detectorID: "stats"), words))
        }
        overlays.present(layerKey: layerKey, blocks: overlayBlocks, domain: domain, ownerPID: app.pid)
        recordNativeStats(statsEntries)
        statusMessage = flagged.isEmpty
            ? nil
            : "Watching \(flagged.count) AI-likely block\(flagged.count == 1 ? "" : "s") in \(app.name)"
    }

    /// OverlayManager.Block → the pet layer's block shape.
    private static func petBlock(_ block: OverlayManager.Block) -> PetCoordinator.FlaggedBlock {
        PetCoordinator.FlaggedBlock(
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

    /// The bands that may draw a highlight and that get a pet.
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

    /// Open the manual check window (paste text → human-vs-AI verdict). Gated:
    /// the whole app is paid, so an unlicensed tap routes to purchase instead.
    /// The engine lives here, so the coordinator borrows it for the window's view.
    func openTextCheck() {
        petWindows.openTextCheck(engine: engine)
    }

    func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Licensing / web

    func activateLicense(_ key: String) async -> LicenseManager.ActivationOutcome {
        await license.activate(key)
    }

}
