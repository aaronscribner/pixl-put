import XCTest
@testable import PixlPutCore

final class EventLogTests: XCTestCase {

    func test_eventLog_freshlyInitialized_hasNoSleepWakeOrVisits() {
        let log = EventLog()
        XCTAssertNil(log.lastSleepAt)
        XCTAssertNil(log.lastWakeAt)
        XCTAssertTrue(log.allSpaceVisits().isEmpty)
    }

    func test_eventLog_recordSleepWake_persistsLatestValue() {
        let log = EventLog()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let t1 = Date(timeIntervalSince1970: 1_001_000)
        log.recordSleep(at: t0)
        log.recordWake(at: t1)
        XCTAssertEqual(log.lastSleepAt, t0)
        XCTAssertEqual(log.lastWakeAt, t1)
    }

    func test_eventLog_recordSpaceVisit_keepsPerSpaceTimestamps() {
        let log = EventLog()
        let t1 = Date(timeIntervalSince1970: 100)
        let t2 = Date(timeIntervalSince1970: 200)
        log.recordSpaceVisit(spaceIndex: 0, at: t1)
        log.recordSpaceVisit(spaceIndex: 1, at: t2)
        XCTAssertEqual(log.lastVisited(spaceIndex: 0), t1)
        XCTAssertEqual(log.lastVisited(spaceIndex: 1), t2)
        XCTAssertNil(log.lastVisited(spaceIndex: 2))
    }

    // Phase D core predicate — the whole reason the EventLog exists.
    func test_shouldRestoreOnSwitch_predicate() {
        let log = EventLog()

        // No wake recorded yet: predicate is false (cold start handled by wake handler).
        XCTAssertFalse(log.shouldRestoreOnSwitch(toSpaceIndex: 0))

        let wakeAt = Date(timeIntervalSince1970: 1_000)
        log.recordWake(at: wakeAt)

        // Wake recorded, never visited Space 0 yet → restore IS warranted.
        XCTAssertTrue(log.shouldRestoreOnSwitch(toSpaceIndex: 0))

        // User visits Space 0 (post-wake) → no longer warranted.
        log.recordSpaceVisit(spaceIndex: 0, at: wakeAt.addingTimeInterval(10))
        XCTAssertFalse(log.shouldRestoreOnSwitch(toSpaceIndex: 0))

        // A visit BEFORE the most recent wake → still warranted (the
        // stale visit doesn't count). This handles: user visited Space 2
        // yesterday, then slept, then woke up today — Space 2 should
        // still get restored on first switch.
        log.recordSpaceVisit(spaceIndex: 2, at: wakeAt.addingTimeInterval(-100))
        XCTAssertTrue(log.shouldRestoreOnSwitch(toSpaceIndex: 2))

        // After a fresh wake, all previously-visited spaces are warranted again.
        let newWake = wakeAt.addingTimeInterval(1_000)
        log.recordWake(at: newWake)
        XCTAssertTrue(log.shouldRestoreOnSwitch(toSpaceIndex: 0))
        XCTAssertTrue(log.shouldRestoreOnSwitch(toSpaceIndex: 2))
    }
}
