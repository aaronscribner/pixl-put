import XCTest
@testable import PixlPutCore

/// `runningApplications` can list one process twice. Building the PID map
/// must not trap on that — it crashed the app twice on 2026-10-02.
final class CGWindowEnumeratorTests: XCTestCase {

    func testDuplicatePIDDoesNotTrapAndKeepsFirstEntry() {
        let map = CGWindowEnumerator.bundleIDsByPID([
            (72739, "com.apple.WebKit.WebContent"),
            (100, "com.microsoft.teams2"),
            (72739, "com.apple.WebKit.WebContent.duplicate"),
        ])
        XCTAssertEqual(map.count, 2)
        XCTAssertEqual(map[72739], "com.apple.WebKit.WebContent")
        XCTAssertEqual(map[100], "com.microsoft.teams2")
    }

    func testEmptyInputGivesEmptyMap() {
        XCTAssertTrue(CGWindowEnumerator.bundleIDsByPID([]).isEmpty)
    }
}
