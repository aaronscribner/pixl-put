import XCTest
@testable import PixlPutCore

/// Test clock that schedules every action 1ms from now — lets us exercise
/// the coalescing logic in real wall-clock time without slowing tests down.
struct FastClock: Clock {
    func dispatchTimeFromNow(seconds: TimeInterval) -> DispatchTime {
        .now() + .milliseconds(20)
    }
}

final class DebouncerTests: XCTestCase {

    // T020 — Many signals within window collapse into one action
    func test_debouncer_whenMultipleSignals_thenFiresExactlyOnce() {
        let expectation = expectation(description: "fires once")
        let counter = Counter()
        let d = Debouncer(window: 0.02, clock: FastClock()) { @Sendable in
            counter.increment()
            expectation.fulfill()
        }
        for _ in 0..<5 { d.signal() }
        wait(for: [expectation], timeout: 1.0)
        // Sleep a touch longer in case more fired (they shouldn't).
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(counter.value, 1)
    }

    // T021 — Paused debouncer drops signals
    func test_debouncer_whenPaused_thenDoesNotFire() {
        let counter = Counter()
        let d = Debouncer(window: 0.02, clock: FastClock()) { @Sendable in
            counter.increment()
        }
        d.setPaused(true)
        for _ in 0..<3 { d.signal() }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(counter.value, 0)
    }

    // Pause cancels in-flight action
    func test_debouncer_whenPausedAfterSignal_thenInflightCancelled() {
        let counter = Counter()
        let d = Debouncer(window: 0.5, clock: SystemClock()) { @Sendable in
            counter.increment()
        }
        d.signal()
        d.setPaused(true)
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(counter.value, 0)
    }

    // Unpause + signal works
    func test_debouncer_whenUnpausedAndSignalled_thenFires() {
        let expectation = expectation(description: "fires after unpause")
        let d = Debouncer(window: 0.02, clock: FastClock()) { @Sendable in
            expectation.fulfill()
        }
        d.setPaused(true)
        d.signal() // dropped
        d.setPaused(false)
        d.signal()
        wait(for: [expectation], timeout: 1.0)
    }
}

/// Thread-safe counter for tests.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func increment() {
        lock.lock(); _value += 1; lock.unlock()
    }
}
