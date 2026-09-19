import Foundation
import AppKit
import IOBluetooth

/// Wraps a closure so it can be hopped onto the IOBluetooth thread via
/// `perform(_:on:with:waitUntilDone:)`.
private final class BlockBox: NSObject {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
}

/// Classic-Bluetooth (RFCOMM) transport for the wuqi control protocol.
///
/// The earbuds must already be paired and connected in System Settings, like
/// any headset. This class finds the control service with an SDP query and
/// opens an RFCOMM channel to it.
///
/// IOBluetooth quirks that shape this design:
///  - Delegate callbacks arrive on the run loop of the thread that made the
///    call, so all IOBluetooth work happens on a dedicated thread whose run
///    loop never stalls (a UI thread's does, during event tracking).
///  - The first `openRFCOMMChannelAsync` in a process often never calls back.
///    We time out and retry, and never `close()` a failed attempt — that close
///    lands asynchronously and kills whichever channel opens next. Those
///    abandoned attempts can still fire callbacks much later, so every
///    callback is checked against the channel it's actually about.
final class RFCOMMConnection: NSObject {
    // Coming out of the charging case, the classic link is up before the
    // earbuds will accept an RFCOMM connection, so this needs to outlast that
    // window rather than giving up early.
    private static let openTimeout: TimeInterval = 4.0
    private static let maxOpenAttempts = 6

    /// How long to wait for the earbuds to answer a command before sending the
    /// next one. The official app sends strictly one at a time and waits up to
    /// 6s for each reply (`yne.r()`); these earbuds often don't reply at all,
    /// so a shorter wait keeps the controls responsive while still never
    /// overlapping two commands.
    private static let replyTimeout: TimeInterval = 1.2

    private(set) var device: IOBluetoothDevice?
    /// The channel that has actually opened. Only this one may be written to,
    /// and only its closure means we're disconnected.
    private var openChannel: IOBluetoothRFCOMMChannel?
    /// The most recent open attempt still in flight.
    private var latestAttempt: IOBluetoothRFCOMMChannel?
    private let decoder = WuqiFrameDecoder()

    private var bluetoothThread: Thread?
    private var openAttempts = 0
    private var openTimeoutTimer: Timer?
    private var targetChannelID: BluetoothRFCOMMChannelID = 0

    private var writeQueue: [[UInt8]] = []
    private var awaitingReply = false
    private var replyTimer: Timer?

    var onStatusChange: ((ConnectionStatus) -> Void)?
    var onMessage: ((WuqiMessage) -> Void)?
    var onLog: ((String) -> Void)?
    /// Every frame written or read, for the labelled log.
    var onFrame: ((WuqiProtocol.Direction, [UInt8]) -> Void)?

    enum ConnectionStatus: Equatable {
        case disconnected
        case searching
        case connecting
        case connected(name: String)
        case failed(String)
    }

    private(set) var status: ConnectionStatus = .disconnected {
        didSet { onStatusChange?(status) }
    }

    struct PairedDeviceInfo: Identifiable, Hashable {
        let id: String // Bluetooth address
        let name: String
    }

