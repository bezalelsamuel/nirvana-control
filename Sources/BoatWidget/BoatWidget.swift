import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Intents
//
// These run inside the widget extension, which is sandboxed and can't touch
// Bluetooth. Each one just signals the running menu bar app, which owns the
// RFCOMM connection and does the actual work.

struct SetAncModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Noise Control"
    static var description = IntentDescription("Switches the earbuds between Off, ANC and Ambient.")

    @Parameter(title: "Mode")
    var mode: AncModeAppEnum

    init() {}
    init(mode: AncModeAppEnum) { self.mode = mode }

    func perform() async throws -> some IntentResult {
        SharedState.post(mode.command)
        return .result()
    }
}

enum AncModeAppEnum: String, AppEnum {
    case off, on, transparency

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Noise Control Mode")
    static var caseDisplayRepresentations: [AncModeAppEnum: DisplayRepresentation] = [
        .off: "Off",
        .on: "ANC",
        .transparency: "Ambient"
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

// MARK: - Timeline

struct BoatEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedState.Snapshot
}

struct BoatProvider: TimelineProvider {
    func placeholder(in context: Context) -> BoatEntry {
        BoatEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (BoatEntry) -> Void) {
        completion(BoatEntry(date: Date(), snapshot: SharedState.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BoatEntry>) -> Void) {
        let entry = BoatEntry(date: Date(), snapshot: SharedState.read())
        // The app reloads us whenever state changes; this is just a backstop.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(600))))
    }
}

// MARK: - View

struct BoatWidgetView: View {
    var entry: BoatEntry
    @Environment(\.widgetFamily) private var family

    private var snapshot: SharedState.Snapshot { entry.snapshot }
    private var isMedium: Bool { family == .systemMedium }

    private var activeMode: AncModeAppEnum {
        switch AncMode(rawValue: UInt8(clamping: snapshot.ancModeRawValue)) {
        case .on: return .on
        case .transparency: return .transparency
        case .off, nil: return .off
        }
    }

    // Header at the top; the tiles take every point below it, so there's no
    // dead gap and they fit whatever size the system gives the widget.
    var body: some View {
        VStack(alignment: .leading, spacing: isMedium ? 12 : 10) {
            header
            modeTiles
                .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        if isMedium {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                deviceName
                Spacer(minLength: 8)
                statusLine
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                deviceName
                statusLine
            }
        }
    }

    private var deviceName: some View {
        Text(snapshot.deviceName)
            .font(.system(size: isMedium ? 15 : 13, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }

    /// The one line that says what state the earbuds are in: battery when
    /// connected, the way to connect when not.
    @ViewBuilder
    private var statusLine: some View {
        let size: CGFloat = isMedium ? 12 : 11
        if !snapshot.isConnected {
            HStack(spacing: 4) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: size - 1, weight: .medium))
                Text("Tap a mode to connect")
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.secondary)
        } else if snapshot.leftBattery == nil, snapshot.rightBattery == nil, snapshot.caseBattery == nil {
            Text("Connected")
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.secondary)
        } else {
            BatteryReadout(
                left: snapshot.leftBattery,
                right: snapshot.rightBattery,
                caseLevel: snapshot.caseBattery,
                size: size
            )
        }
    }

    // MARK: Mode tiles

    private var modeTiles: some View {
        HStack(spacing: isMedium ? 8 : 5) {
            ForEach([AncModeAppEnum.off, .on, .transparency], id: \.self) { mode in
                let isActive = snapshot.isConnected && mode == activeMode
                // Never disabled: when the app isn't connected, a tap makes
                // it connect and then apply the mode.
                Button(intent: SetAncModeIntent(mode: mode)) {
                    ModeTile(mode: mode, isActive: isActive, isLarge: isMedium)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Noise control: \(mode.label)")
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }
        }
    }
}

/// One noise-control mode as a tappable tile.
private struct ModeTile: View {
    let mode: AncModeAppEnum
    let isActive: Bool
    let isLarge: Bool

    var body: some View {
        VStack(spacing: isLarge ? 6 : 5) {
            Image(systemName: mode.symbol)
                .font(.system(size: isLarge ? 26 : 21, weight: .medium))
                .frame(height: isLarge ? 28 : 23)
            Text(mode.label)
                .font(.system(size: isLarge ? 13 : 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(isActive ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.08)))
                // Keeps the active tile marked when a desktop widget drops
                // to its monochrome/accented rendering.
                .widgetAccentable(isActive)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// L / R / Case levels as separate readings: the number brightest, its tag
/// secondary, and red only when a level is low enough to act on.
private struct BatteryReadout: View {
    let left: Int?
    let right: Int?
    let caseLevel: Int?
    let size: CGFloat


    var body: some View {
        HStack(spacing: size * 0.75) {
            if let left { reading("L", left) }
            if let right { reading("R", right) }
            if let caseLevel { reading("Case", caseLevel) }
        }
        .font(.system(size: size, weight: .medium))
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private func reading(_ tag: String, _ level: Int) -> some View {
        HStack(spacing: 3) {
            Text(tag)
                .foregroundStyle(.secondary)
            Text("\(level)%")
                .monospacedDigit()
                .foregroundStyle(level <= SharedState.lowBatteryThreshold ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
        }
        .fixedSize()
    }
}

// MARK: - Widget

struct BoatWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BoatWidget", provider: BoatProvider()) { entry in
            BoatWidgetView(entry: entry)
        }
        .configurationDisplayName("Noise Control")
        .description("Switch ANC modes on your boAt earbuds.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct BoatWidgetBundle: WidgetBundle {
    var body: some Widget {
        BoatWidget()
    }
}
