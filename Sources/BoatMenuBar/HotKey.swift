import AppKit
import Carbon.HIToolbox

/// A recorded key combination, stored as Carbon key code + modifier mask so it
/// can be handed straight to `RegisterEventHotKey`.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        // A bare keystroke would swallow normal typing system-wide.
        guard carbon != 0 else { return nil }
        self.keyCode = UInt32(event.keyCode)
        self.carbonModifiers = carbon
    }

    var displayString: String {
        var parts = ""
        if carbonModifiers & UInt32(controlKey) != 0 { parts += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { parts += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { parts += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { parts += "⌘" }
        return parts + Self.keyName(for: keyCode)
    }

    private static func keyName(for code: UInt32) -> String {
        let names: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
            34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
            18: "1", 19: "2", 20: "3", 21: "4", 22: "5", 23: "6", 26: "7", 28: "8", 25: "9", 29: "0",
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
        ]
        return names[code] ?? "Key \(code)"
    }
}

/// Registers a system-wide hotkey through Carbon, which (unlike a global
/// NSEvent monitor) needs no Accessibility permission.
@MainActor
final class HotKeyManager: ObservableObject {
    static let shared = HotKeyManager()

    @Published private(set) var combo: KeyCombo?
    @Published private(set) var isRecording = false

    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerInstalled = false
    private var recordingMonitor: Any?
    private static let storageKey = "ancHotKey"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(KeyCombo.self, from: data) {
            register(saved)
        }
    }

    // MARK: - Registration

    func register(_ combo: KeyCombo) {
        unregister()
        installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x424D_4252), id: 1)
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        guard status == noErr else { return }
        hotKeyRef = ref
        self.combo = combo
        if let data = try? JSONEncoder().encode(combo) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    func clear() {
        unregister()
        combo = nil
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // The Carbon callback can't capture context, so it routes through the
        // shared instance.
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async {
                HotKeyManager.shared.fire()
            }
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = true
    }

    fileprivate func fire() {
        onTrigger?()
    }

    // MARK: - Recording

    /// Captures the next modified keystroke typed while the panel is focused.
    func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Escape cancels
                self.stopRecording()
                return nil
            }
            guard let combo = KeyCombo(event: event) else {
                return nil // needs at least one modifier; keep listening
            }
            self.register(combo)
            self.stopRecording()
            return nil
        }
    }

    func stopRecording() {
        if let recordingMonitor {
            NSEvent.removeMonitor(recordingMonitor)
        }
        recordingMonitor = nil
        isRecording = false
    }
}
