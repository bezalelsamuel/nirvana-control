import Foundation

/// Byte-level protocol for boAt earbuds on the "wuqi" chipset SDK, reverse
/// engineered from com.boAt.hearables:
///   - `defpackage/lt1.java`  — command table and checksum
///   - `defpackage/boe.java`  — command builders (ANC, EQ, toggles)
///   - `defpackage/yne.java`  — frame parser
/// Transport is classic Bluetooth RFCOMM on the service advertising UUID
/// 0x7034.
///
/// Frame layout:
///
///     [0..4]  fixed header      08 EE 00 00 00
///     [5..6]  command id        e.g. 02 05 for ANC
///     [7]     total frame length (header through checksum)
///     [8]     reserved, always 00
///     [9...]  payload
///     [last]  checksum = sum of all preceding bytes, low byte
enum WuqiProtocol {
    static let header: [UInt8] = [0x08, 0xEE, 0x00, 0x00, 0x00]

    static func frame(command: (UInt8, UInt8), payload: [UInt8]) -> [UInt8] {
        var bytes = header
        bytes.append(command.0)
        bytes.append(command.1)
        bytes.append(UInt8(header.count + 2 + 1 + 1 + payload.count + 1))
        bytes.append(0x00)
        bytes.append(contentsOf: payload)
        bytes.append(checksum(bytes))
        return bytes
    }

    static func checksum(_ bytes: [UInt8]) -> UInt8 {
        UInt8(bytes.reduce(0) { $0 + Int($1) } & 0xFF)
    }

    // MARK: - Commands
    //
    // Every entry here is traced to a named, user-facing action in the app.
    // Do not add a command without doing the same: `05 01` looked like a
    // harmless info query and is in fact Factory Reset (`boe.O()`, reached
    // from the "Factory Reset" flow in `mtb.java`). It wiped a real device.

    enum Command {
        /// `boe.P(String ancMode)` — 0 = DEFAULT, 1 = ANC, 2 = AMBIENT.
        static let anc: (UInt8, UInt8) = (0x02, 0x05)
        /// `boe.J()` ← `a.q5()` ← the "Ear Detect" switch.
        static let inEarDetection: (UInt8, UInt8) = (0x02, 0x04)
        /// `boe.Y()` / `boe.p()` — preset id + band gains per earbud.
        static let equalizer: (UInt8, UInt8) = (0x03, 0x81)
        /// `boe.i()` — battery read; the reply feeds getLeft/RightBattery.
        static let queryBattery: (UInt8, UInt8) = (0x01, 0x05)
        /// `boe.G()` — TWS (both-buds-connected) status read.
        static let queryTwsStatus: (UInt8, UInt8) = (0x01, 0x04)
        /// `boe.w()` — ANC mode read, used by the official app's notification
        /// to show the current mode. Parsed as ANC_STATUS (`toe.d()`).
        static let queryAncStatus: (UInt8, UInt8) = (0x01, 0x0C)
        /// `boe.B()` — in-ear detection read, sent when the official app's
        /// device settings screen loads. Parsed as GET_INEAR (`toe.b()`).
        static let queryInEarStatus: (UInt8, UInt8) = (0x01, 0x09)
    }

    /// The value in a status reply: `toe.d()` / `toe.b()` read the byte just
    /// before the checksum — the last payload byte, not the first.
    static func statusValue(_ message: WuqiMessage) -> UInt8? {
        message.payload.last
    }

    /// Command ids the earbuds use when reporting state. Decode-only — these
    /// are never transmitted.
    enum NotificationCommand {
        static let twsStatus: (UInt8, UInt8) = (0x01, 0x04)
        static let battery: (UInt8, UInt8) = (0x01, 0x05)
        static let spatialStatus: (UInt8, UInt8) = (0x01, 0x0B)
        static let ancStatus: (UInt8, UInt8) = (0x01, 0x0C)
    }

    static func ancFrame(_ mode: AncMode) -> [UInt8] {
        frame(command: Command.anc, payload: [mode.rawValue])
    }

    static func inEarDetectionFrame(enabled: Bool) -> [UInt8] {
        frame(command: Command.inEarDetection, payload: [enabled ? 1 : 0])
    }


    static func queryFrame(_ command: (UInt8, UInt8)) -> [UInt8] {
        frame(command: command, payload: [])
    }

