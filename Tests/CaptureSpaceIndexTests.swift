import XCTest
import CoreGraphics
@testable import PixlPutCore

/// Which Space a capture is filed under.
///
/// With storage keyed per Space, getting this wrong does not merely mislabel the
/// capture — it overwrites a *different* Space's config. Measured 2026-08-12: a
/// Capture Now during a Space-switch transition read the outgoing Space's index
/// from `CGSGetActiveSpace` while AX had already moved to the incoming Space's
/// windows, so Desktop 1's 17 windows landed in Space 1's file and rotated
/// Space 2's real config out of slot 0.
///
/// The fix is to take the index from the captured windows themselves. These
/// tests cover that decision as a pure function.
final class CaptureSpaceIndexTests: XCTestCase {

    /// Convenience: resolve from a fixed windowID → spaceIndex table.
    private func resolver(_ table: [CGWindowID: Int]) -> (CGWindowID) -> Int? {
        { table[$0] }
    }

    func test_modalSpaceIndex_whenAllWindowsAgree_returnsThatSpace() {
        let index = SnapshotEngine.modalSpaceIndex(
            of: [10, 11, 12],
            resolve: resolver([10: 4, 11: 4, 12: 4])
        )
        XCTAssertEqual(index, 4)
    }

    func test_modalSpaceIndex_oneStragglerDoesNotOutvoteTheMajority() {
        let index = SnapshotEngine.modalSpaceIndex(
            of: [101, 102, 103, 104],
            resolve: resolver([101: 0, 102: 0, 103: 0, 104: 1])
        )
        XCTAssertEqual(index, 0)
    }

    /// The second regression, and the reason the resolver passed to this
    /// function must reject multi-Space windows.
    ///
    /// Sticky "all Desktops" windows report every Space. Taking the first of
    /// that list yields the lowest Space ID, so every sticky window votes for
    /// Space 0. In a capture holding only 4–6 windows they became the majority
    /// and three separate Desktops were filed as Space 0 (2026-08-12). A
    /// resolver that returns nil for them leaves the real Space winning.
    func test_modalSpaceIndex_stickyWindowsExcludedByResolver_realSpaceStillWins() {
        // 4 sticky windows (nil = not entitled to vote) and 2 real ones on 4.
        let sticky: Set<CGWindowID> = [1, 2, 3, 4]
        let index = SnapshotEngine.modalSpaceIndex(
            of: [1, 2, 3, 4, 5, 6],
            resolve: { sticky.contains($0) ? nil : 4 }
        )
        XCTAssertEqual(index, 4, "sticky windows must not outvote the Space being captured")
    }

    /// If sticky windows were allowed to vote they WOULD win — this pins why the
    /// filtering lives in the resolver rather than being optional.
    func test_modalSpaceIndex_ifStickyWindowsVoted_theyWouldWin_soTheyMustNot() {
        let index = SnapshotEngine.modalSpaceIndex(
            of: [1, 2, 3, 4, 5, 6],
            resolve: { id in id <= 4 ? 0 : 4 }   // sticky windows reporting Space 0 first
        )
        XCTAssertEqual(index, 0, "documents the failure mode the resolver must prevent")
    }

    func test_modalSpaceIndex_whenNoWindowResolves_returnsNilSoCallerFallsBack() {
        XCTAssertNil(SnapshotEngine.modalSpaceIndex(of: [1, 2, 3], resolve: { _ in nil }))
        XCTAssertNil(SnapshotEngine.modalSpaceIndex(of: [], resolve: { _ in 3 }))
    }

    func test_modalSpaceIndex_ignoresUnresolvableWindows() {
        // Sticky all-Spaces surfaces and windows mid-teardown report no Space;
        // they must not drag the answer or suppress a clear majority.
        let index = SnapshotEngine.modalSpaceIndex(
            of: [1, 2, 3, 4, 5],
            resolve: { id in id <= 2 ? 5 : nil }
        )
        XCTAssertEqual(index, 5)
    }

    func test_modalSpaceIndex_tieBreaksLowAndIsDeterministic() {
        let ids: [CGWindowID] = [1, 2, 3, 4]
        let table: [CGWindowID: Int] = [1: 3, 2: 3, 3: 1, 4: 1]
        let first = SnapshotEngine.modalSpaceIndex(of: ids, resolve: resolver(table))
        XCTAssertEqual(first, 1, "tie resolves to the lowest index")
        for _ in 0..<50 {
            XCTAssertEqual(SnapshotEngine.modalSpaceIndex(of: ids, resolve: resolver(table)), first)
        }
    }
}
