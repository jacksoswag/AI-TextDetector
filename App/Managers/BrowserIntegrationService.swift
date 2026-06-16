import AppKit
import ApplicationServices

/// Browser awareness for the Accessibility pipeline. Browsers ARE scanned
/// (that's the primary text surface); this service knows which apps qualify
/// and how to coax Chromium into exposing web content to Accessibility.
final class BrowserIntegrationService {

    /// Chromium builds web-content accessibility lazily: it only constructs
    /// the AX tree for page content once an assistive client announces itself
    /// by setting this attribute on the application element.
    private static let chromiumIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.microsoft.edgemac", "com.brave.Browser",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    private static let browserBundleIDs: Set<String> = chromiumIDs.union([
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "org.mozilla.firefox",   // AX coverage of web content is partial
    ])

    private var preparedPIDs = Set<pid_t>()

    func isBrowser(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return Self.browserBundleIDs.contains(bundleID)
    }

    /// Ask Chromium-family browsers to build their web-content AX tree before
    /// the first walk. Safari exposes it unconditionally.
    func prepareAccessibility(for app: RunningApp) {
        guard Self.chromiumIDs.contains(app.bundleID),
              !preparedPIDs.contains(app.pid) else { return }
        preparedPIDs.insert(app.pid)
        Self.nudgeAccessibility(pid: app.pid)
    }

    /// Generic accessibility wake-up call, sent to ANY app whose first scan
    /// finds nothing: Chromium honors AXEnhancedUserInterface, Electron apps
    /// (Claude, Slack, VS Code…) require AXManualAccessibility, Firefox
    /// initializes its a11y engine when poked. Harmless for everyone else.
    static func nudgeAccessibility(pid: pid_t) {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}