    override init() {
        super.init()
        startBluetoothThread()

        // Being killed with the channel still open leaves the earbuds holding
        // a half-dead RFCOMM session, and they then refuse new ones until they
        // power-cycle. Always hang up on the way out.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.closeChannelBeforeExit()
        }
    }

    /// Signalled by `rfcommChannelClosed` when a close started at quit time
    /// has actually completed.
    private var exitCloseSignal: DispatchSemaphore?

    /// `close()` only *starts* the RFCOMM disconnect, and it must run on the
    /// thread that owns the channel. So the close is handed to the Bluetooth
    /// thread, and quitting waits — briefly — for the earbuds to confirm.
    private func closeChannelBeforeExit() {
        guard let bluetoothThread else { return }
        let closed = DispatchSemaphore(value: 0)
        let startClose = BlockBox { [weak self] in
            guard let self, let channel = self.openChannel, channel.isOpen() else {
                closed.signal()
                return
            }
            self.exitCloseSignal = closed
            channel.close()
        }
        perform(#selector(executeBlock(_:)), on: bluetoothThread, with: startClose, waitUntilDone: true)
        _ = closed.wait(timeout: .now() + 0.5)
    }

    // MARK: - Dedicated IOBluetooth thread

    private func startBluetoothThread() {
        let thread = Thread { [weak self] in
            // A run loop with no sources exits immediately; the port keeps it alive.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            while let self, !Thread.current.isCancelled {
                _ = self
                RunLoop.current.run(mode: .default, before: .distantFuture)
            }
        }
        thread.name = "com.local.boatmenubar.iobluetooth"
        thread.start()
        bluetoothThread = thread
    }

    private func onBluetoothThread(_ block: @escaping () -> Void) {
        guard let bluetoothThread else { return }
        perform(#selector(executeBlock(_:)), on: bluetoothThread, with: BlockBox(block), waitUntilDone: false)
    }

    @objc private func executeBlock(_ box: BlockBox) {
        box.block()
    }

    private func scheduleTimer(after interval: TimeInterval, _ action: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: false) { _ in action() }
        RunLoop.current.add(timer, forMode: .common)
        return timer
    }

    // MARK: - Device discovery

    /// All classic-Bluetooth devices currently paired in macOS.
    func listPairedDevices() -> [PairedDeviceInfo] {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return paired.compactMap { device in
            guard let address = device.addressString else { return nil }
            return PairedDeviceInfo(id: address, name: device.name ?? address)
        }
    }

    /// Best-effort guess at which paired device is the boAt earbuds.
    func likelyNirvanaDevice(in devices: [PairedDeviceInfo]) -> PairedDeviceInfo? {
        devices.first { $0.name.localizedCaseInsensitiveContains("nirvana") || $0.name.localizedCaseInsensitiveContains("boat") }
    }

    /// Whether macOS currently holds a classic Bluetooth link to this device —
    /// i.e. the earbuds are powered on and in range.
    func isDeviceConnected(address: String) -> Bool {
        IOBluetoothDevice(addressString: address)?.isConnected() ?? false
    }

    var isIdle: Bool {
        switch status {
        case .disconnected, .failed: return true
        default: return false
        }
    }

    // MARK: - Connect / disconnect

    func connect(toAddress address: String) {
        onBluetoothThread { [weak self] in
            guard let self else { return }
            self.status = .connecting
            guard let device = IOBluetoothDevice(addressString: address) else {
                self.status = .failed("Could not resolve device address \(address).")
                return
            }
            self.beginConnect(to: device)
        }
    }

    private func beginConnect(to device: IOBluetoothDevice) {
        self.device = device
        openAttempts = 0
        openChannel = nil
        latestAttempt = nil
        resetWriteQueue()
        // A half-frame left over from the last session would otherwise be
        // glued onto the first bytes of this one.
        decoder.reset()
        onLog?("Querying SDP records on \(device.name ?? device.addressString ?? "device")…")
        let result = device.performSDPQuery(self)
        if result != kIOReturnSuccess {
            status = .failed("SDP query failed to start (\(result)).")
        }
    }

    func disconnect() {
        onBluetoothThread { [weak self] in
            guard let self else { return }
            self.cancelOpenTimeout()
            self.resetWriteQueue()
            if let channel = self.openChannel, channel.isOpen() {
                channel.close()
            }
            self.openChannel = nil
            self.latestAttempt = nil
            self.device = nil
            self.status = .disconnected
        }
    }

    /// Disconnects the earbuds from the Mac entirely, as Disconnect in
    /// System Settings does — audio included, not just the control channel.
    /// This is a Bluetooth link operation, not a command to the earbuds.
    /// The control channel is hung up first so the earbuds never see it
    /// vanish mid-session.
    func disconnectDevice(address: String) {
        disconnect()
        onBluetoothThread {
            guard let device = IOBluetoothDevice(addressString: address), device.isConnected() else { return }
            let result = device.closeConnection()
            if result != kIOReturnSuccess {
                self.onLog?("Couldn't disconnect the earbuds (IOReturn \(result)).")
            }
        }
    }

    // MARK: - Sending (one command at a time)

    /// Queues one already-framed packet for the control channel.
    func send(frame: [UInt8]) {
        onBluetoothThread { [weak self] in
            guard let self else { return }
            // A newer EQ curve supersedes any older one still waiting its
            // turn, so dragging a slider can't build up a backlog.
            if Self.isEqualizer(frame) {
                self.writeQueue.removeAll(where: Self.isEqualizer)
            }
            self.writeQueue.append(frame)
            self.pumpWriteQueue()
        }
    }

    private static func isEqualizer(_ frame: [UInt8]) -> Bool {
        frame.count > 6 && frame[5] == WuqiProtocol.Command.equalizer.0 && frame[6] == WuqiProtocol.Command.equalizer.1
    }

    private func pumpWriteQueue() {
        guard !awaitingReply, !writeQueue.isEmpty else { return }
        guard let channel = openChannel, channel.isOpen() else {
            onLog?("Not connected; dropped \(writeQueue.count) queued command(s).")
            writeQueue.removeAll()
            return
        }

        let frame = writeQueue.removeFirst()
        var bytes = frame
        let result = bytes.withUnsafeMutableBytes { ptr in
            channel.writeSync(ptr.baseAddress, length: UInt16(ptr.count))
        }
        if result != kIOReturnSuccess {
            onLog?("Write failed (IOReturn \(result)) — \(WuqiProtocol.describe(frame, direction: .sent))")
            pumpWriteQueue()
            return
        }
        onFrame?(.sent, frame)

        awaitingReply = true
        replyTimer = scheduleTimer(after: Self.replyTimeout) { [weak self] in
            self?.finishAwaitingReply()
        }
    }

    private func finishAwaitingReply() {
        replyTimer?.invalidate()
        replyTimer = nil
        awaitingReply = false
        pumpWriteQueue()
    }

    private func resetWriteQueue() {
        writeQueue.removeAll()
        replyTimer?.invalidate()
        replyTimer = nil
        awaitingReply = false
    }

    // MARK: - Channel opening with retry

    private func attemptOpenChannel(channelID: BluetoothRFCOMMChannelID) {
        guard let device else { return }
        openAttempts += 1
        targetChannelID = channelID
        onLog?("Opening RFCOMM channel \(channelID) (attempt \(openAttempts))…")

        var newChannel: IOBluetoothRFCOMMChannel?
        let result = device.openRFCOMMChannelAsync(&newChannel, withChannelID: channelID, delegate: self)
        if result != kIOReturnSuccess {
            onLog?("openRFCOMMChannelAsync returned \(result) immediately.")
        }
        latestAttempt = newChannel
        scheduleOpenTimeout()
    }

    private func scheduleOpenTimeout() {
        cancelOpenTimeout()
        openTimeoutTimer = scheduleTimer(after: Self.openTimeout) { [weak self] in
            self?.handleOpenTimeout()
        }
    }

    private func cancelOpenTimeout() {
        openTimeoutTimer?.invalidate()
        openTimeoutTimer = nil
    }

    private func handleOpenTimeout() {
        guard openChannel == nil, device != nil else { return }
        retryOrFail(reason: "no response")
    }

    private func retryOrFail(reason: String) {
        if openAttempts < Self.maxOpenAttempts {
            onLog?("Attempt \(openAttempts) got \(reason); retrying…")
            // Deliberately not closing the abandoned attempt — see the type
            // comment. Its late callbacks are filtered out instead.
            attemptOpenChannel(channelID: targetChannelID)
        } else {
            // With the buds also connected to a phone, the phone's boAt app
            // may be holding this channel. That's a likely cause, not a
            // confirmed one, so the message says as much.
            status = .failed(
                "Couldn't open the control channel. If the boAt app is running on another device, try closing it and reconnecting."
            )
        }
    }
}

