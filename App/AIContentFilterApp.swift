import SwiftUI
import FilterCore

/// Menu-bar-only app (LSUIElement = true in Info.plist: no Dock icon, no main
/// window). The entire product surface is the MenuBarExtra panel.
@main
struct AIContentFilterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var manager = MenuBarManager.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView()
                .environmentObject(manager)
        } label: {
            SlashedIcon(systemName: "text.viewfinder", isSlashed: !manager.settings.isEnabled)
                .accessibilityLabel("Veritas")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MenuBarManager.shared.bootstrap()
    }
}
