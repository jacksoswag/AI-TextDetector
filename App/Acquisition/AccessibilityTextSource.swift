import AppKit
import ApplicationServices
import FilterCore
import os.log

struct AcquiredBlock {
    let text: String
    /// Cocoa screen coordinates (bottom-left origin), ready for NSPanel frames.
    let screenRect: CGRect
    let source: Source
    /// The AX element this block's text starts at — the handle that lets a
    /// highlight overlay follow its content live while the user scrolls. nil for
    /// OCR blocks (pixels have no handles).
    let anchor: AXUIElement?

    enum Source { case accessibility, ocr }

    init(text: String, screenRect: CGRect, source: Source, anchor: AXUIElement? = nil) {
        self.text = text
        self.screenRect = screenRect
        self.source = source
        self.anchor = anchor
    }
}

struct RunningApp {
    let pid: pid_t
    let bundleID: String
    let name: String
}

struct AcquisitionResult {
    let blocks: [AcquiredBlock]
    /// Page host when the scan found a web area with a URL (browsers only).
    let webHost: String?

    static let empty = AcquisitionResult(blocks: [], webHost: nil)
}

/// Tier 2: read text out of apps via the Accessibility tree. No pixels, no
/// OCR — just the strings the app already exposes, with their on-screen frames.
///
/// Browser mode: web content arrives as many small AXStaticText nodes inside
/// an AXWebArea, so the walk gets a bigger budget, fragments are clustered
/// into paragraph blocks by geometry, and the web area's AXURL provides the
/// real domain for Trusted Sites and preference learning.
struct AccessibilityTextSource {

    private static let log = os.Logger(subsystem: "dev.aicf", category: "axdump")

    private static let textRoles: Set<String> = [
        kAXStaticTextRole as String,
        kAXTextAreaRole as String,
    ]

    /// Container roles that never hold page text; skipping them keeps the
    /// traversal budget for actual content (modern web apps nest very deep).
    /// NOTE: AXTabGroup must NOT be skipped — in Safari the tab group element
    /// CONTAINS the web content, not just the tab bar.
    private static let skipRoles: Set<String> = [
        "AXToolbar", "AXMenuBar", "AXMenu", "AXScrollBar",
        "AXPopUpButton", "AXComboBox",
    ]

    func acquire(from app: RunningApp, browserMode: Bool) -> AcquisitionResult {
        guard AX.isTrusted, let window = AX.focusedWindow(pid: app.pid),
              let windowFrame = AX.frame(window) else { return .empty }

        let maxVisited = browserMode ? 6000 : 600
        let maxDepth = browserMode ? 40 : 16
        let minChars = 25

        // All displays, not just the main one — overlays must work wherever
        // the window actually is.
        let screenVisible = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        var items: [BlockClustering.Item] = []   // AX coords (top-left origin)
        var itemElements: [AXUIElement] = []     // parallel to `items`
        var webHost: String?
        var visited = 0
        var deepest = 0
        var roleCounts: [String: Int] = [:]
        var seen = Set<String>()
        let dump = UserDefaults.appGroup.bool(forKey: "debug.axDump")

        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < maxDepth, visited < maxVisited else { return }
            visited += 1
            deepest = max(deepest, depth)

            guard let role = AX.string(element, kAXRoleAttribute as String) else { return }
            if dump { roleCounts[role, default: 0] += 1 }
            if Self.skipRoles.contains(role) { return }

            if browserMode, webHost == nil, role == "AXWebArea" {
                if let value = AX.copy(element, "AXURL"), let url = value as? URL {
                    webHost = url.host?.lowercased()
                }
            }

            // Never highlight the user's own short composer input — but a LONG
            // focused editable region is a document being read (ChatGPT's
            // canvas, a generated draft), which is exactly what we scan.
            if role == kAXTextAreaRole as String,
               let focused = AX.copy(element, kAXFocusedAttribute as String) as? Bool, focused {
                let len = AX.string(element, kAXValueAttribute as String)?.count ?? 0
                if dump { Self.log.notice("focused textarea len=\(len)") }
                if len < 600 { return }   // composer-sized → skip
            }

            if Self.textRoles.contains(role),
               let value = AX.string(element, kAXValueAttribute as String),
               value.count >= minChars,
               let frame = AX.frame(element),
               frame.height >= 10, frame.width >= 60,
               frame.intersects(windowFrame) {

                let key = "\(Int(frame.minX)),\(Int(frame.minY)):\(value.hashValue)"
                if !seen.contains(key) {
                    seen.insert(key)
                    items.append(BlockClustering.Item(text: value, rect: frame))
                    itemElements.append(element)
                }
                return // text nodes rarely contain more text nodes
            }

            // Native apps: prefer the visible subset (cheap, accurate there).
            // Browsers: NEVER trust AXVisibleChildren — virtualized web apps
            // (chatgpt.com and friends) report a tiny non-empty subset and the
            // real content hides in the full child list. Frame-intersection
            // culling below keeps the walk bounded instead.
            var children: [AXUIElement] = []
            if !browserMode {
                children = AX.elements(element, kAXVisibleChildrenAttribute as String)
            }
            if children.isEmpty {
                children = AX.elements(element, kAXChildrenAttribute as String)
            }
            for child in children {
                walk(child, depth: depth + 1)
            }
        }

        walk(window, depth: 0)

        // Diagnostics, opt-in (defaults write dev.aicf.AIContentFilter debug.axDump -bool true):
        // role histogram + walk stats, no content. Text lengths only.
        if dump {
            let histogram = roleCounts.sorted { $0.value > $1.value }.prefix(10)
                .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            let lengths = items.prefix(8).map { String($0.text.count) }.joined(separator: ",")
            Self.log.notice("dump \(app.name, privacy: .public) visited=\(visited) deepest=\(deepest) textItems=\(items.count) lens=[\(lengths, privacy: .public)] roles: \(histogram, privacy: .public)")
        }

        // Always run clustering. Native apps are mostly paragraph-grained anyway, 
        // but Electron apps (Cursor, Slack, etc.) have fragmented AX trees and 
        // desperately need this to avoid falling back to OCR.
        let merged: [BlockClustering.Block] = BlockClustering.cluster(items, minChars: 40)

        let blocks: [AcquiredBlock] = merged.compactMap { block in
            let cocoaRect = block.rect.axToCocoa
            guard screenVisible.isNull
                || cocoaRect.intersects(screenVisible.insetBy(dx: -50, dy: -50)) else { return nil }
            let anchor = block.sourceIndices.first.flatMap {
                $0 < itemElements.count ? itemElements[$0] : nil
            }
            return AcquiredBlock(text: block.text, screenRect: cocoaRect,
                                 source: .accessibility, anchor: anchor)
        }

        return AcquisitionResult(blocks: blocks, webHost: webHost)
    }
}