// MARK: - SDP query callback (IOBluetoothDevice informal async delegate)

extension RFCOMMConnection {
    private static func uuid128(_ string: String) -> IOBluetoothSDPUUID? {
        let hex = string.replacingOccurrences(of: "-", with: "")
        guard hex.count == 32 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes.withUnsafeBytes { ptr in
            IOBluetoothSDPUUID(bytes: ptr.baseAddress, length: ptr.count)
        }
    }

    /// Control-channel UUIDs in priority order. 0x7034 is the one boAt's own
    /// app hardcodes for this device family (`ko0.java`); the rest cover the
    /// other vendor SDKs the app bundles (standard SPP, Bluetrum's custom
    /// UUID from `ABEarbuds.java`, and Airoha's).
    private static let candidateSppUUIDs: [IOBluetoothSDPUUID] = [
        IOBluetoothSDPUUID(uuid16: 0x7034),
        IOBluetoothSDPUUID(uuid16: 0x7033),
        IOBluetoothSDPUUID(uuid16: 0x1101),
        uuid128("B6632277-0642-458B-A7A0-23FB1DC92C93"),
        uuid128("00001107-D102-11E1-9B23-00025B00A5A5")
    ].compactMap { $0 }

    /// Standard audio/telephony profiles. Their RFCOMM channels belong to
    /// macOS's own Bluetooth audio stack — trying to open one (HFP on
    /// channel 2, typically) just hangs forever.
    private static let audioProfileUUID16s: [UInt16] = [
        0x111E, 0x111F, 0x1108, 0x1112, 0x110B, 0x110A, 0x110C, 0x110E, 0x110F, 0x1203
    ]

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status sdpStatus: IOReturn) {
        // A query from a session the user has since cancelled. Compared by
        // address: IOBluetooth may hand back a different object for the same
        // device.
        guard let current = self.device, device.addressString == current.addressString else { return }
        guard sdpStatus == kIOReturnSuccess else {
            status = .failed("SDP query failed (\(sdpStatus)).")
            return
        }

        let allServices = (device.services as? [IOBluetoothSDPServiceRecord]) ?? []
        let summary = allServices.map { svc -> String in
            var channelID: BluetoothRFCOMMChannelID = 0
            let hasRFCOMM = svc.getRFCOMMChannelID(&channelID) == kIOReturnSuccess
            let name = svc.getServiceName() ?? "?"
            return hasRFCOMM ? "\(name)[ch\(channelID)]" : name
        }.joined(separator: ", ")
        onLog?("SDP: \(allServices.count) services — \(summary)")

        var record: IOBluetoothSDPServiceRecord?
        for uuid in Self.candidateSppUUIDs {
            if let match = device.getServiceRecord(for: uuid) {
                var ch: BluetoothRFCOMMChannelID = 0
                guard match.getRFCOMMChannelID(&ch) == kIOReturnSuccess else { continue }
                onLog?("Matched known control service → channel \(ch).")
                record = match
                break
            }
        }

        if record == nil {
            var audioChannels = Set<BluetoothRFCOMMChannelID>()
            for uuid16 in Self.audioProfileUUID16s {
                guard let svc = device.getServiceRecord(for: IOBluetoothSDPUUID(uuid16: uuid16)) else { continue }
                var ch: BluetoothRFCOMMChannelID = 0
                if svc.getRFCOMMChannelID(&ch) == kIOReturnSuccess {
                    audioChannels.insert(ch)
                }
            }
            record = allServices.first { svc in
                var ch: BluetoothRFCOMMChannelID = 0
                guard svc.getRFCOMMChannelID(&ch) == kIOReturnSuccess else { return false }
                return !audioChannels.contains(ch)
            }
            if record != nil {
                onLog?("No known UUID matched; using first non-audio RFCOMM service.")
            }
        }

        guard let record else {
            status = .failed("No RFCOMM-capable service found (\(allServices.count) services total).")
            return
        }

        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else {
            status = .failed("Could not read RFCOMM channel ID from service record.")
            return
        }

        openAttempts = 0
        attemptOpenChannel(channelID: channelID)
    }
}

