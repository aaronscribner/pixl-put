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
    /// True from the moment the machine starts to sleep until the following
    /// resume is consumed. This is what distinguishes a *real* wake (system
    /// slept → apps relaunched / displays reconnected → windows displaced)
    /// from a bare screensaver or lock/unlock cycle (nothing moved). Only a
    /// real wake is allowed to arm the restore gate; otherwise every Space
    /// re-restores its stale snapshot the next time it's visited — even an
    /// hour later — clobbering whatever the user has since arranged.
    private var pendingWake = false

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

        // "Sleep" markers. This Mac (like many desktop/clamshell setups with
        // Electron/video wake-locks) almost never *system*-sleeps — it only
        // sleeps its DISPLAY. macOS reports display sleep via
        // screensDidSleep and full system sleep via willSleep. We mark a
        // pending wake on EITHER, because either one is followed by a resume
        // that may have reflowed windows (an external monitor powering off
        // with the display disconnects/reconnects it). Nothing else sets
        // this, so a bare screensaver/lock with no sleep can't look like a
        // wake — which is what kept the gate from spuriously re-opening.
        for sleepName in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            let sleep = nsq.addObserver(forName: sleepName, object: nil, queue: nil) { [weak self] _ in
                guard let self = self else { return }
                self.lock.lock(); self.pendingWake = true; self.lock.unlock()
            }
            tokens.append(sleep)
        }

        // "Wake" events. Display wake (screensDidWake) is the one that actually
        // fires on this machine; system wake (didWake) fires on the rare real
        // sleep. Both consume the pending wake → arm the gate + trigger the
        // active-Space restore. Consuming means a single sleep produces a
        // single armed wake, no matter how many resume events macOS emits.
        for wakeName in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            let wake = nsq.addObserver(forName: wakeName, object: nil, queue: nil) { [weak self] _ in
                self?.consumeWakeIfPending()
            }
            tokens.append(wake)
        }

        // Unlock / screensaver-stop count as a wake ONLY when a real sleep
        // preceded them. This is the fix for "Space reverts to the wrong
        // config an hour after wake": a bare screensaver-stop used to call
        // recordWake() unconditionally, re-opening the restore gate for every
        // Space long after the actual wake.
        let unlocked = dnq.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.consumeWakeIfPending()
        }
        tokens.append(unlocked)

        let saverStop = dnq.addObserver(
            forName: Notification.Name("com.apple.screensaver.didstop"),
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.consumeWakeIfPending()
        }
        tokens.append(saverStop)

        // A monitor change is NOT a wake and does NOT arm restore.
        // (displayWatcher left unused here on purpose — kept as a field to
        // avoid churn.)
    }

    /// Honor a resume as a wake only if the machine actually slept. Consumes
    /// the pending-wake flag so a single sleep produces a single armed wake,
    /// no matter how many unlock/screensaver-stop events the resume emits.
    private func consumeWakeIfPending() {
        lock.lock()
        let wasPending = pendingWake
        pendingWake = false
        lock.unlock()
        guard wasPending else { return }
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
