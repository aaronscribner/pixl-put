import XCTest
@testable import PixlPutCore

/// The rules that pair one app's windows when neither the window ID nor
/// identity could — and that refuse to pair on list position alone.
final class FallbackMatcherTests: XCTestCase {

    private func orderOnly(_ title: String?) -> FallbackMatcher.Candidate {
        FallbackMatcher.Candidate(title: title, isOrderOnly: true)
    }

    func test_uniqueTitles_pairEvenWhenListOrderDiffers() {
        let pairs = FallbackMatcher.pair(
            saved: [orderOnly("Inbox"), orderOnly("Calendar"), orderOnly("Docs")],
            live: [orderOnly("Docs"), orderOnly("Inbox"), orderOnly("Calendar")]
        )
        XCTAssertEqual(pairs, [
            .init(saved: 0, live: 1, reason: .uniqueTitle),
            .init(saved: 1, live: 2, reason: .uniqueTitle),
            .init(saved: 2, live: 0, reason: .uniqueTitle),
        ])
    }

    func test_titleSharedByTwoWindows_pairsNeither() {
        let pairs = FallbackMatcher.pair(
            saved: [orderOnly("New Tab"), orderOnly("New Tab")],
            live: [orderOnly("New Tab"), orderOnly("New Tab")]
        )
        XCTAssertTrue(pairs.isEmpty, "two identical titles can't say which window is which")
    }

    func test_soleOrderOnlyWindow_pairsWithoutATitle() {
        let pairs = FallbackMatcher.pair(saved: [orderOnly(nil)], live: [orderOnly("Chat | Microsoft Teams")])
        XCTAssertEqual(pairs, [.init(saved: 0, live: 0, reason: .soleWindow)])
    }

    func test_soleLeftoverAfterTitles_pairs() {
        // Three Firefox windows; two kept their titles, one navigated.
        let pairs = FallbackMatcher.pair(
            saved: [orderOnly("A"), orderOnly("B"), orderOnly("C")],
            live: [orderOnly("B"), orderOnly("C2"), orderOnly("A")]
        )
        XCTAssertEqual(pairs.count, 3)
        XCTAssertEqual(pairs.first { $0.saved == 2 }, .init(saved: 2, live: 1, reason: .soleWindow))
    }

    func test_severalUntitledWindows_neverPairOnOrder() {
        let pairs = FallbackMatcher.pair(saved: [orderOnly(nil), orderOnly(nil)],
                                         live: [orderOnly(nil), orderOnly(nil)])
        XCTAssertTrue(pairs.isEmpty)
    }

    func test_unequalLeftovers_pairOnlyByTitle() {
        let pairs = FallbackMatcher.pair(
            saved: [orderOnly("A"), orderOnly("B")],
            live: [orderOnly("A"), orderOnly("X"), orderOnly("Y")]
        )
        XCTAssertEqual(pairs, [.init(saved: 0, live: 0, reason: .uniqueTitle)])
    }

    /// A window with a real identity that failed to match is evidence of a
    /// different window, so it is never paired just for being left over.
    func test_strongIdentityLeftover_isNotPairedAsSoleWindow() {
        let pairs = FallbackMatcher.pair(
            saved: [FallbackMatcher.Candidate(title: "Old tab", isOrderOnly: false)],
            live: [orderOnly("New tab")]
        )
        XCTAssertTrue(pairs.isEmpty)
    }

    func test_emptyTitlesAreIgnored() {
        let pairs = FallbackMatcher.pair(saved: [orderOnly(""), orderOnly("")],
                                         live: [orderOnly(""), orderOnly("")])
        XCTAssertTrue(pairs.isEmpty)
    }
}
