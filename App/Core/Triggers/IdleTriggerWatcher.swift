import Foundation
import AppKit

/// Subscribes to every "machine going idle" signal that macOS exposes, and
/// routes each through a single `Debouncer` so they collapse into one
/// capture event per 5-second window (spec FR-005, FR-007).
///
/// Sources subscribed:
///   - `com.apple.screensaver.didstart`     (distributed notification)
///   - `com.apple.screenIsLocked`           (distributed notification)
///   - `NSWorkspace.screensDidSleepNotification`
public final class IdleTriggerWatcher: @unchecked Sendable {

    private let debouncer: Debouncer
    private let eventLog: EventLog?
    private var tokens: [Any] = []
    private let lock = NSLock()

    public init(debouncer: Debouncer, eventLog: EventLog? = nil) {
        self.debouncer = debouncer
        self.eventLog = eventLog
    }

    deinit { stop() }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard tokens.isEmpty else { return }

        let nsq = NSWorkspace.shared.notificationCenter
        let dnq = DistributedNotificationCenter.default()

        let sleep = nsq.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.eventLog?.recordSleep()
            self?.debouncer.signal()
        }
        tokens.append(sleep)

        let saverStart = dnq.addObserver(
            forName: Notification.Name("com.apple.screensaver.didstart"),
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.eventLog?.recordSleep()
            self?.debouncer.signal()
        }
        tokens.append(saverStart)

        let locked = dnq.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.eventLog?.recordSleep()
            self?.debouncer.signal()
        }
        tokens.append(locked)
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
    }

    public func setPaused(_ paused: Bool) {
        debouncer.setPaused(paused)
    }
}
