import AppKit
import ApplicationServices
import FilterCore
import os.log

/// Fully automatic, tiered, event-driven text acquisition. No manual scan
/// actions exist anywhere in the product, and — per spec §5 — there is no
/// polling: the service reacts to events, never sweeps on a clock.
///
///   Tier 1/2 — Accessibility, per frontmost app: browsers (page URL → real
///              domain) and native apps. Cheap; the primary path.
///   Tier 3   — OCR, whole-screen, as an EVENT-GATED FALLBACK only: it runs
///              when an AX scan of the frontmost app comes back empty (after
///              the wake-up nudge and one retry), subject to an in-flight guard
///              and a 20 s per-bundle cooldown. The safety net for anything
///              Accessibility can't expose. Processed in memory, never leaves
///              the Mac.
///
/// Triggers (the ONLY things that cause a scan):
///   • app activation                          → reattach observers, scan
///   • AX focused-window / title / value /
///     window-created / focused-element change → coalesced rescan (250 ms)
///   • window moved / resized / destroyed       → routed to overlays + rescan
///   • scroll settled (>150 ms after last wheel)→ settle scan
///   • wake from sleep                          → scan
///
/// Accepted limitation: a canvas/Metal app that repaints WITHOUT emitting any
/// AX, scroll, or activation event will not re-trigger OCR until some event
/// fires. That is the spec's event model — we do not run a fallback clock to
/// paper over it.
@MainActor
final class TextAcquisitionService {

    var onBlocks: (([AcquiredBlock], RunningApp, String, TextSource) -> Void)?

    /// Decoupling seams — Acquisition/ holds no reference to the orchestrator
    /// that owns it. The integration phase wires each of these.
    /// Permission state, reported whenever either grant is (re)learned.
    var onPermissionState: ((_ needsAccessibility: Bool, _ needsScreenRecording: Bool) -> Void)?
    /// Scroll state: true on the first wheel of a burst, false once it settles.
    /// Drives the overlay's hide-on-scroll / re-present-on-settle contract and
    /// the pet's tracking mode.
    var onScrollActivity: ((Bool) -> Void)?
    /// App-activation hook (z-order reassert). Fires on every frontmost change.
    var onAppActivated: (() -> Void)?
    /// AX window move/resize/destroy for a tracked pid → overlays clear + rescan.
    var onWindowEvent: ((pid_t) -> Void)?

    private static let log = Logger(subsystem: "dev.aicf", category: "scan")
    private static let ocrCooldown: TimeInterval = 2.0
    /// Spec's max batch window: many AX events in a burst coalesce into one
    /// scan within this debounce.
    private static let eventDebounce: TimeInterval = 0.25
    /// Cap on AXValueChanged subscriptions per scan — enough to catch streaming
    /// updates without registering against an unbounded element set.
    private static let maxValueAnchors = 40
    /// LRU of live AX observers, at most this many; evicting one invalidates it.
    private static let maxObservers = 4
    /// How long a browser stays "extension-owned" after its last post/heartbeat
    /// before the AX/OCR path reclaims it (covers chrome://, file://, the PDF
    /// viewer, an extension crash, or a canvas editor that handed back).
    private static let extTTL: TimeInterval = 6.0

    private let axSource = AccessibilityTextSource()
    private let ocrSource = OCRTextSource()
    private let browsers = BrowserIntegrationService()

    private var activationObserver: NSObjectProtocol?
    private var sleepObservers: [NSObjectProtocol] = []
    private var scrollMonitor: Any?
    private var scrollSettleTimer: Timer?
    private var scrolling = false
    private var pendingScan: Task<Void, Never>?
    private var pendingOCRByBundle: [String: Task<Void, Never>] = [:]
    private var retriedPIDs = Set<pid_t>()
    private var ocrInFlight = false
    private var requestedScreenCapture = false
    private var isAsleep = false
    private var lastExternalApp: NSRunningApplication?
    /// Browser bundles currently fed by the companion extension → timestamp of
    /// the last post/heartbeat. While warm (< extTTL) `scanApp` skips the slow
    /// AX walk + OCR fallback for that browser.
    private var extensionOwned: [String: Date] = [:]
    private(set) var isRunning = false
    private var pendingScrollSettle = false
    /// True while a frontmost scan (the off-main AX walk) is in flight. The
    /// overlay's typing heartbeat reads this to avoid stacking overlapping walks.
    private(set) var isScanning = false

