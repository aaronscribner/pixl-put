import Foundation

/// In-memory log of sleep / wake / per-Space-visit timestamps used by the
/// lazy-restore policy in `AppLifecycle`. Fully thread-safe via an
/// internal lock; designed to be queried from any actor / queue without
/// requiring main-actor hops.
///
/// **Lifetime**: process-scoped by default; `Phase E` adds persistence
/// to `~/Library/Application Support/DisplayMaid-Next/event-log.json` so
/// the policy survives an app restart but not a system reboot (Space IDs
/// aren't stable across reboot — persisting them would mislead).
public final class EventLog: @unchecked Sendable {

    private let lock = NSLock()
    private var _lastSleepAt: Date?
    private var _lastWakeAt: Date?
    /// Keyed by per-display Space index (matches `WindowEntry.spaceIndex`).
    /// In Phase A we use `SpaceResolver.activeSpaceIndex()` directly; in
    /// Phase D this expands to a `(displayFingerprintID, spaceIndex)`
    /// composite once cross-display Space tracking lands.
    private var _spaceLastVisitedAt: [Int: Date] = [:]

    public init() {}

    // MARK: - Sleep / Wake

    public func recordSleep(at date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        _lastSleepAt = date
    }

    public func recordWake(at date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        _lastWakeAt = date
    }

    public var lastSleepAt: Date? {
        lock.lock(); defer { lock.unlock() }
        return _lastSleepAt
    }

    public var lastWakeAt: Date? {
        lock.lock(); defer { lock.unlock() }
        return _lastWakeAt
    }

    // MARK: - Space visits

    /// Record that the user is now viewing the given Space. Should be
    /// called from the `NSWorkspace.activeSpaceDidChangeNotification`
    /// handler in AppLifecycle.
    public func recordSpaceVisit(spaceIndex: Int, at date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        _spaceLastVisitedAt[spaceIndex] = date
    }

    public func lastVisited(spaceIndex: Int) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return _spaceLastVisitedAt[spaceIndex]
    }

    public func allSpaceVisits() -> [Int: Date] {
        lock.lock(); defer { lock.unlock() }
        return _spaceLastVisitedAt
    }

    // MARK: - Policy predicates

    /// Phase D auto-restore predicate: "this Space hasn't been visited
    /// since the last wake, so a snapshot-restore would be welcome."
    ///
    /// Returns `true` when there IS a last-wake timestamp AND either
    /// (a) the user has never visited this Space, or (b) their last
    /// visit predates the most recent wake. Returns `false` when no
    /// wake event has happened yet (cold start — restore is handled by
    /// the wake handler itself, not the Space-switch handler).
    public func shouldRestoreOnSwitch(toSpaceIndex spaceIndex: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let wake = _lastWakeAt else { return false }
        guard let visit = _spaceLastVisitedAt[spaceIndex] else { return true }
        return visit < wake
    }
}
