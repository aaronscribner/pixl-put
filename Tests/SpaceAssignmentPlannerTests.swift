import XCTest
import CoreGraphics
@testable import PixlPutCore

/// Covers the decision that the process-scoped relocation mechanism forces:
/// when one app's windows were captured on different Spaces, which Space wins,
/// and is the resulting partial restore accounted for honestly (ADR-0002).
final class SpaceAssignmentPlannerTests: XCTestCase {

    private func entry(
        _ bundleID: String,
        space: Int,
        ordinal: Int = 0,
        minimized: Bool = false
    ) -> WindowEntry {
        WindowEntry(
            bundleID: bundleID,
            identity: .documentPath(URL(fileURLWithPath: "/tmp/\(bundleID)-\(space)-\(ordinal)")),
            ordinalInApp: ordinal,
            displayFingerprintID: "display-1",
            spaceIndex: space,
            frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
            isMinimized: minimized,
            isFullscreen: false,
            capturedAt: Date(timeIntervalSince1970: 0)
        )
    }

    func test_singleAppOnOneSpace_isExact() {
        let plan = SpaceAssignmentPlanner.plan(for: [
            entry("com.brave.Browser", space: 3, ordinal: 0),
            entry("com.brave.Browser", space: 3, ordinal: 1),
        ])
        XCTAssertEqual(plan.assignments.count, 1)
        let assignment = try? XCTUnwrap(plan.assignments.first)
        XCTAssertEqual(assignment?.targetSpaceIndex, 3)
        XCTAssertEqual(assignment?.satisfiedWindows, 2)
        XCTAssertEqual(assignment?.displacedWindows, 0)
        XCTAssertTrue(plan.partial.isEmpty)
    }

    func test_majoritySpaceWins_andDisplacedCountIsReported() {
        // Three windows on Space 1, one on Space 5 — moving the single window
        // is strictly better than moving three.
        let plan = SpaceAssignmentPlanner.plan(for: [
            entry("com.brave.Browser", space: 1, ordinal: 0),
            entry("com.brave.Browser", space: 1, ordinal: 1),
            entry("com.brave.Browser", space: 1, ordinal: 2),
            entry("com.brave.Browser", space: 5, ordinal: 3),
        ])
        let assignment = plan.assignments.first
        XCTAssertEqual(assignment?.targetSpaceIndex, 1)
        XCTAssertEqual(assignment?.satisfiedWindows, 3)
        XCTAssertEqual(assignment?.displacedWindows, 1)
        XCTAssertEqual(plan.partial.count, 1, "a displaced window makes the restore partial")
        XCTAssertEqual(plan.totalDisplaced, 1)
    }

    func test_tieBreaksOnEarliestCreatedWindow_notDictionaryOrder() {
        // One window on each of Spaces 7 and 2. The window with the lowest
        // ordinal (created first) is the closest proxy for "primary".
        let plan = SpaceAssignmentPlanner.plan(for: [
            entry("com.apple.Safari", space: 7, ordinal: 4),
            entry("com.apple.Safari", space: 2, ordinal: 1),
        ])
        XCTAssertEqual(plan.assignments.first?.targetSpaceIndex, 2)
        XCTAssertEqual(plan.assignments.first?.displacedWindows, 1)
    }

    func test_tieBreakIsDeterministicAcrossRepeatedRuns() {
        // Guards against relying on Dictionary iteration order, which varies
        // per process launch.
        let windows = [
            entry("com.apple.Safari", space: 7, ordinal: 4),
            entry("com.apple.Safari", space: 2, ordinal: 1),
            entry("com.apple.Terminal", space: 5, ordinal: 2),
            entry("com.apple.Terminal", space: 6, ordinal: 0),
        ]
        let first = SpaceAssignmentPlanner.plan(for: windows)
        for _ in 0..<50 {
            XCTAssertEqual(SpaceAssignmentPlanner.plan(for: windows), first)
        }
    }

    func test_minimizedWindowsDoNotOutvoteVisibleOnes() {
        // Two minimized windows on Space 9 must not drag the one visible
        // window off Space 1 — the user can only see the visible one.
        let plan = SpaceAssignmentPlanner.plan(for: [
            entry("com.apple.Notes", space: 1, ordinal: 0),
            entry("com.apple.Notes", space: 9, ordinal: 1, minimized: true),
            entry("com.apple.Notes", space: 9, ordinal: 2, minimized: true),
        ])
        XCTAssertEqual(plan.assignments.first?.targetSpaceIndex, 1)
        XCTAssertEqual(plan.assignments.first?.satisfiedWindows, 1)
        XCTAssertEqual(plan.assignments.first?.displacedWindows, 0)
    }

    func test_appWithOnlyMinimizedWindows_isSkipped() {
        let plan = SpaceAssignmentPlanner.plan(for: [
            entry("com.apple.Notes", space: 9, ordinal: 0, minimized: true),
        ])
        XCTAssertTrue(plan.assignments.isEmpty, "no visible window means no Space to pin the app to")
    }

    func test_appsArePlannedIndependently() {
        let plan = SpaceAssignmentPlanner.plan(for: [
            entry("com.brave.Browser", space: 3, ordinal: 0),
            entry("com.apple.Terminal", space: 7, ordinal: 0),
        ])
        XCTAssertEqual(plan.assignments.map(\.bundleID), ["com.apple.Terminal", "com.brave.Browser"])
        XCTAssertEqual(plan.assignments.map(\.targetSpaceIndex), [7, 3])
        XCTAssertEqual(plan.totalSatisfied, 2)
    }

    func test_emptySnapshot_producesEmptyPlan() {
        XCTAssertTrue(SpaceAssignmentPlanner.plan(for: []).assignments.isEmpty)
    }
}
