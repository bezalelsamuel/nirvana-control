import SwiftUI

@main
struct BoatMenuBarApp: App {
    @StateObject private var device = DeviceManager()

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
        guard device.isConnected else { return "waveform.circle" }
        switch device.ancMode {
        case .off: return "waveform"
        case .on: return "waveform.badge.minus"
        case .transparency: return "waveform.badge.plus"
        }
    }
}
