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
/// SINGLE AUTHORITATIVE UPDATE PATH (the stability contract):
///   `present(...)` is the ONLY thing that creates, moves, restyles, or
///   destroys a panel. It diffs the incoming blocks against what is on screen
///   and applies the difference in one synchronous pass. There is no per-frame
///   tracker and no second reconciliation system.
///
///   A highlight is valid ONLY for the exact app/window/text state that
///   produced it. The moment anything can move it — scroll start, window
///   move/resize, a tracked text element changing — the affected layer is
///   invalidated (hidden) immediately, and the next settled scan re-presents
///   it at correct coordinates. Highlights therefore never track stale
///   geometry: they are present and correct, or absent. They are never wrong.
///
///   Invalidation is PRIMARILY event-driven: `windowEventOccurred(pid:)` fires
///   the instant an app emits an AX window-move/resize or text-value-changed
///   notification. But some apps remove or reposition on-screen text WITHOUT
///   emitting any such notification (canvas/Metal renderers like Google Docs,
///   apps that update AX geometry asynchronously). For those, a low-rate (5 Hz)
///   `cullTimer` runs a cheap anchor-drift safety net: it re-reads one anchored
///   panel per layer and invalidates the layer if that anchor vanished or moved.
///   This is a backstop for the event path, not a replacement for it.
///
/// Panels are CONTENT-keyed: identity is the block's text hash, not its
/// position. A rescan that returns the same text repositions the existing
/// panel in place; changed text yields a new key, so the old panel is removed
/// by the diff and a new one created — never a stale annotation left behind.
@MainActor
final class OverlayManager {

    static let ocrKey = "ocr"
    static func axKey(_ pid: pid_t) -> String { "ax:\(pid)" }
    /// Browser-extension layer: text + positions come from the companion
    /// extension's DOM read, not AX. Window-tracked (z-ordered above the browser
    /// window) like an AX layer, but anchorless like OCR — so it is excluded from
    /// the AX drift cull. The extension's explicit CLEAR is its invalidation path.
    /// Keyed by pid AND tab id so two windows/tabs of one browser get distinct
    /// layers instead of overwriting each other.
    static func extKey(_ pid: pid_t, _ tab: String) -> String { "ext:\(pid):\(tab)" }

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
        /// Extension-fed layer: window-tracked but anchorless, so it is excluded
        /// from the anchor-drift/title cull (the extension drives invalidation).
        var isExt = false
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
        state.isExt = layerKey.hasPrefix("ext:")
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
                anchorRefEditSig: block.anchor.flatMap { Self.editSignature($0) }
            )
        }

        state.panels = updatedPanels
        layers[layerKey] = state
        commitUI()
        notifyActiveBlocks()
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
        //   • geometry drift (anchor gone, or its origin moved) → the bracket is
        //     in the wrong place → clear the layer NOW, then rescan.
        //   • content drift (same origin, but the element resized or its text
        //     changed) → the bracket is still positionally correct → DON'T clear;
        //     just rescan so present() updates/removes it once the change settles.
        //     Keeps brackets steady through streaming/typing instead of tearing
        //     them down every 200 ms tick.
        // Collect first, act after the loop — invalidate() calls commitUI() and we
        // must not mutate `layers` mid-iteration.
        var staleKeys: [String] = []
        var contentRescanNeeded = false
        for (layerKey, layerState) in layers where !layerState.isOCR && !layerState.isExt {
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
            var layerContentStale = false
            for tracked in layerState.panels.values {
                guard let anchor = tracked.anchor, let ref = tracked.anchorRefRect else { continue }
                guard let live = AX.frame(anchor)?.axToCocoa else {
                    staleKeys.append(layerKey); break          // anchor gone → geometry stale
                }
                if abs(live.minX - ref.minX) > 4 || abs(live.minY - ref.minY) > 4 {
                    staleKeys.append(layerKey); break          // moved → wrong position → clear now
                }
                if abs(live.width - ref.width) > 4 || abs(live.height - ref.height) > 4 {
                    layerContentStale = true; continue         // grew/shrank in place → rescan only
                }
                if Self.editSignature(anchor) != tracked.anchorRefEditSig {
                    layerContentStale = true                   // in-place text edit → rescan only
                }
            }
            if layerContentStale { contentRescanNeeded = true }
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
        // typing, so passive reading pays nothing.
        let typingNow = lastKeyDownAt.map { Date().timeIntervalSince($0) < Self.typingWindow } ?? false
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

    /// Remove a single layer's highlights immediately. Used by the browser
    /// extension's explicit CLEAR (tab hidden / navigated / closed) and by the
    /// canvas-editor fallback handoff.
    func dropLayer(_ layerKey: String) {
        guard layers[layerKey] != nil else { return }
        invalidate(layerKey: layerKey)
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
                    result: tracked.result
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