    /// EQ frame (`boe.p()`): 32 bytes — a preset id, then ten band gains
    /// repeated once per earbud.
    ///
    /// The app has a second, 20-byte encoding (`boe.q()`) and picks between
    /// them per model from a value in its runtime database, so the APK alone
    /// can't settle it. Testing on the Nirvana Ion ANC did: builds sending only
    /// the 20-byte frame had no audible effect, while builds that sent this
    /// one did. Preset id 5 is what `p()` emits for a curve that isn't one of
    /// its named presets.
    static func eqFrame(gains: [Int8]) -> [UInt8] {
        let encoded = (0..<10).map { index in
            encodeGain(index < gains.count ? gains[index] : 0)
        }
        var payload: [UInt8] = [5, 0x03]
        payload.append(contentsOf: encoded) // left earbud
        payload.append(contentsOf: encoded) // right earbud
        return frame(command: Command.equalizer, payload: payload)
    }

    /// Gains run -8...+8 dB and are sent with a +120 bias (`boe.n()`).
    static func encodeGain(_ gain: Int8) -> UInt8 {
        UInt8(max(-8, min(8, Int(gain))) + 120)
    }

    static func decodeGain(_ byte: UInt8) -> Int {
        Int(byte) - 120
    }

    /// Command ids as a single comparable value — Swift can't pattern-match
    /// a `switch` against tuple constants.
    static func key(_ command: (UInt8, UInt8)) -> UInt16 {
        UInt16(command.0) << 8 | UInt16(command.1)
    }

    // MARK: - Labels

    enum Direction { case sent, received }

    /// A human-readable name for a frame, worked out from its bytes alone.
    ///
    /// Used for the saved log. Deriving it from the bytes (rather than from
    /// what the calling code meant to send) means the label can never
    /// disagree with what actually crossed the wire.
    static func describe(_ frame: [UInt8], direction: Direction) -> String {
        guard frame.count >= 10 else {
            return "Unrecognised fragment (\(frame.count) bytes)"
        }
        let command = (frame[5], frame[6])
        let id = key(command)
        let payload = Array(frame[9..<(frame.count - 1)])
        let checksumOK = checksum(Array(frame.dropLast())) == frame.last
        let suffix = checksumOK ? "" : "  [checksum mismatch]"

        func mode(_ byte: UInt8?) -> String {
            byte.flatMap { AncMode(rawValue: $0)?.label } ?? "unknown value \(byte.map(String.init) ?? "-")"
        }

        let body: String
        switch id {
        case key(Command.anc):
            body = direction == .sent
                ? "ANC command → \(mode(payload.first))"
                : "ANC acknowledgement → \(mode(payload.first))"

        case key(Command.inEarDetection):
            body = "In-ear detection command → \(payload.first == 1 ? "On" : "Off")"

        case key(Command.equalizer) where direction == .received:
            // The earbuds answer each EQ frame with a short `09 FF …` frame
            // under the same command id — an acknowledgement, not a curve.
            body = "EQ acknowledgement"

        case key(Command.equalizer):
            // Payload is [presetID, 0x03, left × 10, right × 10]; the first
            // eight gains are the bands this model uses.
            let gains = payload.dropFirst(2).prefix(bandCount).map { Int8(clamping: decodeGain($0)) }
            let name = EqPreset.matching(Array(gains)).map { "preset \($0.label)" } ?? "custom curve"
            body = "EQ command → \(name) \(gains.map(String.init).joined(separator: " "))"

        case key(Command.queryBattery) where direction == .sent:
            body = "Battery query"

        case key(NotificationCommand.battery):
            var levels: [String] = []
            // 0 for a bud means it's in the case or off (the official app
            // shows it with no percentage).
            if payload.count >= 1 { levels.append(payload[0] == 0 ? "L not in use (0)" : "L \(payload[0])%") }
            if payload.count >= 2 { levels.append(payload[1] == 0 ? "R not in use (0)" : "R \(payload[1])%") }
            if payload.count >= 3 {
                // 0 is the earbuds' "no reading" (see DeviceManager).
                levels.append(payload[2] == 0 ? "Case no reading (0)" : "Case \(payload[2])%")
            }
            body = "Battery reply → \(levels.isEmpty ? "no data" : levels.joined(separator: ", "))"

        case key(NotificationCommand.twsStatus):
            if direction == .sent {
                body = "TWS status query"
            } else if frame.count == 13 {
                // `toe.q()` case 11: byte 9 is 1 when both buds are linked.
                body = "TWS status reply → \(payload.first == 1 ? "both buds linked" : "one bud in use")"
            } else {
                body = "TWS status reply (\(frame.count) bytes, not decoded)"
            }

        case key(NotificationCommand.ancStatus):
            body = direction == .sent
                ? "ANC status query"
                : "ANC status report → \(mode(payload.last))"

        case key(Command.queryInEarStatus):
            body = direction == .sent
                ? "In-ear detection status query"
                : "In-ear detection status → \(payload.last.map { $0 != 0 ? "On" : "Off" } ?? "no data")"

        case key(NotificationCommand.spatialStatus):
            body = "Spatial audio status report"

        case key((0x05, 0x01)):
            // Never sent by this app — labelled so it stands out if it ever
            // appears. See the note above `Command`.
            body = "⚠️ FACTORY RESET command"

        default:
            body = String(format: "Unknown command %02X %02X", command.0, command.1)
        }
        return body + suffix
    }

