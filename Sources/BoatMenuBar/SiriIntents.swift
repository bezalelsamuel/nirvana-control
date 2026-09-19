import AppIntents

/// The Siri / Shortcuts action. It runs inside the app, which owns the
/// Bluetooth connection, so it acts directly rather than signalling the app
/// as the sandboxed widget has to.
struct SetNoiseControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Noise Control"
    static var description = IntentDescription("Switches your boAt earbuds between Off, ANC and Ambient.")
    static var openAppWhenRun = false

    @Parameter(title: "Mode")
    var mode: AncModeAppEnum

    init() {}
    init(mode: AncModeAppEnum) { self.mode = mode }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch DeviceManager.shared.requestAncMode(mode.mode) {
        case .applied:
            return .result(dialog: "Noise control set to \(mode.label).")
        case .connecting:
            return .result(dialog: "Connecting to your earbuds and switching to \(mode.label).")
        case .notLinked:
            return .result(dialog: "Your earbuds aren't connected to this Mac.")
        }
    }
}

/// The phrases Siri listens for. Apple requires the app's name in each one.
struct NirvanaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SetNoiseControlIntent(),
            phrases: [
                "Set \(.applicationName) to \(\.$mode)",
                "Switch \(.applicationName) to \(\.$mode)",
                "Turn on \(\.$mode) in \(.applicationName)",
                "Set noise control to \(\.$mode) in \(.applicationName)",
                "Change noise control in \(.applicationName)"
            ],
            shortTitle: "Noise Control",
            systemImageName: "waveform"
        )
    }
}
