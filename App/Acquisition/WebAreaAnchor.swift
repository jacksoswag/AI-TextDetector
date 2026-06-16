import AppKit
import ApplicationServices
import FilterCore

/// Maps a browser tab's viewport-relative DOM rects (CSS px, from
/// getBoundingClientRect) into global Cocoa screen rects for the overlay.
///
/// Primary path (B): the page's `AXWebArea` element IS the rendered web-viewport
/// rectangle in screen coordinates — already on the correct display and already
/// accounting for whatever browser chrome (tab strip, URL/bookmarks bars) is
/// showing. We do ONE cheap shallow AX lookup for it (not the 6000-node text
/// walk), cache it per pid+window, and scale each DOM rect into it. The scale
/// ratio `webArea.width / innerWidth` absorbs Retina, page zoom, and OS display
/// zoom, so neither devicePixelRatio nor any chrome-height math ever enters the
/// transform.
///
/// Fallback (A): when no AXWebArea resolves (a not-yet-built Chromium tree, a
/// canvas surface, Firefox's partial coverage), estimate the content origin
/// purely from the window geometry the extension reports (screenX/Y, outer/inner
/// height). Less accurate — it assumes all non-content height sits above the
/// viewport — but needs no AX, so it paints the first frame with zero round-trips
/// while the tree builds. `map` reports which path it used so the caller can
/// re-map and upgrade A → B once the AXWebArea appears.
@MainActor
final class WebAreaAnchor {

    struct DOMRect { let x, y, w, h: Double }   // viewport-relative CSS px, top-left
    struct Viewport {
        let innerWidth, innerHeight: Double
        let outerWidth, outerHeight: Double
        let screenX, screenY: Double
    }
    struct Result { let rects: [CGRect]; let viaWebArea: Bool }

    /// Cached AXWebArea per pid, paired with the focused window it was found
    /// under so a different window of the same browser doesn't reuse it.
    private struct Entry { let window: AXUIElement; let webArea: AXUIElement }
    private var cache: [pid_t: Entry] = [:]
    /// Recent failed lookups, so a cold/canvas/Firefox pid doesn't re-run the
    /// full BFS on every scroll-rate post.
    private var negativeCache: [pid_t: Date] = [:]
    private static let negativeTTL: TimeInterval = 1.0
    private var screenObserver: NSObjectProtocol?

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.cache.removeAll(); self?.negativeCache.removeAll() }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    /// Map each DOM rect to a Cocoa (bottom-left origin) screen rect. `rects` is
    /// empty (and viaWebArea false) for a degenerate viewport.
    func map(pid: pid_t, viewport: Viewport, rects: [DOMRect]) -> Result {
        guard viewport.innerWidth > 0, viewport.innerHeight > 0 else {
            return Result(rects: [], viaWebArea: false)
        }
        if let viaWeb = mapViaWebArea(pid: pid, viewport: viewport, rects: rects) {
            return Result(rects: viaWeb, viaWebArea: true)
        }
        return Result(rects: mapViaScreenEstimate(viewport: viewport, rects: rects), viaWebArea: false)
    }

    /// Forget the cached AXWebArea for `pid` (tab switch / navigation handoff).
    func invalidate(pid: pid_t) {
        cache[pid] = nil
        negativeCache[pid] = nil
    }

    // MARK: Approach B — AXWebArea frame

    private func mapViaWebArea(pid: pid_t, viewport vp: Viewport, rects: [DOMRect]) -> [CGRect]? {
        guard let area = webArea(pid: pid), let web = AX.frame(area) else { return nil }  // AX top-left, global

        let sx = web.width / CGFloat(vp.innerWidth)
        let sy = web.height / CGFloat(vp.innerHeight)
        // A meaningful sx/sy disagreement means the AXWebArea frame is the full
        // document height, not the clipped viewport — its origin/scale can't be
        // trusted, so fall back to the screen estimate.
        guard sx > 0, sy > 0, abs(sx - sy) / max(sx, sy) < 0.03 else { return nil }

        return rects.map { r in
            // getBoundingClientRect is already viewport-relative — do NOT re-add scroll.
            let axRect = CGRect(
                x: web.minX + CGFloat(r.x) * sx,
                y: web.minY + CGFloat(r.y) * sy,
                width: CGFloat(r.w) * sx,
                height: CGFloat(r.h) * sy
            )
            return axRect.axToCocoa
        }
    }

    /// The cached AXWebArea for `pid` (re-validated against the live focused
    /// window) or a fresh shallow search.
    private func webArea(pid: pid_t) -> AXUIElement? {
        guard let focused = AX.focusedWindow(pid: pid) else { return nil }
        if let entry = cache[pid], CFEqual(entry.window, focused), AX.frame(entry.webArea) != nil {
            return entry.webArea
        }
        cache[pid] = nil
        if let failedAt = negativeCache[pid], Date().timeIntervalSince(failedAt) < Self.negativeTTL {
            return nil
        }
        guard let found = findWebArea(window: focused) else {
            negativeCache[pid] = Date()
            return nil
        }
        negativeCache[pid] = nil
        cache[pid] = Entry(window: focused, webArea: found)
        return found
    }

    /// Breadth-first from the focused window, depth- and visit-capped. The
    /// AXWebArea sits a few container levels down (window > group(s) > AXWebArea),
    /// reached in tens of node visits — versus the 6000-node text-walk budget.
    private func findWebArea(window: AXUIElement) -> AXUIElement? {
        let skip: Set<String> = ["AXToolbar", "AXMenuBar", "AXMenu", "AXScrollBar"]
        var frontier: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !frontier.isEmpty, visited < 150 {
            let (element, depth) = frontier.removeFirst()
            visited += 1
            if AX.string(element, kAXRoleAttribute as String) == "AXWebArea" { return element }
            guard depth < 6 else { continue }
            for child in AX.elements(element, kAXChildrenAttribute as String) {
                if let role = AX.string(child, kAXRoleAttribute as String), skip.contains(role) { continue }
                frontier.append((child, depth + 1))
            }
        }
        return nil
    }

    // MARK: Approach A — window-geometry estimate (no AX)

    private func mapViaScreenEstimate(viewport vp: Viewport, rects: [DOMRect]) -> [CGRect] {
        // Content origin in global top-left CSS px. Assumes symmetric side
        // borders and all remaining chrome above the viewport — correct in the
        // common macOS case (no bottom bar), off by a bottom bar's height when a
        // downloads/find bar is showing.
        let chromeSide = max(0, (vp.outerWidth - vp.innerWidth) / 2)
        let chromeTop = max(0, vp.outerHeight - vp.innerHeight)
        let contentLeft = vp.screenX + chromeSide
        let contentTop = vp.screenY + chromeTop
        return rects.map { r in
            CGRect(x: contentLeft + r.x, y: contentTop + r.y, width: r.w, height: r.h).axToCocoa
        }
    }
}
