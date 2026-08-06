import XCTest
import AppKit
import CoreGraphics
@testable import PixlPutCore

/// End-to-end proof that cross-Space relocation actually moves a real window
/// (ADR-0002). Requires a live GUI session and at least two user Spaces, so it
/// is opt-in and never runs in CI:
///
///     PIXPUT_LIVE_SPACE_TESTS=1 swift test --filter SpaceAssignerLiveTests
///
/// Uses Calculator as the subject — disposable, no user documents, quit at the
/// end so the process-lifetime Space assignment dies with it.
final class SpaceAssignerLiveTests: XCTestCase {

    private var enabled: Bool { ProcessInfo.processInfo.environment["PIXPUT_LIVE_SPACE_TESTS"] == "1" }
    private let bundleID = "com.apple.calculator"

    override func setUpWithError() throws {
        try XCTSkipUnless(enabled, "set PIXPUT_LIVE_SPACE_TESTS=1 to run live Space tests")
        try XCTSkipUnless(PrivateCGS.canRelocateAcrossSpaces, "CGSProcessAssignToSpace unavailable")
    }

    func test_assignerMovesARealWindowToADifferentSpace() throws {
        let resolver = SpaceResolver()
        XCTAssertTrue(resolver.canRelocateAcrossSpaces)

        // Two distinct user Spaces on some display, or there is nothing to prove.
        let displays = PrivateCGS.managedDisplaySpaces()
        let display = try XCTUnwrap(displays.first { $0.value.count >= 2 },
                                    "needs a display with 2+ Spaces — add one in Mission Control")
        let spaceIDs = display.value

        let app = try launchCalculator()
        defer { app.terminate() }

        let pid = app.processIdentifier
        let probeWindow = try XCTUnwrap(waitForWindow(ofPID: pid), "Calculator never showed a window")
        let originSpaceID = try XCTUnwrap(PrivateCGS.spaces(forWindow: probeWindow).first)
        let originIndex = try XCTUnwrap(spaceIDs.firstIndex(of: originSpaceID))

        // Target any Space that isn't the one it is already on.
        let targetIndex = try XCTUnwrap(spaceIDs.indices.first { $0 != originIndex })

        let plan = SpaceAssignmentPlanner.Plan(assignments: [
            .init(bundleID: bundleID, targetSpaceIndex: targetIndex,
                  satisfiedWindows: 1, displacedWindows: 0)
        ])

        let outcomes = SpaceAssigner().apply(plan, displayUUID: display.key)
        let outcome = try XCTUnwrap(outcomes.first)
        XCTAssertTrue(outcome.applied, "assignment failed: \(outcome.failureReason ?? "unknown")")

        // Independent confirmation — re-read rather than trusting the outcome.
        let landedOn = PrivateCGS.spaces(forWindow: probeWindow)
        XCTAssertTrue(landedOn.contains(spaceIDs[targetIndex]),
                      "window reports Spaces \(landedOn), expected \(spaceIDs[targetIndex])")
        XCTAssertFalse(landedOn.contains(originSpaceID), "window should have left its origin Space")
    }

    func test_assignmentToAMissingSpaceIndexFailsCleanly() throws {
        let app = try launchCalculator()
        defer { app.terminate() }
        _ = waitForWindow(ofPID: app.processIdentifier)

        // Index far beyond any real Space count — must report, not crash or lie.
        let plan = SpaceAssignmentPlanner.Plan(assignments: [
            .init(bundleID: bundleID, targetSpaceIndex: 9_999, satisfiedWindows: 1, displacedWindows: 0)
        ])
        let outcome = try XCTUnwrap(SpaceAssigner().apply(plan).first)
        XCTAssertFalse(outcome.applied)
        XCTAssertEqual(outcome.failureReason, "Space index 9999 no longer exists")
    }

    func test_appThatIsNotRunningIsReportedNotCrashed() throws {
        let plan = SpaceAssignmentPlanner.Plan(assignments: [
            .init(bundleID: "com.example.definitely.not.running",
                  targetSpaceIndex: 0, satisfiedWindows: 1, displacedWindows: 0)
        ])
        let outcome = try XCTUnwrap(SpaceAssigner().apply(plan).first)
        XCTAssertFalse(outcome.applied)
        XCTAssertEqual(outcome.failureReason, "app not running")
    }

    // MARK: - Helpers

    private func launchCalculator() throws -> NSRunningApplication {
        if let existing = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID }) {
            return existing
        }
        let url = try XCTUnwrap(NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID))
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false

        var launched: NSRunningApplication?
        let done = expectation(description: "Calculator launched")
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, _ in
            launched = app
            done.fulfill()
        }
        wait(for: [done], timeout: 15)
        return try XCTUnwrap(launched)
    }

    private func waitForWindow(ofPID pid: pid_t) -> CGWindowID? {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let windows = CGWindowEnumerator.enumerateAllWindows().filter { $0.ownerPID == pid }
            if let first = windows.first, !PrivateCGS.spaces(forWindow: first.windowID).isEmpty {
                return first.windowID
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }
}
