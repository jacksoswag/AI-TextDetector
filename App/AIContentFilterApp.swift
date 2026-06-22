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
            MenuBarLabel(settings: manager.settings, license: manager.license)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu-bar glyph. Slashed whenever Veritas is not actively watching: the
/// master switch is off, or no license is active. A paused or unlicensed state
/// shows at a glance instead of detection just going quiet. Observes both nested
/// stores directly, since a nested ObservableObject doesn't republish through the
/// parent manager.
private struct MenuBarLabel: View {
    @ObservedObject var settings: SettingsManager
    @ObservedObject var license: LicenseManager

    var body: some View {
        SlashedIcon(systemName: "text.viewfinder", isSlashed: !settings.isEnabled || !license.isActive)
            .accessibilityLabel("Veritas")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MenuBarManager.shared.bootstrap()
    }
}
