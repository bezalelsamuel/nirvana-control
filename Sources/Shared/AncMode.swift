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
