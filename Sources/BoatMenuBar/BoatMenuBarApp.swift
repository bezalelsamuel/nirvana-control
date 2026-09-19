import SwiftUI
import AppKit

@main
struct BoatMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var device = DeviceManager.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(device: device)
        } label: {
            Image(systemName: statusIcon)
        }
        .menuBarExtraStyle(.window)
    }

    /// The icon doubles as an ANC indicator so the current mode is readable
    /// without opening the panel.
    private var statusIcon: String {
        device.isConnected ? device.ancMode.symbol : "waveform.circle"
    }
}

/// Receives `nirvanacontrol://` links. A delegate rather than `.onOpenURL`,
/// because a MenuBarExtra's view only exists while its panel is open, and a
/// link can arrive at any time — including the one that launched the app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            DeviceManager.shared.handleLink(url)
        }
    }
}
