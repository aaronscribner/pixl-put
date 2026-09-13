import XCTest
import CoreGraphics
@testable import PixlPutCore

/// "Restore windows to their Spaces" after a reboot (ADR-0002).
///
/// Two things change when the machine restarts: every app gets a new pid and
/// renumbers its window creation ordinals, and the assigner has to judge an
/// app's Space from windows it has never seen. Both used to make the restore a
/// silent no-op; these tests pin the rules that keep it working.
final class SpaceRestoreAfterRestartTests: XCTestCase {

    // MARK: - Assigner verification

    private let target: UInt64 = 7

    func test_placement_ignoresWindowsThatReportNoSpace() {
        // The measured post-reboot shape: the first CG window is an off-screen
        // helper with no Space; the real windows follow. Judging by the first
        // window alone reported every such app as "did not take effect".
        let spaces: [[UInt64]] = [[], [], [7], [7]]
        XCTAssertEqual(SpaceAssigner.placement(windowSpaces: spaces, target: target), .all)
    }

    func test_placement_ignoresStickyAllDesktopsWindows() {
        // A window on every Space contains the target by construction and
        // must not count as evidence that the app moved.
        let spaces: [[UInt64]] = [[3, 4, 5, 6, 7], [3]]
        XCTAssertEqual(SpaceAssigner.placement(windowSpaces: spaces, target: target), .none)
    }

    func test_placement_isUnknownWhenNoWindowReportsASingleSpace() {
        XCTAssertEqual(SpaceAssigner.placement(windowSpaces: [[], [3, 7]], target: target), .unknown)
        XCTAssertEqual(SpaceAssigner.placement(windowSpaces: [], target: target), .unknown)
    }

    func test_placement_distinguishesAllSomeNone() {
        XCTAssertEqual(SpaceAssigner.placement(windowSpaces: [[7], [7]], target: target), .all)
        XCTAssertEqual(SpaceAssigner.placement(windowSpaces: [[7], [3]], target: target), .some)
        XCTAssertEqual(SpaceAssigner.placement(windowSpaces: [[3], [4]], target: target), .none)
    }

    func test_outcome_alreadyOnTargetDefaultsToFalse() {
        let outcome = SpaceAssigner.Outcome(bundleID: "a", targetSpaceIndex: 1, applied: true)
        XCTAssertFalse(outcome.alreadyOnTarget)
    }

    // MARK: - Per-window matching survives an app restart

    private func entry(_ bundleID: String, identity: WindowIdentity, space: Int, ordinal: Int = 0) -> WindowEntry {
        WindowEntry(
            bundleID: bundleID, identity: identity, ordinalInApp: ordinal,
            displayFingerprintID: "d1", spaceIndex: space,
            frame: CGRectCodable(x: 0, y: 0, width: 100, height: 100),
            isMinimized: false, isFullscreen: false, capturedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func live(_ bundleID: String, identity: WindowIdentity, windowID: CGWindowID?, ordinal: Int = 0) -> LiveWindow {
        LiveWindow(
            bundleID: bundleID, identity: identity, ordinalInApp: ordinal,
            currentFrame: CGRectCodable(x: 0, y: 0, width: 100, height: 100),
            currentDisplayFingerprintID: "d1", windowID: windowID, isFullscreen: false
        )
    }

    private let workspace = WindowIdentity.editorWorkspace(URL(fileURLWithPath: "/src/PixPut"))
    private let tabsA = WindowIdentity.browserTabSet([URL(string: "https://a.example")!])

    func test_deepIdentityMatchesEvenWhenOrdinalChangedAcrossRestart() {
        // Captured as the app's 4th window; after the reboot it is the 1st.
        let moves = SpaceAssignmentPlanner.perWindowMoves(
            snapshot: [entry("com.microsoft.VSCode", identity: workspace, space: 3, ordinal: 3)],
            live: [live("com.microsoft.VSCode", identity: workspace, windowID: 101, ordinal: 0)]
        )
        XCTAssertEqual(moves.map(\.targetSpaceIndex), [3])
    }

    func test_sameIdentityOnSeveralSpaces_usesOrdinalToDisambiguate() {
        let snapshot = [
            entry("com.brave.Browser", identity: tabsA, space: 3, ordinal: 0),
            entry("com.brave.Browser", identity: tabsA, space: 7, ordinal: 1),
        ]
        let moves = SpaceAssignmentPlanner.perWindowMoves(
            snapshot: snapshot,
            live: [
                live("com.brave.Browser", identity: tabsA, windowID: 101, ordinal: 0),
                live("com.brave.Browser", identity: tabsA, windowID: 202, ordinal: 1),
                live("com.brave.Browser", identity: tabsA, windowID: 303, ordinal: 9), // no exact ordinal: left alone
            ]
        )
        XCTAssertEqual(moves.first { $0.windowID == 101 }?.targetSpaceIndex, 3)
        XCTAssertEqual(moves.first { $0.windowID == 202 }?.targetSpaceIndex, 7)
        XCTAssertNil(moves.first { $0.windowID == 303 })
    }

    func test_sameIdentityAndOrdinalOnTwoSpaces_isStillAmbiguous() {
        let moves = SpaceAssignmentPlanner.perWindowMoves(
            snapshot: [
                entry("com.brave.Browser", identity: tabsA, space: 3),
                entry("com.brave.Browser", identity: tabsA, space: 7),
            ],
            live: [live("com.brave.Browser", identity: tabsA, windowID: 101)]
        )
        XCTAssertTrue(moves.isEmpty)
    }

    // MARK: - Backend selection reports its fallback

    func test_selectionExplainsFallbackWhenYabaiIsInstalledButNotAnswering() {
        let selection = SpaceRelocationBackendFactory.select()
        if let yabai = YabaiRelocationBackend.locate(), !yabai.isAvailable {
            XCTAssertFalse(selection.backend.supportsPerWindowMoves)
            XCTAssertNotNil(selection.fallbackReason)
        } else {
            XCTAssertNil(selection.fallbackReason)
        }
    }
}
