import Foundation

/// The bridge between the menu bar app and its widget.
///
/// Two separate processes are involved and the widget extension is sandboxed,
/// so they can't share memory or reach the same files freely:
///
///  - **State flows app → widget** through an App Group's UserDefaults, which
///    is the one store both sides are allowed to touch.
///
///    The group ID is prefixed with the Team ID on purpose. The iOS-style
///    `group.…` form must be authorised by a provisioning profile, and a free
///    Personal Team's profiles don't carry App Groups — with that form the
///    entitlement was signed in but never honoured, and the widget read
///    nothing. macOS accepts `<TeamID>.…` groups on the signature alone.
///  - **Commands flow widget → app** as distributed notifications. A sandboxed
///    process can't attach userInfo to those, so the command is encoded in the
///    notification *name* instead.
public enum SharedState {
    public static let appGroupID = "G8N2V7JRQ3.com.local.boatmenubar"

    public static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    // MARK: - Keys

    private enum Key {
        static let connected = "shared.connected"
        static let ancMode = "shared.ancMode"
        static let deviceName = "shared.deviceName"
        static let leftBattery = "shared.leftBattery"
        static let rightBattery = "shared.rightBattery"
        static let caseBattery = "shared.caseBattery"
    }

    // MARK: - Snapshot

    public struct Snapshot {
        public var isConnected: Bool
        public var ancModeRawValue: Int
        public var deviceName: String
        public var leftBattery: Int?
        public var rightBattery: Int?
        public var caseBattery: Int?

        public init(
            isConnected: Bool,
            ancModeRawValue: Int,
            deviceName: String,
            leftBattery: Int?,
            rightBattery: Int?,
            caseBattery: Int?
        ) {
            self.isConnected = isConnected
            self.ancModeRawValue = ancModeRawValue
            self.deviceName = deviceName
            self.leftBattery = leftBattery
            self.rightBattery = rightBattery
            self.caseBattery = caseBattery
        }

        public static let placeholder = Snapshot(
            isConnected: false,
            ancModeRawValue: 0,
            deviceName: "Earbuds",
            leftBattery: nil,
            rightBattery: nil,
            caseBattery: nil
        )
    }

    public static func write(_ snapshot: Snapshot) {
        guard let defaults else { return }
        defaults.set(snapshot.isConnected, forKey: Key.connected)
        defaults.set(snapshot.ancModeRawValue, forKey: Key.ancMode)
        defaults.set(snapshot.deviceName, forKey: Key.deviceName)
        setOptional(snapshot.leftBattery, Key.leftBattery, defaults)
        setOptional(snapshot.rightBattery, Key.rightBattery, defaults)
        setOptional(snapshot.caseBattery, Key.caseBattery, defaults)
    }

    public static func read() -> Snapshot {
        guard let defaults else { return .placeholder }
        return Snapshot(
            isConnected: defaults.bool(forKey: Key.connected),
            ancModeRawValue: defaults.integer(forKey: Key.ancMode),
            deviceName: defaults.string(forKey: Key.deviceName) ?? "Earbuds",
            leftBattery: optional(Key.leftBattery, defaults),
            rightBattery: optional(Key.rightBattery, defaults),
            caseBattery: optional(Key.caseBattery, defaults)
        )
    }

    private static func setOptional(_ value: Int?, _ key: String, _ defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func optional(_ key: String, _ defaults: UserDefaults) -> Int? {
        defaults.object(forKey: key) as? Int
    }

    // MARK: - Battery text (shared so panel and widget always agree)

    /// "L 97% · R 98%" with both buds in use, just "R 98%" with one.
    /// A nil level means that bud (or the case) isn't reporting — the
    /// earbuds send 0 for a bud that's in the case or off, and the official
    /// app shows such a bud with no percentage at all.
    public static func batterySummary(left: Int?, right: Int?, caseLevel: Int?, separator: String = " · ") -> String? {
        var parts: [String] = []
        if let left {
            parts.append("L \(left)%")
        }
        if let right {
            parts.append("R \(right)%")
        }
        if let caseLevel {
            parts.append("Case \(caseLevel)%")
        }
        return parts.isEmpty ? nil : parts.joined(separator: separator)
    }

    /// At or below this a level counts as low — the official app turns a
    /// bud's reading red below 21%.
    public static let lowBatteryThreshold = 20

    /// The low-battery notification text for whichever parts are low, or nil
    /// if none are. Both buds low reads as "Your buds are low" rather than
    /// naming each one. Pass nil for a part with no live reading.
    public static func lowBatteryMessage(left: Int?, right: Int?, caseLevel: Int?) -> String? {
        func low(_ level: Int?) -> Int? {
            guard let level, level <= lowBatteryThreshold else { return nil }
            return level
        }
        let lowLeft = low(left), lowRight = low(right), lowCase = low(caseLevel)

        var subject: String
        var levels: [String] = []
        switch (lowLeft, lowRight) {
        case let (l?, r?):
            subject = "Your buds"
            levels = ["L \(l)%", "R \(r)%"]
        case let (l?, nil):
            subject = "Left bud"
            levels = ["\(l)%"]
        case let (nil, r?):
            subject = "Right bud"
            levels = ["\(r)%"]
        case (nil, nil):
            guard let c = lowCase else { return nil }
            return "Case is low — \(c)%."
        }

        if let c = lowCase {
            subject += subject == "Your buds" ? " and case" : " and the case"
            // With one bud named, spell out which number is which.
            if levels.count == 1 {
                levels = ["\(subject.hasPrefix("Left") ? "L" : "R") \(levels[0])"]
            }
            levels.append("Case \(c)%")
        }
        let verb = subject == "Left bud" || subject == "Right bud" ? "is" : "are"
        return "\(subject) \(verb) low — \(levels.joined(separator: ", "))."
    }

    // MARK: - Commands (widget → app)

    /// Command names doubling as distributed-notification names, since a
    /// sandboxed sender can't carry a payload.
    public enum Command: String, CaseIterable, Sendable {
        case ancOff = "com.local.boatmenubar.command.ancOff"
        case ancOn = "com.local.boatmenubar.command.ancOn"
        case ancTransparency = "com.local.boatmenubar.command.ancTransparency"
        case refresh = "com.local.boatmenubar.command.refresh"

        public var notificationName: Notification.Name {
            Notification.Name(rawValue)
        }
    }

    public static func post(_ command: Command) {
        DistributedNotificationCenter.default().postNotificationName(
            command.notificationName,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}
