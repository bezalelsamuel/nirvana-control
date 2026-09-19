import AppKit
import IOKit
import IOKit.pwr_mgt

/// Reports the MacBook's lid closing (when that puts the Mac to sleep) and
/// opening again.
///
/// The power-management root domain broadcasts a clamshell-state message the
/// moment the lid moves. Its argument also says whether closing the lid will
/// sleep the Mac — it won't when an external display keeps it running
/// (clamshell mode), and that case is deliberately ignored. System sleep and
/// wake are watched too, as a backstop: the lid message can lose the race
/// with sleep, and a lid opened while asleep may only show up as a wake.
@MainActor
final class LidMonitor {
    /// The lid closed and the Mac is going to sleep.
    var onLidClosed: (() -> Void)?
    /// The lid opened (or the Mac woke with it open).
    var onLidOpened: (() -> Void)?

    private var rootDomain: io_service_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    /// `kIOPMMessageClamshellStateChange` — a C macro Swift can't import:
    /// iokit_family_msg(sub_iokit_powermanagement, 0x100).
    private static let clamshellStateChange: natural_t = 0xE003_4100
    /// `kClamshellStateBit`: set while the lid is closed.
    private static let clamshellClosedBit = 1 << 0
    /// `kClamshellSleepBit`: set when a closed lid will sleep the Mac.
    private static let clamshellSleepBit = 1 << 1

    init() {
        rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        Self.shared = self
        guard rootDomain != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, .main)

        IOServiceAddInterestNotification(
            port,
            rootDomain,
            kIOGeneralInterest,
            { _, _, messageType, argument in
                guard messageType == LidMonitor.clamshellStateChange else { return }
                let bits = Int(bitPattern: argument)
                let closed = bits & LidMonitor.clamshellClosedBit != 0
                let willSleep = bits & LidMonitor.clamshellSleepBit != 0
                MainActor.assumeIsolated {
                    guard let monitor = LidMonitor.shared else { return }
                    if !closed {
                        monitor.onLidOpened?()
                    } else if willSleep {
                        monitor.onLidClosed?()
                    }
                }
            },
            nil,
            &notifier
        )

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard let monitor = LidMonitor.shared, monitor.isLidClosed else { return }
                monitor.onLidClosed?()
            }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard let monitor = LidMonitor.shared, !monitor.isLidClosed else { return }
                monitor.onLidOpened?()
            }
        }
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
