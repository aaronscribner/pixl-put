import Foundation
import AppKit
import CoreGraphics

/// Subscribes to every "machine resuming / display reconfigured" signal
/// and routes each through a `Debouncer` so simultaneous wake +
/// display-reconfiguration events collapse into one restore (spec FR-006,
/// FR-008).
public final class WakeTriggerWatcher: @unchecked Sendable {

    private let debouncer: Debouncer
    private let displayWatcher: DisplayConfigWatcher
    private let eventLog: EventLog?
    private var tokens: [Any] = []
    private var displaySubscription: UUID?
    private let lock = NSLock()

    public init(
        debouncer: Debouncer,
        displayWatcher: DisplayConfigWatcher = DisplayConfigWatcher(),
        eventLog: EventLog? = nil
    ) {
        self.debouncer = debouncer
        self.displayWatcher = displayWatcher
        self.eventLog = eventLog
    }

    deinit { stop() }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard tokens.isEmpty, displaySubscription == nil else { return }

        let nsq = NSWorkspace.shared.notificationCenter

        // The ONLY events that arm auto-restore are the ones that actually
        // displace windows:
        //
        //   1. Monitor reconfiguration — an external display connecting or
        //      disconnecting (power-cycled monitor, laptop clamshell, cable
        //      pull). macOS reflows windows onto the remaining displays, so
        //      this is the real "my windows moved" event.
        //   2. Real system wake (didWake) — a full sleep/wake, which also
        //      reconnects displays and relaunches apps.
        //
        // Deliberately NOT triggers: display-backlight sleep/wake, screensaver,
        // and lock/unlock. Those fire constantly (every idle timeout) and do
        // NOT move any windows — arming restore on them just re-applied the
        // snapshot over and over, dragging windows (esp. VS Code, whose
        // identity drifts as you change files) back to a stale layout.
        displayWatcher.start()
        displaySubscription = displayWatcher.subscribe { [weak self] in
            self?.armRestore()
        }

        let wake = nsq.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.armRestore()
        }
        tokens.append(wake)
    }

    /// Arm the per-Space lazy restore and trigger the active-Space restore.
    /// The debouncer collapses the burst of reconfiguration callbacks macOS
    /// emits for a single connect/disconnect into one restore.
    private func armRestore() {
        eventLog?.recordWake()
        debouncer.signal()
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        let nsq = NSWorkspace.shared.notificationCenter
        let dnq = DistributedNotificationCenter.default()
        for token in tokens {
            nsq.removeObserver(token)
            dnq.removeObserver(token)
        }
        tokens.removeAll()
        if let id = displaySubscription {
            displayWatcher.unsubscribe(id)
            displaySubscription = nil
        }
        displayWatcher.stop()
    }
}
