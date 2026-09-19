import CoreAudio
import Foundation

/// Keeps the Mac's own microphone as the system input.
///
/// When Bluetooth earbuds connect, macOS makes their mic the default input.
/// Using it switches the earbuds to the hands-free profile, which drops
/// playback to low-quality mono for as long as anything records. This
/// watches the default input and, whenever it becomes a Bluetooth device,
/// puts the built-in mic back. Wired and USB mics are left alone.
@MainActor
final class MicrophoneGuard {
    var isEnabled = false {
        didSet { if isEnabled { enforce() } }
    }
    var onSwitch: ((String) -> Void)?

    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init() {
        AudioObjectAddPropertyListenerBlock(Self.system, &Self.defaultInputAddress, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.enforce() }
        }
    }

    private func enforce() {
        guard isEnabled,
              let current = Self.defaultInput(),
              Self.isBluetooth(current),
              let builtIn = Self.builtInInput(),
              builtIn != current else { return }
        var id = builtIn
        let status = AudioObjectSetPropertyData(
            Self.system, &Self.defaultInputAddress, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &id
        )
        if status == noErr {
            onSwitch?("Switched the microphone from \(Self.name(of: current) ?? "earbuds") to \(Self.name(of: builtIn) ?? "the Mac's microphone").")
        } else {
            onSwitch?("Couldn't switch to the Mac's microphone (OSStatus \(status)).")
        }
    }

    // MARK: - CoreAudio queries

    private static func defaultInput() -> AudioObjectID? {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &defaultInputAddress, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private static func allDevices() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func transportType(of device: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &type) == noErr ? type : nil
    }

    private static func isBluetooth(_ device: AudioObjectID) -> Bool {
        let type = transportType(of: device)
        return type == kAudioDeviceTransportTypeBluetooth || type == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func hasInput(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func builtInInput() -> AudioObjectID? {
        allDevices().first { transportType(of: $0) == kAudioDeviceTransportTypeBuiltIn && hasInput($0) }
    }

    private static func name(of device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }
}