    /// Per-app AX notification subscriptions, LRU-ordered (front = most recent).
    private var observers: [(pid: pid_t, observer: AXEventObserver)] = []
    /// Focused window currently subscribed per pid, so window-level
    /// notifications get re-pointed when focus moves to another window.
    private var focusedWindowByPID: [pid_t: AXUIElement] = [:]
    /// Last whole-screen OCR pass time per bundle id (the 20 s cooldown map).
    private var lastOCRByBundle: [String: Date] = [:]

    private static weak var shared: TextAcquisitionService?

    init() {
        Self.shared = self
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        // Show the native Accessibility prompt exactly once, ever. After that
        // the menu's calm fix-it row handles the un-granted case; we never
        // re-summon the system modal on our own.
        if !AX.isTrusted, !UserDefaults.appGroup.bool(forKey: "accessibility.promptShown") {
            UserDefaults.appGroup.set(true, forKey: "accessibility.promptShown")
            _ = AX.promptForTrust()
        }

        // App switches don't clear overlays — every visible window keeps its
        // own layer; AX window notifications handle each layer's lifecycle.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.appActivated() }
        }

        // Synchronous: runs immediately during NSEvent delivery on the main thread,
        // BEFORE any queued Task (including a completing evaluationTask) can run.
        // Without this, an in-flight present() can race the scroll and paint stale
        // highlights before clearAll() fires.
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrollWheelMoved() }
        }

        let center = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification,
                               object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.isAsleep = true }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification,
                               object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.isAsleep = false; self?.scheduleScan(after: 2.0) }
            },
            // A Spaces switch / Mission Control move changes which windows are
            // visible WITHOUT necessarily emitting an app-activation
            // notification, so highlights from the previously-front app could
            // otherwise linger over the now-visible one. Treat it like a front
            // change: clear stale layers (via onAppActivated) and rescan.
            center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                               object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.spaceChanged() }
            },
        ]

        scheduleScan(after: 0.5)
    }

    func stop() {
        isRunning = false
        pendingScan?.cancel()
        pendingOCRByBundle.values.forEach { $0.cancel() }
        pendingOCRByBundle.removeAll()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        sleepObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        sleepObservers = []
        activationObserver = nil
        scrollMonitor = nil
        scrollSettleTimer?.invalidate(); scrollSettleTimer = nil
        // Tear down every AX subscription; observers must not outlive us.
        observers.forEach { $0.observer.invalidate() }
        observers.removeAll()
        focusedWindowByPID.removeAll()
        // Session-scoped bookkeeping resets with the master switch: PIDs get
        // recycled by the OS and bundle cooldowns shouldn't survive a restart
        // of scanning.
        retriedPIDs.removeAll()
        lastOCRByBundle.removeAll()
    }

    /// Quick follow-up pass requested by the overlay after it invalidates a
    /// layer (scroll settle, window move/resize, text change) so highlights
    /// re-present at correct coordinates without waiting for the next organic
    /// event. An event-SCHEDULED one-shot (it fires once and cancels any prior
    /// pending scan), NOT a poll — nothing here repeats on a clock.
    func requestConfirmScan(after delay: TimeInterval = 1.2) {
        scheduleScan(after: delay)
    }

    // MARK: - Browser extension ownership

    /// The companion extension just posted text for this browser bundle. Refresh
    /// its ownership window so the AX/OCR browser path stays suppressed.
    func markExtensionOwned(_ bundleID: String) { extensionOwned[bundleID] = Date() }

    /// The extension relinquished this browser (tab closed, or a canvas-editor
    /// handoff): let the AX/OCR path reclaim it on the next scan.
    func clearExtensionOwned(_ bundleID: String) { extensionOwned.removeValue(forKey: bundleID) }

    func isBrowserBundle(_ bundleID: String) -> Bool { browsers.isBrowser(bundleID) }

    /// The single coalescing one-shot every trigger funnels through. Each call
    /// resets the timer, meaning rapid events (like continuous scrolling or
    /// typing) hold off the scan until things settle for `eventDebounce` ms.
    private func scheduleScan(after delay: TimeInterval) {
        pendingScan?.cancel()
        guard isRunning, !isAsleep else { return }

        pendingScan = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.scrolling else { return }
            await self.scanFrontmost()
        }
    }

    // MARK: - Triggers

    private func appActivated() {
        guard isRunning else { return }
        // Reattach observers to the new frontmost app and re-pin overlay
        // z-order, then scan once it has settled (windows finish animating in).
        onAppActivated?()
        // Send the a11y wake-up immediately, BEFORE the settle delay, so a lazy
        // AX tree (Chromium, Electron) is already building during the wait — the
        // first scan is then far more likely to find text and skip the
        // empty→nudge→retry hop, which is the bulk of the cold-start latency.
        // Cheap and idempotent for every app.
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            BrowserIntegrationService.nudgeAccessibility(pid: front.processIdentifier)
        }
        scheduleScan(after: 0.5)
    }

    /// A Spaces switch / Mission Control move: re-pin z-order, clear any layer
    /// that no longer belongs to the frontmost app (handled in `onAppActivated`),
    /// then rescan the now-visible app.
    private func spaceChanged() {
        guard isRunning else { return }
        onAppActivated?()
        scheduleScan(after: 0.4)
    }

    private func scrollWheelMoved() {
        guard isRunning else { return }
        if !scrolling {
            scrolling = true
            onScrollActivity?(true)
        }

        // scroll is "stopped" after >150 ms of quiet; 250 ms is comfortably
        // past that and matches the event batch window).
        scrollSettleTimer?.invalidate()
        let timer = Timer(timeInterval: Self.eventDebounce, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.scrollSettled() }
        }
        scrollSettleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func scrollSettled() {
        scrollSettleTimer = nil
        scrolling = false
        pendingScrollSettle = true
        // Wait 750ms after the last wheel event before scanning. Canvas-based
        // renderers (Google Docs) update AX element positions lazily; they go
        // through a transitional state (wrong/zero coordinates) for ~200-500ms
        // after the page visually stops scrolling. Scanning too early captures
        // pre-scroll coordinates, producing highlights at stale positions.
        scheduleScan(after: 0.75)
    }

    /// Every AX-observer notification lands here and is debounced into a single
    /// coalesced scan. Window move/resize/destroy are also forwarded to the
    /// overlay layer (it needs to clear stale annotations immediately, not wait
    /// for the rescan).
    private func handleAXNotification(_ notification: String, pid: pid_t) {
        guard isRunning else { return }
        // The kAX*Notification constants are already typed `String` in the SDK,
        // so the case patterns match them directly (no `as String` cast).
        switch notification {
        case kAXWindowMovedNotification,
             kAXWindowResizedNotification,
             kAXWindowMiniaturizedNotification,
             kAXValueChangedNotification,
             kAXTitleChangedNotification:
            // Geometry, a watched text element, OR the window title changed under
            // the annotations. The title case is the browser tab-switch /
            // navigation signal: the page under our highlights is replaced even
            // though the old tab's AX elements keep their frames, so hide that
            // pid's layer immediately. The coalesced rescan re-presents the new
            // content. (The 5 Hz cull's title check is the backstop for when this
            // notification isn't delivered.)
            onWindowEvent?(pid)
        case kAXFocusedWindowChangedNotification,
             kAXMainWindowChangedNotification:
            // Focus moved to a different window: re-point the window-level
            // subscriptions, and clear now — the highlights belonged to the old
            // window. The coalesced rescan re-anchors panels for the new one.
            reattachFocusedWindow(pid: pid)
            onWindowEvent?(pid)
        default:
            break
        }
        scheduleScan(after: Self.eventDebounce)
    }

    // MARK: - Tier 1/2: Accessibility, frontmost app

    func scanFrontmost() async {
        isScanning = true
        defer {
            isScanning = false
            if self.pendingScrollSettle {
                self.pendingScrollSettle = false
                self.onScrollActivity?(false)
            }
        }
        let front = NSWorkspace.shared.frontmostApplication
        // Remember the last non-self frontmost app so a rescan triggered while
        // our own menu panel is frontmost still targets the app the user is
        // reading (this map was previously never populated).
        if let front, front.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalApp = front
        }
        var target = front
        if target?.bundleIdentifier == Bundle.main.bundleIdentifier {
            target = lastExternalApp
        }
        await scanApp(target)
    }

    private func scanApp(_ target: NSRunningApplication?) async {
        guard isRunning, !isAsleep else { return }
        guard let target, let bundleID = target.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier else { return }

        let app = RunningApp(
            pid: target.processIdentifier,
            bundleID: bundleID,
            name: target.localizedName ?? bundleID
        )

        guard AX.isTrusted else {
            Self.log.notice("scan skipped: accessibility not granted")
            onPermissionState?(true, false)
            return
        }
        onPermissionState?(false, false)

        let isBrowser = browsers.isBrowser(bundleID)

        // The companion extension is feeding this browser's text + positions.
        // Skip the slow AX text walk and the empty→nudge→retry→OCR cascade
        // entirely (that path is the ~3s cold-start latency); the extension
        // paints instantly. Still send the cheap, idempotent a11y nudge so the
        // AXWebArea exists for the coordinate mapper's accurate path — nothing
        // waits on it. A canvas-editor fallback clears ownership, so Docs still
        // takes the AX path below.
        if isBrowser, let owned = extensionOwned[bundleID],
           Date().timeIntervalSince(owned) < Self.extTTL {
            browsers.prepareAccessibility(for: app)
            attachWindowObserversOnly(for: app.pid)
            return
        }

        if isBrowser { browsers.prepareAccessibility(for: app) }

        // The AX tree walk runs off the main thread exactly as before — it can
        // touch thousands of elements on a busy page and must not block UI.
        let source = axSource
        let axStart = DispatchTime.now()
        let result = await Task.detached(priority: .userInitiated) {
            source.acquire(from: app, browserMode: isBrowser)
        }.value
        let axWalkMs = Int(Double(DispatchTime.now().uptimeNanoseconds - axStart.uptimeNanoseconds) / 1_000_000)

        Self.log.notice("scan \(app.name, privacy: .public) browser=\(isBrowser) blocks=\(result.blocks.count) host=\(result.webHost ?? "-", privacy: .public) axWalkMs=\(axWalkMs)")

        let minWords = SettingsSnapshot.current().minWords
        let totalWords = result.blocks.reduce(0) { $0 + TextMetrics.wordCount($1.text) }
        let scoreable = totalWords >= minWords
        
        if !result.blocks.isEmpty {
            attachObservers(for: app.pid, blocks: result.blocks)
            
            // FIX: Only dispatch onBlocks if the tree actually contains scoreable text.
            // If Electron's AX tree is temporarily unrendered during scroll (exposing only
            // UI chrome), dispatching this would result in a fully `.safe` evaluation,
            // which causes MenuBarManager to present an empty flagged list, destroying
            // all existing panels instantly.
            if scoreable {
                let domain = result.webHost ?? "app:\(app.bundleID)"
                onBlocks?(result.blocks, app, domain, isBrowser ? .browser : .native)
            }
        } else {
            attachWindowObserversOnly(for: app.pid)
        }

        if scoreable {
            // A useful read re-arms the empty-scan fast retry
            retriedPIDs.remove(app.pid)
            return
        }

        // Functionally empty: many apps (Chromium, Electron, Firefox) only
        // build their accessibility tree once a client announces itself — and
        // some Electron builds need the nudge re-sent per window. Re-nudge on
        // every such pass (two cheap AX writes); fast retry only the first
        // time. If the app still exposes nothing scoreable, fall back to OCR.
        BrowserIntegrationService.nudgeAccessibility(pid: app.pid)
        if !retriedPIDs.contains(app.pid) {
            retriedPIDs.insert(app.pid)
            // Shorter retry than before: the activation-time nudge has already
            // given the lazy AX tree a head start, so it is usually ready sooner.
            scheduleScan(after: 0.6)
        } else {
            await ocrFallback(for: app)
        }
    }

    // MARK: - AX observers (LRU of at most `maxObservers`)

    /// Ensure a live observer for `pid`, (re)subscribe its structural and
    /// window-level notifications, and refresh the per-scan AXValueChanged set
    /// to the just-scanned blocks' anchors.
    private func attachObservers(for pid: pid_t, blocks: [AcquiredBlock]) {
        guard let observer = observer(for: pid) else { return }

        // App-element notifications: focus/title/activation/structure changes.
        let appElement = AX.appElement(pid: pid)
        for notification in Self.appNotifications {
            observer.observe(notification, on: appElement)
        }

        // Window-level notifications on the currently focused window.
        reattachFocusedWindow(pid: pid, using: observer)

        // TEXT_BLOCK_CHANGED: watch up to N of this scan's text elements. Swap
        // the previous scan's set out first so we never accumulate stale
        // subscriptions as the page changes.
        observer.cancelAll(notification: kAXValueChangedNotification)
        var watched = 0
        for block in blocks {
            guard watched < Self.maxValueAnchors else { break }
            guard let anchor = block.anchor else { continue }
            observer.observe(kAXValueChangedNotification, on: anchor)
            watched += 1
        }
    }

    /// Window-geometry subscription alone, for apps whose AX tree exposes no
    /// text (see the empty-scan branch above). Deliberately skips the
    /// app-level notification set AND the AXValueChanged anchors — there is
    /// no text to watch, and app-level churn from a nudged Electron process
    /// must not reach `handleAXNotification`'s rescan path on a loop.
    private func attachWindowObserversOnly(for pid: pid_t) {
        guard let observer = observer(for: pid) else { return }
        // Drop any app-level set left from a previous text-bearing scan of
        // this pid (apps can go AX-blind on navigation); the next successful
        // scan re-subscribes everything via `attachObservers`.
        for notification in Self.appNotifications {
            observer.cancelAll(notification: notification)
        }
        observer.cancelAll(notification: kAXValueChangedNotification)
        reattachFocusedWindow(pid: pid, using: observer)
    }

    /// (Re)subscribe the window-level notifications to the app's current
    /// focused window, dropping the previous window's set. Called on first
    /// attach and whenever focus moves between windows.
    private func reattachFocusedWindow(pid: pid_t, using existing: AXEventObserver? = nil) {
        guard let observer = existing ?? observerIfPresent(for: pid) else { return }
        // Drop the old window's subscriptions (they were registered under these
        // same notification names, so a name-scoped cancel is exactly right).
        for notification in Self.windowNotifications {
            observer.cancelAll(notification: notification)
        }
        guard let window = AX.focusedWindow(pid: pid) else {
            focusedWindowByPID[pid] = nil
            return
        }
        focusedWindowByPID[pid] = window
        for notification in Self.windowNotifications {
            observer.observe(notification, on: window)
        }
    }

    /// Fetch or create the observer for `pid`, moving it to the front of the
    /// LRU. Creating a fifth observer evicts (and invalidates) the least
    /// recently used one.
    private func observer(for pid: pid_t) -> AXEventObserver? {
        if let index = observers.firstIndex(where: { $0.pid == pid }) {
            let entry = observers.remove(at: index)
            observers.insert(entry, at: 0)
            return entry.observer
        }
        guard let created = AXEventObserver(pid: pid, handler: { [weak self] notification, _ in
            self?.handleAXNotification(notification, pid: pid)
        }) else { return nil }
        observers.insert((pid, created), at: 0)
        while observers.count > Self.maxObservers {
            let evicted = observers.removeLast()
            evicted.observer.invalidate()
            focusedWindowByPID[evicted.pid] = nil
        }
        return created
    }

    /// Lookup without creating or reordering — for handlers that should only
    /// act on an app we are already watching.
    private func observerIfPresent(for pid: pid_t) -> AXEventObserver? {
        observers.first { $0.pid == pid }?.observer
    }

    private static let appNotifications: [String] = [
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
        kAXWindowCreatedNotification,
        kAXFocusedUIElementChangedNotification,
        // Browser tab switches / navigation retitle the window → DOMAIN_CHANGED.
        kAXTitleChangedNotification,
        kAXApplicationActivatedNotification,
        kAXApplicationDeactivatedNotification,
    ]

    private static let windowNotifications: [String] = [
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXWindowMiniaturizedNotification,
    ]

    // MARK: - Tier 3: OCR, whole screen, event-gated fallback

    /// Whole-screen OCR, run only because an AX scan of the frontmost app came
    /// back empty after the nudge + retry. Gated by: not already in flight,
    /// machine awake, and at least `ocrCooldown` since the last OCR pass for
    /// this bundle id. If an event fires during the cooldown, a trailing pass
    /// is queued to ensure the final state is captured.
    private func ocrFallback(for app: RunningApp) async {
        guard isRunning, !isAsleep else { return }
        
        let bundleID = app.bundleID
        
        if let last = lastOCRByBundle[bundleID] {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < Self.ocrCooldown {
                // Inside the cooldown window. Queue a trailing scan if one isn't already queued.
                if pendingOCRByBundle[bundleID] == nil {
                    let delay = Self.ocrCooldown - elapsed
                    pendingOCRByBundle[bundleID] = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        guard !Task.isCancelled else { return }
                        self?.pendingOCRByBundle[bundleID] = nil
                        await self?.executeOCR(for: app)
                    }
                }
                return
            }
        }

        await executeOCR(for: app)
    }

    private func executeOCR(for app: RunningApp) async {
        guard isRunning, !isAsleep, !ocrInFlight else { return }

        // Preflight Screen Recording without prompting; ask the system exactly
        // once, then surface a calm fix-it row if declined.
        guard CGPreflightScreenCaptureAccess() else {
            if !requestedScreenCapture {
                requestedScreenCapture = true
                CGRequestScreenCaptureAccess()
            } else {
                onPermissionState?(false, true)
            }
            return
        }
        onPermissionState?(false, false)

        lastOCRByBundle[app.bundleID] = Date()
        ocrInFlight = true
        defer { ocrInFlight = false }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ocr = ocrSource
        do {
            let blocks = try await ocr.acquireWholeScreen(excludingPID: ownPID)
            Self.log.notice("ocr-fallback blocks=\(blocks.count)")
            // TCC quirk: a Screen Recording grant given while the app runs
            // doesn't take effect until relaunch — captures show wallpaper
            // only. Detect the symptom so the log explains itself.
            if blocks.isEmpty {
                let visibleOthers = NSWorkspace.shared.runningApplications
                    .filter { $0.activationPolicy == .regular && !$0.isHidden }.count
                if visibleOthers > 1 {
                    Self.log.notice("ocr-fallback saw no text with \(visibleOthers) visible apps — if persistent, the Screen Recording grant may need an app relaunch")
                }
            }
            guard !blocks.isEmpty else { return }
            // OCR text is attributed to the app that triggered the fallback —
            // the frontmost, AX-blind one the user is actually reading. That
            // identity is what lets provenance recognize AI-chat desktop apps
            // (Claude, ChatGPT) and what keys per-app calibration; the price
            // is that any other window peeking around it shares the
            // attribution, which the whole-screen capture always implied.
            // The `.ocr` source still routes panels to the floating
            // screen-level overlay layer, so nothing window-tracks.
            onBlocks?(blocks, app, "app:\(app.bundleID)", .ocr)
        } catch {
            Self.log.notice("ocr-fallback failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
