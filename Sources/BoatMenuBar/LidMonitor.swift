import AppKit
import IOKit
import IOKit.pwr_mgt

/// Reports when the MacBook's lid closes.
///
/// The power-management root domain broadcasts a clamshell-state message the
/// moment the lid moves — whether the Mac then sleeps or stays awake on an
/// external display. System sleep is watched too, as a backstop in case that
/// message loses the race with sleep.
@MainActor
final class LidMonitor {
    var onLidClosed: (() -> Void)?

    private var rootDomain: io_service_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    /// `kIOPMMessageClamshellStateChange` — a C macro Swift can't import:
    /// iokit_family_msg(sub_iokit_powermanagement, 0x100).
    private static let clamshellStateChange: natural_t = 0xE003_4100
    /// Bit in that message's argument that is set while the lid is closed.
    private static let clamshellClosedBit = 1

    init() {
        rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, .main)

        IOServiceAddInterestNotification(
            port,
            rootDomain,
            kIOGeneralInterest,
            { _, _, messageType, argument in
                guard messageType == LidMonitor.clamshellStateChange else { return }
                let closed = Int(bitPattern: argument) & LidMonitor.clamshellClosedBit != 0
                guard closed else { return }
                MainActor.assumeIsolated { LidMonitor.shared?.onLidClosed?() }
            },
            nil,
            &notifier
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard let monitor = LidMonitor.shared, monitor.isLidClosed else { return }
                monitor.onLidClosed?()
            }
        }

        Self.shared = self
    }

    /// The IOKit callback is a C function pointer and can't capture `self`.
    private static var shared: LidMonitor?

    /// Reads the lid's current position; false on Macs without one.
    var isLidClosed: Bool {
        guard rootDomain != 0 else { return false }
        let value = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }
}
