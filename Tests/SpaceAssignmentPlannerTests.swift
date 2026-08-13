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

    func test_tiedSpaces_leaveTheAppAloneRatherThanCollapsingIt() {
        // One window on each of Spaces 7 and 2. Whichever is chosen misplaces
        // as many as it places, so the app must not be moved at all.
        let plan = SpaceAssignmentPlanner.plan(for: [
            entry("com.apple.Safari", space: 7, ordinal: 4),
            entry("com.apple.Safari", space: 2, ordinal: 1),
        ])
        XCTAssertTrue(plan.assignments.isEmpty, "a tie can never place more than it misplaces")
        XCTAssertEqual(plan.unrestorable.map(\.bundleID), ["com.apple.Safari"])
        XCTAssertEqual(plan.unrestorable.first?.windowCount, 2)
        XCTAssertEqual(plan.unrestorable.first?.spaceCount, 2)
        XCTAssertEqual(plan.totalLeftAlone, 2)
    }

    /// The bug that collapsed every VS Code window onto Space 0.
    ///
    /// `ordinalInApp` carries an AX creation ordinal for windows captured on the
    /// active Space and `Int(windowID)` for windows found by the cross-Space CG
    /// pass. The old tie-break compared those two numberings directly, so the
    /// capture Space — the only one with single-digit ordinals — won every tie
    /// and dragged the whole app onto it.
    func test_capturePassOrdinalsDoNotDecideTheTarget() {
        // Space 0 was active at capture (AX ordinals). Spaces 1 and 2 hold more
        // windows between them but were found by the CG pass, so their ordinals
        // are CG window numbers.
        let windows = [
            entry("com.microsoft.VSCode", space: 0, ordinal: 0),
            entry("com.microsoft.VSCode", space: 0, ordinal: 1),
            entry("com.microsoft.VSCode", space: 1, ordinal: 31_204),
            entry("com.microsoft.VSCode", space: 1, ordinal: 31_207),
            entry("com.microsoft.VSCode", space: 1, ordinal: 31_211),
            entry("com.microsoft.VSCode", space: 2, ordinal: 30_988),
        ]
        let plan = SpaceAssignmentPlanner.plan(for: windows)
        XCTAssertNotEqual(plan.assignments.first?.targetSpaceIndex, 0,
                          "Space 0 held the fewest windows; only its AX ordinals made it win")
        // Space 1 holds 3 of 6 — a plurality, but it misplaces 3, so the guard
        // leaves the app alone instead.
        XCTAssertTrue(plan.assignments.isEmpty)
        XCTAssertEqual(plan.unrestorable.first?.bundleID, "com.microsoft.VSCode")
        XCTAssertEqual(plan.unrestorable.first?.bestCaseSatisfied, 3)
        XCTAssertEqual(plan.unrestorable.first?.bestCaseDisplaced, 3)
    }

    func test_clearMajoritySurvivesTheGuard_evenWithCGOrdinals() {
        // 4 on Space 2 against 1 on Space 0: strictly more placed than
        // misplaced, so the move is worth making regardless of which pass
        // captured which window.
        let plan = SpaceAssignmentPlanner.plan(for: [
            entry("com.brave.Browser", space: 0, ordinal: 0),
            entry("com.brave.Browser", space: 2, ordinal: 30_101),
            entry("com.brave.Browser", space: 2, ordinal: 30_102),
            entry("com.brave.Browser", space: 2, ordinal: 30_103),
            entry("com.brave.Browser", space: 2, ordinal: 30_104),
        ])
        XCTAssertEqual(plan.assignments.first?.targetSpaceIndex, 2)
        XCTAssertEqual(plan.assignments.first?.satisfiedWindows, 4)
        XCTAssertEqual(plan.assignments.first?.displacedWindows, 1)
        XCTAssertTrue(plan.unrestorable.isEmpty)
    }

    func test_planIsDeterministicAcrossRepeatedRuns() {
        // Guards against relying on Dictionary iteration order, which varies
        // per process launch. Mixes a kept assignment with a skipped app so
        // both output arrays are exercised.
        let windows = [
            entry("com.apple.Safari", space: 7, ordinal: 4),
            entry("com.apple.Safari", space: 2, ordinal: 1),
            entry("com.apple.Terminal", space: 5, ordinal: 2),
            entry("com.apple.Terminal", space: 5, ordinal: 3),
            entry("com.apple.Terminal", space: 6, ordinal: 0),
        ]
        let first = SpaceAssignmentPlanner.plan(for: windows)
        XCTAssertEqual(first.assignments.map(\.bundleID), ["com.apple.Terminal"])
        XCTAssertEqual(first.unrestorable.map(\.bundleID), ["com.apple.Safari"])
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
