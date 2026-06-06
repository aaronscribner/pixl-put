import XCTest
import CoreGraphics
@testable import PixlPutCore

/// Tests for the pure planning behind "Restore Spaces": the Ctrl+Arrow
/// navigation plan and the relocation decision logic. The side-effecting
/// parts (keystroke synthesis, CGSMoveWindowsToManagedSpace, AX frame
/// setting) are validated on real hardware.
final class SpaceRestoreTests: XCTestCase {

    // MARK: - SpaceSwitcher.plan

    func testPlanStepsRightWhenTargetIsAhead() {
        let ordered: [UInt64] = [10, 20, 30, 40]
        let plan = SpaceSwitcher.plan(orderedSpaceIDs: ordered, activeSpaceID: 10, targetSpaceID: 40)
        XCTAssertEqual(plan, SpaceSwitcher.Plan(direction: .right, steps: 3))
    }

    func testPlanStepsLeftWhenTargetIsBehind() {
        let ordered: [UInt64] = [10, 20, 30, 40]
        let plan = SpaceSwitcher.plan(orderedSpaceIDs: ordered, activeSpaceID: 30, targetSpaceID: 10)
        XCTAssertEqual(plan, SpaceSwitcher.Plan(direction: .left, steps: 2))
    }

    func testPlanIsZeroStepsWhenAlreadyOnTarget() {
        let ordered: [UInt64] = [10, 20, 30]
        let plan = SpaceSwitcher.plan(orderedSpaceIDs: ordered, activeSpaceID: 20, targetSpaceID: 20)
        XCTAssertEqual(plan?.steps, 0)
    }

    func testPlanIsNilWhenSpaceNotInRow() {
        let ordered: [UInt64] = [10, 20, 30]
        XCTAssertNil(SpaceSwitcher.plan(orderedSpaceIDs: ordered, activeSpaceID: 99, targetSpaceID: 20))
        XCTAssertNil(SpaceSwitcher.plan(orderedSpaceIDs: ordered, activeSpaceID: 10, targetSpaceID: 99))
    }

    // MARK: - SpaceRestorePlanner.targetSpaceByKey

    private func entry(
        bundle: String, identity: WindowIdentity, ordinal: Int, space: Int
    ) -> WindowEntry {
        WindowEntry(
            bundleID: bundle, identity: identity, ordinalInApp: ordinal,
            displayFingerprintID: "d", spaceIndex: space,
            frame: CGRectCodable(x: 0, y: 0, width: 100, height: 100),
            isMinimized: false, isFullscreen: false,
            capturedAt: Date(timeIntervalSince1970: 0)
        )
    }

    func testTargetMapExcludesOrdinalOnlyIdentities() {
        let url = URL(string: "file:///work/a")!
        let windows = [
            entry(bundle: "com.code", identity: .editorWorkspace(url), ordinal: 0, space: 2),
            entry(bundle: "com.finder", identity: .ordinal(0), ordinal: 0, space: 1),
        ]
        let map = SpaceRestorePlanner.targetSpaceByKey(windows)
        // editorWorkspace is kept; ordinal-only is excluded (unreliable match).
        XCTAssertEqual(map.count, 1)
        XCTAssertEqual(map[SpaceRestorePlanner.matchKey(windows[0])], 2)
        XCTAssertNil(map[SpaceRestorePlanner.matchKey(windows[1])])
    }

    func testTargetMapDropsAmbiguousKeyOnTwoSpaces() {
        let url = URL(string: "https://example.com")!
        let windows = [
            entry(bundle: "com.brave", identity: .documentPath(url), ordinal: 0, space: 1),
            entry(bundle: "com.brave", identity: .documentPath(url), ordinal: 0, space: 3),
        ]
        let map = SpaceRestorePlanner.targetSpaceByKey(windows)
        XCTAssertTrue(map.isEmpty, "a key seen on two Spaces is ambiguous and must be dropped")
    }

    // MARK: - SpaceRestorePlanner.relocations

    func testRelocationsOnlyForWindowsOnTheWrongSpace() {
        let targets = ["a": 2, "b": 0, "c": 3]
        let live = [
            (key: "a", currentSpaceIndex: 0), // belongs on 2 -> relocate
            (key: "b", currentSpaceIndex: 0), // already on 0 -> leave
            (key: "c", currentSpaceIndex: 3), // already on 3 -> leave
            (key: "x", currentSpaceIndex: 1), // no target -> leave
        ]
        let result = SpaceRestorePlanner.relocations(live: live, targets: targets)
        XCTAssertEqual(result, [SpaceRestorePlanner.Relocation(key: "a", targetSpaceIndex: 2)])
    }

    func testDistinctSpaceIndicesSortedAscending() {
        let url = URL(string: "file:///x")!
        let windows = [
            entry(bundle: "a", identity: .documentPath(url), ordinal: 0, space: 3),
            entry(bundle: "b", identity: .documentPath(url), ordinal: 1, space: 0),
            entry(bundle: "c", identity: .documentPath(url), ordinal: 2, space: 3),
        ]
        XCTAssertEqual(SpaceRestorePlanner.distinctSpaceIndices(windows), [0, 3])
    }
}
