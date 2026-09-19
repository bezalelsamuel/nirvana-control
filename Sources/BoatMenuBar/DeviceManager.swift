import Foundation
import Combine
import AppKit
import WidgetKit
import UniformTypeIdentifiers
import ServiceManagement
import UserNotifications

/// One line in the session log.
struct LogEntry: Identifiable {
    enum Kind {
        case sent
        case received
        case info

        var arrow: String {
            switch self {
            case .sent: return "→"
            case .received: return "←"
            case .info: return "•"
            }
        }
    }

    let id = UUID()
    let date: Date
    let kind: Kind
    /// What happened, in words ("ANC command → Ambient").
    let label: String
    /// The raw frame, for sent/received entries.
    let bytes: [UInt8]?

    var hex: String? {
        bytes.map { $0.map { String(format: "%02X", $0) }.joined(separator: " ") }
    }
}

/// An EQ curve the user saved and named.
struct CustomEqPreset: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var gains: [Int8]
}

/// A choice in the preset picker: one of the built-ins or a saved one.
enum EqSelection: Hashable {
    case builtIn(EqPreset)
    case custom(UUID)
}

@MainActor
final class DeviceManager: ObservableObject {
    @Published private(set) var status: RFCOMMConnection.ConnectionStatus = .disconnected
    @Published var ancMode: AncMode = .off
    @Published private(set) var eqGains: [Int8] = Array(repeating: 0, count: WuqiProtocol.bandCount)
    @Published private(set) var customPresets: [CustomEqPreset] = []
    /// The saved preset last picked, remembered so edits to its curve can be
    /// saved back to it.
    @Published private(set) var editingCustomID: UUID?
    @Published var inEarDetection: Bool = false
    @Published private(set) var logEntries: [LogEntry] = []
    /// The earbuds we'd connect to, and whether macOS currently has a link to
    /// them — drives whether the panel offers Connect or Bluetooth Settings.
    @Published private(set) var target: Target?
    @Published private(set) var leftBattery: Int?
    @Published private(set) var rightBattery: Int?
    /// The case level to show. The earbuds can only read the case while a
    /// bud is docked, and send 0 otherwise, so this holds the last real
    /// reading rather than dropping it (see `caseReadingDate`).
    @Published private(set) var caseBattery: Int?
    /// When `caseBattery` was last actually reported by the earbuds.
    @Published private(set) var caseReadingDate: Date?
    /// Whether both buds are linked to each other; nil until the earbuds say.
    @Published private(set) var twsConnected: Bool?
    @Published var autoConnect: Bool {
        didSet { UserDefaults.standard.set(autoConnect, forKey: Self.autoConnectKey) }
    }
    /// Mirrors the app's login item, so the toggle always shows what macOS
    /// will actually do.
    @Published private(set) var openAtLogin = false
    /// Drop the earbuds' Bluetooth link when the lid closes, so they're
    /// free for the phone instead of staying tied to a closed Mac.
    @Published var disconnectOnLidClose: Bool {
        didSet { UserDefaults.standard.set(disconnectOnLidClose, forKey: Self.disconnectOnLidCloseKey) }
    }
    /// Keep the Mac's own mic as the input instead of the earbuds'.
    @Published var useMacMicrophone: Bool {
        didSet {
            UserDefaults.standard.set(useMacMicrophone, forKey: Self.useMacMicrophoneKey)
            microphoneGuard.isEnabled = useMacMicrophone
        }
    }

    struct Target: Equatable {
        let address: String
        let name: String
        let inRange: Bool
    }

    private static let lastDeviceAddressKey = "lastConnectedDeviceAddress"
    private static let eqGainsKey = "eqGains"
    private static let ancModeKey = "ancMode"
    private static let autoConnectKey = "autoConnect"
    private static let disconnectOnLidCloseKey = "disconnectOnLidClose"
    private static let useMacMicrophoneKey = "useMacMicrophone"
    private static let customPresetsKey = "customEqPresets"
    private static let caseBatteryKey = "lastCaseBattery"
    private static let caseReadingDateKey = "lastCaseReadingDate"
    private static let loginItemSetUpKey = "loginItemSetUp"
    /// Enough history to cover a long debugging session in the saved file.
    private static let maxLogEntries = 5000

