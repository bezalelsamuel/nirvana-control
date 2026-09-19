import SwiftUI

@main
struct BoatMenuBarApp: App {
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
