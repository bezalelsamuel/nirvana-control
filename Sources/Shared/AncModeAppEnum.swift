import AppIntents

/// Noise-control modes as App Intents sees them — used by the widget's
/// buttons and by the app's Siri / Shortcuts action.
enum AncModeAppEnum: String, AppEnum {
    case off, on, transparency

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Noise Control Mode")
    static var caseDisplayRepresentations: [AncModeAppEnum: DisplayRepresentation] = [
        .off: DisplayRepresentation(title: "Off", synonyms: ["noise control off"]),
        .on: DisplayRepresentation(title: "ANC", synonyms: ["noise cancelling", "noise cancellation", "active noise cancellation"]),
        .transparency: DisplayRepresentation(title: "Ambient", synonyms: ["ambient mode", "transparency", "transparency mode"])
    ]

    var command: SharedState.Command {
        switch self {
        case .off: return .ancOff
        case .on: return .ancOn
        case .transparency: return .ancTransparency
        }
    }

    /// The shared mode this intent value stands for; labels and icons come
    /// from there. (The display names above stay as literals because App
    /// Intents reads them at build time.)
    var mode: AncMode {
        switch self {
        case .off: return .off
        case .on: return .on
        case .transparency: return .transparency
        }
    }

    var label: String { mode.label }
    var symbol: String { mode.symbol }
}
