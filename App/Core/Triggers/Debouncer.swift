import Foundation

/// Generic event coalescer. Multiple events within `window` collapse into a
/// single invocation of `action` after the window expires from the last event.
/// Honours an externally-controlled `paused` flag (Story-2 acceptance #3).
///
/// Construction does not start anything; the first `signal()` call begins the
/// debounce window. Thread-safe via an internal lock.
public final class Debouncer: @unchecked Sendable {
    public typealias Action = @Sendable () -> Void

    public let window: TimeInterval
    private let clock: any Clock
    private let queue: DispatchQueue
    private let action: Action

    private let lock = NSLock()
    private var pendingItem: DispatchWorkItem?
    /// External pause state — when `true`, `signal()` is a no-op.
    private var _paused: Bool = false

    public var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return _paused
    }

    public init(
        window: TimeInterval = 5.0,
        clock: any Clock = SystemClock(),
        queue: DispatchQueue = .global(qos: .utility),
        action: @escaping Action
    ) {
        self.window = window
        self.clock = clock
        self.queue = queue
        self.action = action
    }

    public func setPaused(_ paused: Bool) {
        lock.lock(); defer { lock.unlock() }
        _paused = paused
        if paused {
            pendingItem?.cancel()
            pendingItem = nil
        }
    }

    /// Receive an event. Any pending invocation is cancelled and a new one is
    /// scheduled `window` seconds from now. While paused, the call is dropped.
    public func signal() {
        lock.lock()
        if _paused {
            lock.unlock()
            return
        }
        pendingItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.action()
        }
        pendingItem = item
        let delay = clock.dispatchTimeFromNow(seconds: window)
        lock.unlock()
        queue.asyncAfter(deadline: delay, execute: item)
    }

    /// Cancel any pending action (without invoking it).
    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        pendingItem?.cancel()
        pendingItem = nil
    }
}

/// Clock seam so tests can inject deterministic time.
public protocol Clock: Sendable {
    func dispatchTimeFromNow(seconds: TimeInterval) -> DispatchTime
}

public struct SystemClock: Clock {
    public init() {}
    public func dispatchTimeFromNow(seconds: TimeInterval) -> DispatchTime {
        .now() + .milliseconds(Int(seconds * 1000))
    }
}
