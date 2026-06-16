import AppKit

/// CGWindowList helpers: map highlight overlays to the real window they cover
/// (for z-ordering) and enumerate which apps actually have windows on screen
/// (for whole-screen scanning).
enum WindowResolver {

    /// The on-screen window of `pid` that overlaps `cocoaRect` the most.
    /// Window numbers feed `NSWindow.order(.above, relativeTo:)` so a highlight
    /// panel sits directly above its content window — and below anything
    /// covering that window.
    static func windowNumber(pid: pid_t, containing cocoaRect: CGRect) -> Int? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        let primaryHeight = NSScreen.primaryHeight
        let cgRect = CGRect(x: cocoaRect.minX, y: primaryHeight - cocoaRect.maxY,
                            width: cocoaRect.width, height: cocoaRect.height)

        var best: (number: Int, area: CGFloat)?
        for info in list {
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            let overlap = bounds.intersection(cgRect)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > (best?.area ?? 0) { best = (number, area) }
        }
        return best?.number
    }

    /// PIDs of regular apps with normal-layer windows on screen, front to
    /// back. These are the scan targets for whole-screen coverage.
    static func visibleAppPIDs() -> [pid_t] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        var seen = Set<pid_t>()
        var ordered: [pid_t] = []
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let owner = info[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
                      .flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  bounds.width > 220, bounds.height > 150 else { continue }
            if seen.insert(owner).inserted { ordered.append(owner) }
        }
        return ordered
    }
}