    private var batteryTimer: Timer?
    /// How often to re-read battery while connected, since it drains.
    private static let batteryRefreshInterval: TimeInterval = 60
    /// Set when the user clicks Release Control, so the auto-connect timer
    /// doesn't immediately undo it. Cleared on an explicit Connect.
    private var manuallyReleased = false
    /// A widget tap that arrived while disconnected: apply that ANC mode once
    /// the connection opens, instead of reading the earbuds' current one.
    private var applyAncOnConnect = false
    /// The earbuds the lid-close disconnected, to link again on open.
    private var disconnectedByLid: String?
    private var lidReconnectRunning = false
    private static let lidReconnectAttempts = 5
    private static let lidReconnectDelay: Double = 3

    private enum BatteryPart { case left, right, caseLevel }
    /// Parts already alerted for in their current low spell, so each gets
    /// one notification rather than one per battery reading.
    private var lowBatteryAlerted = Set<BatteryPart>()
    /// A part re-arms only once it has charged back above this, so readings
    /// hovering around the threshold can't re-alert.
    private static let lowBatteryRearmLevel = 25

    var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    var isConnecting: Bool {
        switch status {
        case .connecting: return true
        default: return false
        }
    }

    private let connection = RFCOMMConnection()
    private let lidMonitor = LidMonitor()
    private let microphoneGuard = MicrophoneGuard()

    init() {
        let defaults = UserDefaults.standard
        autoConnect = defaults.object(forKey: Self.autoConnectKey) as? Bool ?? true
        disconnectOnLidClose = defaults.object(forKey: Self.disconnectOnLidCloseKey) as? Bool ?? true
        useMacMicrophone = defaults.object(forKey: Self.useMacMicrophoneKey) as? Bool ?? true

        if let saved = defaults.array(forKey: Self.eqGainsKey) as? [Int],
           saved.count == WuqiProtocol.bandCount {
            eqGains = saved.map { Int8(clamping: $0) }
        }
        loadLastCaseReading()
        if let data = defaults.data(forKey: Self.customPresetsKey),
           let saved = try? JSONDecoder().decode([CustomEqPreset].self, from: data) {
            customPresets = saved
        }
        if let savedMode = defaults.object(forKey: Self.ancModeKey) as? Int,
           let mode = AncMode(rawValue: UInt8(clamping: savedMode)) {
            ancMode = mode
        }

        connection.onStatusChange = { [weak self] newStatus in
            Task { @MainActor in self?.statusDidChange(newStatus) }
        }
        connection.onMessage = { [weak self] message in
            Task { @MainActor in self?.handle(message: message) }
        }
        connection.onLog = { [weak self] line in
            Task { @MainActor in self?.log(line) }
        }
        connection.onFrame = { [weak self] direction, frame in
            Task { @MainActor in self?.logFrame(frame, direction: direction) }
        }

        HotKeyManager.shared.onTrigger = { [weak self] in
            self?.cycleAncMode()
        }
        lidMonitor.onLidClosed = { [weak self] in
            self?.lidDidClose()
        }
        lidMonitor.onLidOpened = { [weak self] in
            self?.lidDidOpen()
        }
        microphoneGuard.onSwitch = { [weak self] line in
            self?.log(line)
        }
        // didSet doesn't run for assignments in init.
        microphoneGuard.isEnabled = useMacMicrophone

        observeWidgetCommands()
        publishToWidget()
        setUpLoginItem()
        requestNotificationPermission()

        startAutoConnectTimer()
        attemptAutoConnect()
    }

    private func statusDidChange(_ newStatus: RFCOMMConnection.ConnectionStatus) {
        status = newStatus
        switch newStatus {
        case .connected:
            onConnected()
            startBatteryTimer()
        case .failed(let message):
            log("Connection failed: \(message)")
            applyAncOnConnect = false
            stopBatteryTimer()
            clearBattery()
        case .disconnected:
            // Includes a cancelled connect, whose pending widget request
            // shouldn't carry over to a later one.
            applyAncOnConnect = false
            stopBatteryTimer()
            clearBattery()
        case .connecting:
            stopBatteryTimer()
            clearBattery()
        }
        publishToWidget()
    }

    /// Clears the buds' levels, which are only meaningful while connected.
    /// The case's last reading is kept — it's still true after a disconnect.
    private func clearBattery() {
        leftBattery = nil
        rightBattery = nil
        twsConnected = nil
    }

