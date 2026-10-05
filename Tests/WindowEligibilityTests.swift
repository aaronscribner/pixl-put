import XCTest
@testable import PixlPutCore

/// Which Accessibility windows PixPut saves and restores. The rule mirrors
/// yabai's `window_is_real`: yabai is the cross-Space actuator, so a window
/// it will not track cannot be moved, and one PixPut saves anyway only takes
/// an ordinal from a real window of the same app.
final class WindowEligibilityTests: XCTestCase {

    func test_standardFloatingAndDialogWindows_areRestorable() {
        XCTAssertTrue(AXClient.isRestorableWindow(role: "AXWindow", subrole: "AXStandardWindow"))
        XCTAssertTrue(AXClient.isRestorableWindow(role: "AXWindow", subrole: "AXFloatingWindow"))
        XCTAssertTrue(AXClient.isRestorableWindow(role: "AXWindow", subrole: "AXDialog"))
    }

    func test_otherSubroles_areNotRestorable() {
        for subrole in ["AXUnknown", "AXSystemDialog", "AXSystemFloatingWindow", ""] {
            XCTAssertFalse(AXClient.isRestorableWindow(role: "AXWindow", subrole: subrole), subrole)
        }
    }

    /// Only processes owning a window are asked for windows. Five WebKit
    /// web-content helpers owning none took the 1s AX timeout each.
    func test_onlyWindowOwningProcessesAreWalked() {
        let owners: Set<pid_t> = [100, 200]
        XCTAssertTrue(AXClient.ownsAWindow(pid: 100, windowOwners: owners))
        XCTAssertFalse(AXClient.ownsAWindow(pid: 36481, windowOwners: owners))
    }

    /// No owner list means CoreGraphics gave no answer; skipping everything
    /// would capture nothing, so everything is walked.
    func test_emptyOwnerList_walksEveryProcess() {
        XCTAssertTrue(AXClient.ownsAWindow(pid: 36481, windowOwners: []))
    }

    func test_missingRoleOrSubrole_isNotRestorable() {
        XCTAssertFalse(AXClient.isRestorableWindow(role: "AXWindow", subrole: nil))
        XCTAssertFalse(AXClient.isRestorableWindow(role: nil, subrole: "AXStandardWindow"))
        XCTAssertFalse(AXClient.isRestorableWindow(role: "AXSheet", subrole: "AXStandardWindow"))
    }
}
