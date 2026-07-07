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
        let dnq = DistributedNotificationCenter.default()

        let wake = nsq.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.eventLog?.recordWake()
            self?.debouncer.signal()
        }
        tokens.append(wake)

        let unlocked = dnq.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.eventLog?.recordWake()
            self?.debouncer.signal()
        }
        tokens.append(unlocked)

        let saverStop = dnq.addObserver(
            forName: Notification.Name("com.apple.screensaver.didstop"),
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.eventLog?.recordWake()
            self?.debouncer.signal()
        }
        tokens.append(saverStop)

        displayWatcher.start()
        displaySubscription = displayWatcher.subscribe { [weak self] in
            // A display reconfiguration (monitor plugged in / arrangement
            // changed) must re-arm the per-Space restore the same way a wake
            // does. Without this, only the ACTIVE Space restores on a display
            // change: `EventLog.shouldRestoreOnSwitch` gates on the last-wake
            // timestamp, so Spaces the user already visited this session never
            // restore when switched to. Recording a wake here resets that gate
            // so each Space restores the first time it's visited after the
            // display change.
            self?.eventLog?.recordWake()
            self?.debouncer.signal()
        }
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
