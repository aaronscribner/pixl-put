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

        // Events that arm auto-restore — every way windows get displaced:
        //
        //   1. Monitor reconfiguration — an external display connecting or
        //      disconnecting (power-cycled monitor, laptop clamshell, cable
        //      pull). macOS reflows windows onto the remaining displays, so
        //      this is the real "my windows moved" event.
        //   2. Real system wake (didWake) — a full sleep/wake, which also
        //      reconnects displays and relaunches apps.
        //   3. Display wake (screensDidWake) — on AC power the machine often
        //      never system-sleeps: overnight it darkwakes while only the
        //      DISPLAY sleeps, and the G9 drops its DisplayPort link when the
        //      backlight goes down, displacing windows with NO didWake and NO
        //      reconfiguration event the app sees (measured 2026-08-06:
        //      display off 01:22 → on 07:29, VS Code displaced, zero
        //      triggers fired). An earlier revision excluded this on the
        //      claim that backlight wake "does not move windows" — false on
        //      this hardware — and because re-applying the snapshot was
        //      destructive back when auto-capture kept mutating it. Capture
        //      is manual now and restore is idempotent, so a redundant
        //      trigger moves nothing and costs milliseconds.
        //   4. Screen unlock — the wake-restore path skips while the screen
        //      is locked (AX enumerates loginwindow with bogus frames), and
        //      at display-wake the screen usually IS still locked. Without
        //      an unlock trigger, triggers 1–3 all fall into the lock gate
        //      and nothing ever re-fires. The debouncer coalesces the
        //      wake→unlock burst into one restore.
        displayWatcher.start()
        displaySubscription = displayWatcher.subscribe { [weak self] in
            self?.armRestore(trigger: "display-reconfiguration")
        }

        let wake = nsq.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.armRestore(trigger: "system-wake")
        }
        tokens.append(wake)

        let screensWake = nsq.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.armRestore(trigger: "screens-wake")
        }
        tokens.append(screensWake)

        let unlock = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: nil
        ) { [weak self] _ in
            self?.armRestore(trigger: "unlock")
        }
        tokens.append(unlock)
    }

    /// Arm the per-Space lazy restore and trigger the active-Space restore.
    /// The debouncer collapses the burst of reconfiguration callbacks macOS
    /// emits for a single connect/disconnect into one restore.
    ///
    /// Every arm logs its trigger: "restore didn't run and the log is empty"
    /// must never again be ambiguous between a dead trigger and a skip.
    private func armRestore(trigger: String) {
        DiagnosticLog.write("wake", "restore armed: trigger=\(trigger)")
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