    /// The eight bands this chipset exposes, in transmission order
    /// (`EqRepository.saveFreqArraysForSDK`, sdk 7). Two further slots exist
    /// in the frame but are unused and sent flat.
    static let bandFrequencies = [100, 200, 400, 800, 1600, 3200, 6400, 12800]
    static let bandCount = 8
    static let gainRange: ClosedRange<Int8> = -8...8
}

/// Curves for the eight bands this chipset exposes. boAt keeps its per-model
/// preset curves in a runtime database rather than in the APK, so these are
/// our own, shaped after the seven-band curves the app ships for sibling
/// models (`defpackage/p70`) and re-spread across this model's bands.
enum EqPreset: String, CaseIterable, Identifiable, Hashable {
    case signature = "Signature"
    case bassBoost = "Bass Boost"
    case trebleBoost = "Treble Boost"
    case vocal = "Vocal"
    case balanced = "Balanced"
    case rock = "Rock"
    case pop = "Pop"
    case club = "Club"

    var id: String { rawValue }
    var label: String { rawValue }

    //                        100  200  400  800  1.6k 3.2k 6.4k 12.8k
    var gains: [Int8] {
        switch self {
        case .signature:   return [ 0,   0,   0,   0,   0,   0,   0,   0]
        case .bassBoost:   return [ 6,   5,   3,   1,   0,   0,   0,   0]
        case .trebleBoost: return [ 0,   0,   0,   0,   1,   3,   5,   6]
        case .vocal:       return [-3,  -2,   0,   3,   4,   3,   1,  -1]
        case .balanced:    return [-3,  -3,   0,   0,  -2,  -3,  -3,  -3]
        case .rock:        return [ 5,   4,   1,  -1,  -1,   2,   4,   4]
        case .pop:         return [-2,   0,   2,   3,   2,   1,   2,   3]
        case .club:        return [ 3,   2,   3,   1,   3,   3,   3,   2]
        }
    }

    /// The preset whose curve matches these gains, or nil for a hand-tuned
    /// curve that matches none of them.
    static func matching(_ gains: [Int8]) -> EqPreset? {
        allCases.first { $0.gains == gains }
    }

    /// A name for a saved preset: trimmed, defaulted when empty, and numbered
    /// if it would clash (case-insensitively) with any `taken` name, so every
    /// entry in the picker is distinguishable. "My Preset 1" clashing gives
    /// "My Preset 2", not "My Preset 1 2".
    static func uniqueName(_ proposed: String, taken: [String]) -> String {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "My Preset" : trimmed
        let takenSet = Set(taken.map { $0.lowercased() })
        guard takenSet.contains(base.lowercased()) else { return base }

        var stem = base
        if let last = base.split(separator: " ").last, Int(last) != nil, base.contains(" ") {
            stem = String(base.dropLast(last.count)).trimmingCharacters(in: .whitespaces)
        }
        var n = 2
        while takenSet.contains("\(stem) \(n)".lowercased()) { n += 1 }
        return "\(stem) \(n)"
    }
}

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
}

/// A frame received from the earbuds.
struct WuqiMessage {
    let command: (UInt8, UInt8)
    let payload: [UInt8]
    let raw: [UInt8]
}

/// Splits the incoming RFCOMM byte stream into frames using the length byte
/// at index 7 (mirrors `yne.j()`).
final class WuqiFrameDecoder {
    private var buffer: [UInt8] = []

    func feed(_ bytes: [UInt8]) -> [WuqiMessage] {
        buffer.append(contentsOf: bytes)
        var messages: [WuqiMessage] = []

        while buffer.count >= 8 {
            let length = Int(buffer[7])
            // No frame this protocol defines is shorter than 10 bytes or
            // longer than the 32-byte EQ frame; anything outside that means
            // we're misaligned, so slide forward a byte and try again.
            guard (10...64).contains(length) else {
                buffer.removeFirst()
                continue
            }
            guard buffer.count >= length else { break }

            let frame = Array(buffer[0..<length])
            buffer.removeFirst(length)
            let payload = length > 9 ? Array(frame[9..<(length - 1)]) : []
            messages.append(WuqiMessage(command: (frame[5], frame[6]), payload: payload, raw: frame))
        }
        return messages
    }

    func reset() {
        buffer.removeAll()
    }
}