    private func loadLastCaseReading() {
        let defaults = UserDefaults.standard
        guard let level = defaults.object(forKey: Self.caseBatteryKey) as? Int,
              let date = defaults.object(forKey: Self.caseReadingDateKey) as? Date else { return }
        caseBattery = level
        caseReadingDate = date
    }

    private func recordCaseReading(_ level: Int) {
        caseBattery = level
        caseReadingDate = Date()
        UserDefaults.standard.set(level, forKey: Self.caseBatteryKey)
        UserDefaults.standard.set(caseReadingDate, forKey: Self.caseReadingDateKey)
    }

    /// Tooltip text explaining where the case level came from.
    var caseReadingNote: String? {
        guard caseBattery != nil, let caseReadingDate else { return nil }
        let when = caseReadingDate.formatted(date: Calendar.current.isDateInToday(caseReadingDate) ? .omitted : .abbreviated, time: .shortened)
        return "Case level last read at \(when). The earbuds can only read the case while a bud is inside it."
    }

    private func startBatteryTimer() {
        stopBatteryTimer()
        let timer = Timer(timeInterval: Self.batteryRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshBattery() }
        }
        RunLoop.main.add(timer, forMode: .common)
        batteryTimer = timer
    }

    private func stopBatteryTimer() {
        batteryTimer?.invalidate()
        batteryTimer = nil
    }

    /// Battery for the panel and widget: only the bud(s) in use.
    var batterySummary: String? {
        SharedState.batterySummary(left: leftBattery, right: rightBattery, caseLevel: caseBattery)
    }

    // MARK: - Widget bridge

    /// The widget runs sandboxed in its own process, so its buttons can't send
    /// Bluetooth commands themselves — they post a distributed notification
    /// that we act on here.
    private func observeWidgetCommands() {
        let center = DistributedNotificationCenter.default()
        for command in SharedState.Command.allCases {
            center.addObserver(
                forName: command.notificationName,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleWidgetCommand(command) }
            }
        }
    }

    private func handleWidgetCommand(_ command: SharedState.Command) {
        log("Widget: \(command.logDescription)")
        let mode: AncMode
        switch command {
        case .ancOff: mode = .off
        case .ancOn: mode = .on
        case .ancTransparency: mode = .transparency
        }

        if isConnected {
            setAncMode(mode)
            return
        }

        // Not connected: remember the choice and connect; `onConnected`
        // then applies it, so a widget tap still does something.
        ancMode = mode
        UserDefaults.standard.set(Int(mode.rawValue), forKey: Self.ancModeKey)
        // A connect already on its way picks this up too, rather than reading
        // the earbuds' current mode over the top of it.
        applyAncOnConnect = true
        if isConnecting { return }
        guard let target, target.inRange else {
            applyAncOnConnect = false
            log("Widget tap ignored: earbuds aren't connected to this Mac.")
            publishToWidget()
            return
        }
        connect(toAddress: target.address)
    }

    /// Mirrors current state into the App Group so the widget can render it,
    /// then asks WidgetKit to redraw.
    private func publishToWidget() {
        SharedState.write(
            SharedState.Snapshot(
                isConnected: isConnected,
                ancModeRawValue: Int(ancMode.rawValue),
                deviceName: target?.name ?? "Earbuds",
                leftBattery: leftBattery,
                rightBattery: rightBattery,
                caseBattery: caseBattery
            )
        )
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Auto-connect

    private func startAutoConnectTimer() {
        let timer = Timer(timeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.attemptAutoConnect() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Opens the control channel once macOS has a classic Bluetooth link to
    /// the remembered earbuds, so the user never has to click Connect.
    private func attemptAutoConnect() {
        refreshPairedDevices()
        guard autoConnect, !manuallyReleased, !isConnected, !isConnecting, connection.isIdle else { return }
        guard let address = UserDefaults.standard.string(forKey: Self.lastDeviceAddressKey) else { return }
        guard connection.isDeviceConnected(address: address) else { return }
        log("Earbuds are in range — connecting automatically.")
        connection.connect(toAddress: address)
    }

    /// The transport sends these one at a time, so the order here is the
    /// order the earbuds receive them.
    /// The earbuds' own ANC mode and in-ear setting win: they're read, not
    /// overwritten, so a change made by long-pressing a bud survives a
    /// reconnect. The one exception is a widget tap that asked for a mode
    /// while disconnected. EQ is always restored — it's the app's setting.
    private func onConnected() {
        if applyAncOnConnect {
            connection.send(frame: WuqiProtocol.ancFrame(ancMode))
        } else {
            connection.send(frame: WuqiProtocol.queryFrame(WuqiProtocol.Command.queryAncStatus))
        }
        applyAncOnConnect = false
        connection.send(frame: WuqiProtocol.queryFrame(WuqiProtocol.Command.queryInEarStatus))
        commitEq()
        refreshBattery()
        connection.send(frame: WuqiProtocol.queryFrame(WuqiProtocol.Command.queryTwsStatus))
    }

    func refreshBattery() {
        guard isConnected else { return }
        connection.send(frame: WuqiProtocol.queryFrame(WuqiProtocol.Command.queryBattery))
    }

    func cycleAncMode() {
        guard isConnected else { return }
        let order: [AncMode] = [.off, .on, .transparency]
        let next = order[((order.firstIndex(of: ancMode) ?? 0) + 1) % order.count]
        setAncMode(next)
    }

    // MARK: - Connection

    /// Picks the device we'd control: the one we connected to last, else a
    /// boAt-looking name among the paired devices.
    func refreshPairedDevices() {
        let pairedDevices = connection.listPairedDevices()
        let remembered = UserDefaults.standard.string(forKey: Self.lastDeviceAddressKey)
        let match = pairedDevices.first { $0.id == remembered }
            ?? connection.likelyNirvanaDevice(in: pairedDevices)

        guard let match else {
            target = nil
            return
        }
        target = Target(
            address: match.id,
            name: match.name,
            inRange: connection.isDeviceConnected(address: match.id)
        )
    }

    func connectToTarget() {
        guard let target else { return }
        connect(toAddress: target.address)
    }

    func openBluetoothSettings() {
        // The pane's identifier changed in Ventura; try the modern one first.
        let candidates = [
            "x-apple.systempreferences:com.apple.BluetoothSettings",
            "x-apple.systempreferences:com.apple.preferences.Bluetooth"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    func connect(toAddress address: String) {
        manuallyReleased = false
        UserDefaults.standard.set(address, forKey: Self.lastDeviceAddressKey)
        log("Connecting to \(address)…")
        connection.connect(toAddress: address)
    }

    /// Disconnects the earbuds from the Mac at the Bluetooth level. Only
    /// called when closing the lid sleeps the Mac — with an external display
    /// keeping it awake, the earbuds stay. Not a manual release: once they're
    /// linked again, auto-connect takes control as usual.
    private func lidDidClose() {
        guard disconnectOnLidClose,
              let address = target?.address ?? UserDefaults.standard.string(forKey: Self.lastDeviceAddressKey),
              connection.isDeviceConnected(address: address) else { return }
        log("Lid closed — disconnecting the earbuds from this Mac.")
        disconnectedByLid = address
        connection.disconnectDevice(address: address)
    }

    /// Links the earbuds again when the lid opens — but only if closing it is
    /// what disconnected them, so it never pulls in buds the user had
    /// disconnected themselves.
    private func lidDidOpen() {
        guard disconnectedByLid != nil, !lidReconnectRunning else { return }
        guard disconnectOnLidClose else {
            disconnectedByLid = nil // turned off while the lid was shut
            return
        }
        lidReconnectRunning = true
        log("Lid opened — reconnecting the earbuds.")
        reconnectAfterLid(attempt: 1)
    }

    /// Bluetooth can take a few seconds to come back after wake, and the buds
    /// may be in their case, so this tries a handful of times, then gives up.
    private func reconnectAfterLid(attempt: Int) {
        guard let address = disconnectedByLid, !lidMonitor.isLidClosed else {
            lidReconnectRunning = false
            return
        }
        connection.reconnectDevice(address: address) { [weak self] linked in
            Task { @MainActor in
                guard let self else { return }
                if linked {
                    self.log("Earbuds reconnected.")
                    self.finishLidReconnect()
                    self.attemptAutoConnect()
                } else if attempt < Self.lidReconnectAttempts {
                    try? await Task.sleep(for: .seconds(Self.lidReconnectDelay))
                    self.reconnectAfterLid(attempt: attempt + 1)
                } else {
                    self.log("Couldn't reconnect the earbuds after opening the lid (are they in the case?).")
                    self.finishLidReconnect()
                }
            }
        }
    }

    private func finishLidReconnect() {
        disconnectedByLid = nil
        lidReconnectRunning = false
    }

    func disconnect() {
        manuallyReleased = true
        log("Released control. Auto-connect paused until you reconnect.")
        connection.disconnect()
    }

    // MARK: - Controls

    func setAncMode(_ mode: AncMode) {
        ancMode = mode
        UserDefaults.standard.set(Int(mode.rawValue), forKey: Self.ancModeKey)
        connection.send(frame: WuqiProtocol.ancFrame(mode))
        publishToWidget()
    }

    func setInEarDetection(_ enabled: Bool) {
        inEarDetection = enabled
        connection.send(frame: WuqiProtocol.inEarDetectionFrame(enabled: enabled))
    }

    // MARK: - EQ presets

    /// Which preset the current curve is, if any. Presets are recognised by
    /// their curve rather than remembered, so the answer is always true to
    /// what's actually on the earbuds; built-ins win if a saved preset
    /// happens to share a curve with one.
    var activeSelection: EqSelection? {
        if let builtIn = EqPreset.matching(eqGains) {
            return .builtIn(builtIn)
        }
        if let custom = customPresets.first(where: { $0.gains == eqGains }) {
            return .custom(custom.id)
        }
        return nil
    }

    /// The name to show for the current curve, or nil if it's unsaved.
    var activeSelectionName: String? {
        switch activeSelection {
        case .builtIn(let preset): return preset.label
        case .custom(let id): return customPresets.first { $0.id == id }?.name
        case nil: return nil
        }
    }

    func select(_ selection: EqSelection) {
        switch selection {
        case .builtIn(let preset):
            editingCustomID = nil
            eqGains = preset.gains
        case .custom(let id):
            guard let preset = customPresets.first(where: { $0.id == id }) else { return }
            editingCustomID = id
            eqGains = preset.gains
        }
        persistGains()
        commitEq()
    }

    /// A saved preset the user picked and has since tweaked — its changes can
    /// be written back to it rather than only saved as something new.
    var modifiedCustomPreset: CustomEqPreset? {
        guard activeSelection == nil, let editingCustomID else { return nil }
        return customPresets.first { $0.id == editingCustomID }
    }

    func saveCurrentCurveAsPreset(named proposed: String) {
        let preset = CustomEqPreset(id: UUID(), name: uniquePresetName(proposed, excluding: nil), gains: eqGains)
        customPresets.append(preset)
        editingCustomID = preset.id
        persistCustomPresets()
        log("Saved EQ preset “\(preset.name)”.")
    }

    func updatePreset(_ id: UUID) {
        guard let index = customPresets.firstIndex(where: { $0.id == id }) else { return }
        customPresets[index].gains = eqGains
        persistCustomPresets()
        log("Updated EQ preset “\(customPresets[index].name)”.")
    }

    func renamePreset(_ id: UUID, to proposed: String) {
        guard let index = customPresets.firstIndex(where: { $0.id == id }) else { return }
        let old = customPresets[index].name
        customPresets[index].name = uniquePresetName(proposed, excluding: id)
        persistCustomPresets()
        log("Renamed EQ preset “\(old)” to “\(customPresets[index].name)”.")
    }

    func deletePreset(_ id: UUID) {
        guard let index = customPresets.firstIndex(where: { $0.id == id }) else { return }
        let removed = customPresets.remove(at: index)
        if editingCustomID == id { editingCustomID = nil }
        persistCustomPresets()
        log("Deleted EQ preset “\(removed.name)”.")
    }

    /// A name for the next new preset: "My Preset 1", "My Preset 2", …
    var suggestedPresetName: String {
        uniquePresetName("My Preset 1", excluding: nil)
    }

    private func uniquePresetName(_ proposed: String, excluding id: UUID?) -> String {
        EqPreset.uniqueName(
            proposed,
            taken: EqPreset.allCases.map(\.label) + customPresets.filter { $0.id != id }.map(\.name)
        )
    }

    private func persistCustomPresets() {
        if let data = try? JSONEncoder().encode(customPresets) {
            UserDefaults.standard.set(data, forKey: Self.customPresetsKey)
        }
    }

    func setGain(band: Int, to gain: Int8) {
        guard band < eqGains.count else { return }
        eqGains[band] = max(WuqiProtocol.gainRange.lowerBound, min(WuqiProtocol.gainRange.upperBound, gain))
        persistGains()
    }

    /// Sent when a slider is released, as the official app does
    /// (`EQView` only notifies on ACTION_UP). The transport also drops any
    /// older EQ frame still waiting to go out.
    func commitEq() {
        connection.send(frame: WuqiProtocol.eqFrame(gains: eqGains))
    }

    private func persistGains() {
        UserDefaults.standard.set(eqGains.map { Int($0) }, forKey: Self.eqGainsKey)
    }

    // MARK: - Incoming

    private func handle(message: WuqiMessage) {
        let id = WuqiProtocol.key(message.command)
        if id == WuqiProtocol.key(WuqiProtocol.NotificationCommand.ancStatus),
           let value = WuqiProtocol.statusValue(message),
           let mode = AncMode(rawValue: value) {
            // Also arrives unprompted when the mode is changed on the buds.
            ancMode = mode
            UserDefaults.standard.set(Int(mode.rawValue), forKey: Self.ancModeKey)
            publishToWidget()
        } else if id == WuqiProtocol.key(WuqiProtocol.Command.queryInEarStatus),
                  let value = WuqiProtocol.statusValue(message) {
            // `toe.b()`: any non-zero value means on.
            inEarDetection = value != 0
        } else if id == WuqiProtocol.key(WuqiProtocol.NotificationCommand.battery),
                  message.payload.count >= 2 {
            // Frame bytes 9, 10 and (when present) 11 — `toe.q()` reads the
            // case level only from the longer 13-byte reply.
            // A bud reading 0 is in the case or off — the official app shows
            // it with no percentage — so only buds actually in use get a level.
            leftBattery = message.payload[0] > 0 ? Int(message.payload[0]) : nil
            rightBattery = message.payload[1] > 0 ? Int(message.payload[1]) : nil
            // The earbuds can only read the case while a bud is docked: on a
            // real device they sent 91% with one bud in the case and 0 once
            // both were out again. So 0 means "can't see the case", not
            // "empty", and it leaves the last real reading in place.
            let caseLevel = message.payload.count >= 3 ? Int(message.payload[2]) : 0
            if caseLevel > 0 {
                recordCaseReading(caseLevel)
            }
            publishToWidget()
            // Only live readings count — never the remembered case level.
            checkLowBattery(left: leftBattery, right: rightBattery, caseLevel: caseLevel > 0 ? caseLevel : nil)
        } else if id == WuqiProtocol.key(WuqiProtocol.NotificationCommand.twsStatus),
                  message.raw.count == 13 {
            // `toe.q()` case 11: only the 13-byte reply carries it; byte 9 is
            // 1 when both buds are linked. The earbuds push this themselves
            // when a bud comes out of or goes into the case, so re-read the
            // battery to show the right bud straight away.
            let linked = message.payload[0] == 1
            if linked != twsConnected {
                twsConnected = linked
                log(linked ? "Both buds in use." : "One bud in use.")
                refreshBattery()
            }
        }
    }

    // MARK: - Open at login

    func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log("Couldn't \(enabled ? "turn on" : "turn off") Open at Login: \(error.localizedDescription)")
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Turns Open at Login on the first time this version runs — the user
    /// asked for it — and afterwards only reflects whatever they've chosen.
    private func setUpLoginItem() {
        if !UserDefaults.standard.bool(forKey: Self.loginItemSetUpKey) {
            UserDefaults.standard.set(true, forKey: Self.loginItemSetUpKey)
            setOpenAtLogin(true)
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Low battery alerts

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            if !granted {
                Task { @MainActor in self?.log("Notifications are off, so low-battery alerts won't show.") }
            }
        }
    }

    /// Notifies when any part newly drops to the low threshold. The message
    /// covers everything that's low right now, so if the second bud follows
    /// the first, the alert reads "Your buds are low".
    private func checkLowBattery(left: Int?, right: Int?, caseLevel: Int?) {
        let readings: [(BatteryPart, Int?)] = [(.left, left), (.right, right), (.caseLevel, caseLevel)]
        var newlyLow = false
        for (part, level) in readings {
            guard let level else { continue }
            if level <= SharedState.lowBatteryThreshold {
                if lowBatteryAlerted.insert(part).inserted { newlyLow = true }
            } else if level > Self.lowBatteryRearmLevel {
                lowBatteryAlerted.remove(part)
            }
        }
        guard newlyLow, let message = SharedState.lowBatteryMessage(left: left, right: right, caseLevel: caseLevel) else { return }

        let content = UNMutableNotificationContent()
        content.title = target?.name ?? "Earbuds"
        content.body = message
        content.sound = .default
        // A fixed identifier replaces the previous alert instead of stacking.
        let request = UNNotificationRequest(identifier: "lowBattery", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        log("Low battery alert: \(message)")
    }

    // MARK: - Log

    /// The newest lines, formatted for the panel.
    var recentLogLines: [String] {
        logEntries.suffix(12).map { "\($0.kind.arrow) \($0.label)" }
    }

    private func log(_ text: String) {
        append(LogEntry(date: Date(), kind: .info, label: text, bytes: nil))
    }

    private func logFrame(_ frame: [UInt8], direction: WuqiProtocol.Direction) {
        append(LogEntry(
            date: Date(),
            kind: direction == .sent ? .sent : .received,
            label: labelWithSavedPresetName(WuqiProtocol.describe(frame, direction: direction), frame: frame),
            bytes: frame
        ))
    }

    /// The protocol layer only knows the built-in presets. If an EQ frame's
    /// gains match a saved preset, name it — still worked out from the bytes.
    private func labelWithSavedPresetName(_ label: String, frame: [UInt8]) -> String {
        guard label.hasPrefix("EQ command → custom curve"), frame.count >= 19 else { return label }
        let gains = frame[11..<(11 + WuqiProtocol.bandCount)].map { Int8(clamping: WuqiProtocol.decodeGain($0)) }
        guard let preset = customPresets.first(where: { $0.gains == gains }) else { return label }
        return label.replacingOccurrences(of: "custom curve", with: "saved preset “\(preset.name)”")
    }

    private func append(_ entry: LogEntry) {
        logEntries.append(entry)
        if logEntries.count > Self.maxLogEntries {
            logEntries.removeFirst(logEntries.count - Self.maxLogEntries)
        }
    }

    /// Asks where to save, then writes the whole session log as plain text
    /// with every command labelled.
    func saveLogs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let stamp = Self.fileStampFormatter.string(from: Date())
        panel.nameFieldStringValue = "Nirvana Control log \(stamp).txt"
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try logFileContents().write(to: url, atomically: true, encoding: .utf8)
            log("Saved log to \(url.lastPathComponent).")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            log("Couldn't save log: \(error.localizedDescription)")
        }
    }

    private func logFileContents() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let eq = activeSelectionName.map { "preset \($0)" } ?? "unsaved custom curve"

        var lines: [String] = [
            "Nirvana Control — session log",
            "Saved:        \(Self.timestampFormatter.string(from: Date()))",
            "App version:  \(version)",
            "Device:       \(target.map { "\($0.name) (\($0.address))" } ?? "none")",
            "Connection:   \(statusDescription)",
            "Settings:     ANC = \(ancMode.label); EQ = \(eq) [\(eqGains.map(String.init).joined(separator: " "))]; In-ear detection = \(inEarDetection ? "on" : "off")",
            "Battery:      \(batterySummary ?? "no reading this session")\(twsConnected.map { $0 ? " (both buds linked)" : " (one bud in use)" } ?? "")",
            "",
            "Legend:  → sent to earbuds    ← received from earbuds    • app event",
            "Labels are worked out from each frame's bytes, not from what the app meant to send.",
            String(repeating: "-", count: 78)
        ]
        for entry in logEntries {
            let time = Self.timeFormatter.string(from: entry.date)
            lines.append("\(time)  \(entry.kind.arrow)  \(entry.label)")
            if let hex = entry.hex {
                lines.append("                   \(hex)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private var statusDescription: String {
        switch status {
        case .connected(let name): return "connected to \(name)"
        case .connecting: return "connecting"
        case .failed(let message): return "failed — \(message)"
        case .disconnected: return "not connected"
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()
}

private extension SharedState.Command {
    var logDescription: String {
        switch self {
        case .ancOff: return "ANC → Off tapped"
        case .ancOn: return "ANC → ANC tapped"
        case .ancTransparency: return "ANC → Ambient tapped"
        }
    }
}