// MARK: - IOBluetoothRFCOMMChannelDelegate

extension RFCOMMConnection: IOBluetoothRFCOMMChannelDelegate {
    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        if error == kIOReturnSuccess {
            // Adopt the first channel that opens while we still want one —
            // even a "timed-out" attempt that came good late is a perfectly
            // valid connection to the same service.
            guard openChannel == nil, device != nil else {
                if rfcommChannel !== openChannel {
                    onLog?("Ignoring a late open from an abandoned attempt.")
                }
                return
            }
            cancelOpenTimeout()
            openChannel = rfcommChannel
            latestAttempt = nil
            let name = device?.name ?? "Earbuds"
            onLog?("RFCOMM channel open on \(rfcommChannel.getID()).")
            status = .connected(name: name)
        } else {
            // Only the attempt we're currently waiting on can drive a retry;
            // a failure reported by an older abandoned one is noise.
            guard rfcommChannel === latestAttempt, openChannel == nil, device != nil else { return }
            cancelOpenTimeout()
            retryOrFail(reason: "error \(error)")
        }
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        // Abandoned attempts close too; only the live channel closing means
        // we've actually lost the earbuds.
        guard rfcommChannel === openChannel else { return }
        exitCloseSignal?.signal()
        exitCloseSignal = nil
        onLog?("RFCOMM channel closed.")
        openChannel = nil
        resetWriteQueue()
        status = .disconnected
    }

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        // An abandoned attempt that opened late could otherwise interleave
        // its bytes with the live channel's inside the shared decoder.
        guard rfcommChannel === openChannel, let dataPointer, dataLength > 0 else { return }
        let bytes = Array(UnsafeBufferPointer(start: dataPointer.assumingMemoryBound(to: UInt8.self), count: dataLength))
        let messages = decoder.feed(bytes)
        if messages.isEmpty {
            // Log raw bytes that didn't complete a frame, so nothing the
            // earbuds send is ever silently lost from the log.
            onLog?("Recv (partial/unframed): \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
        }
        for message in messages {
            onFrame?(.received, message.raw)
            onMessage?(message)
        }
        // Any answer from the earbuds releases the next queued command.
        if awaitingReply {
            finishAwaitingReply()
        }
    }
}
