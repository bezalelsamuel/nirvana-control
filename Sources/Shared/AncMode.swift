import Foundation

/// The earbuds' noise-control modes. The raw values are what goes on the wire
/// (`boe.P()`: 0 = DEFAULT, 1 = ANC, 2 = AMBIENT). Shared so the panel, the
/// menu bar icon and the widget can never disagree on a label or icon.
enum AncMode: UInt8, CaseIterable, Identifiable, Hashable {
    case off = 0
    case on = 1
    case transparency = 2

    var id: UInt8 { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .on: return "ANC"
        case .transparency: return "Ambient"
        }
    }

    var symbol: String {
        switch self {
        case .off: return "waveform"
        case .on: return "waveform.badge.minus"
        case .transparency: return "waveform.badge.plus"
        }
    }
}

// MARK: - Links

extension AncMode {
    /// The URL scheme the app registers, for Shortcuts' Open URLs action.
    static let linkScheme = "nirvanacontrol"

    /// The word in a link that picks each mode: `nirvanacontrol://anc`.
    var linkName: String {
        switch self {
        case .off: return "off"
        case .on: return "anc"
        case .transparency: return "ambient"
        }
    }

    /// The mode a `nirvanacontrol://…` link asks for, or nil for any other
    /// link. Case-insensitive, and tolerant of a trailing slash and of the
    /// `nirvanacontrol:anc` form (no `//`, so no host).
    init?(link url: URL) {
        guard url.scheme?.lowercased() == Self.linkScheme else { return nil }
        let raw = url.host ?? url.path
        let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard let mode = Self.allCases.first(where: { $0.linkName == name }) else { return nil }
        self = mode
    }
}
