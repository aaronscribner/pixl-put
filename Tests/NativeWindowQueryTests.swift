import XCTest
import CoreGraphics
@testable import PixlPutCore

/// The pure half of PixPut's native every-Space window query: Space IDs in,
/// yabai-shaped rows out. No window server involved.
final class NativeWindowQueryTests: XCTestCase {

    private func descriptor(
        _ id: CGWindowID,
        pid: pid_t = 100,
        bundle: String = "com.example.app",
        title: String = "",
        bounds: CGRectCodable = CGRectCodable(x: 0, y: 0, width: 800, height: 600),
        onScreen: Bool = true
    ) -> CGWindowDescriptor {
        CGWindowDescriptor(
            windowID: id, ownerPID: pid, bundleID: bundle,
            title: title, bounds: bounds, isOnScreen: onScreen
        )
    }

    /// Position in the ordered Space list, plus one, is the index yabai
    /// reported — and the index `pixputSpaceIndex` subtracts back off.
    func test_spaceIndex_isOneBasedPositionInOrderedList() {
        let out = NativeWindowQuery.build(
            descriptors: [descriptor(1), descriptor(2), descriptor(3)],
            spaceIDsByWindow: [1: [30], 2: [40], 3: [90]],
            orderedSpaceIDs: [30, 40, 90]
        )

        XCTAssertEqual(out.map(\.id), [1, 2, 3])
        XCTAssertEqual(out.map(\.space), [1, 2, 3])
        XCTAssertEqual(out.map(\.pixputSpaceIndex), [0, 1, 2])
    }

    /// Space IDs are not contiguous and do not start at 1 — on the measured
    /// host they were 3...9 — so the mapping must go through the ordered
    /// list rather than arithmetic on the raw ID.
    func test_nonContiguousSpaceIDs_mapByPositionNotValue() {
        let out = NativeWindowQuery.build(
            descriptors: [descriptor(7)],
            spaceIDsByWindow: [7: [8]],
            orderedSpaceIDs: [3, 4, 5, 6, 7, 8, 9]
        )

        XCTAssertEqual(out.first?.space, 6)
        XCTAssertEqual(out.first?.pixputSpaceIndex, 5)
    }

    /// A window on every Space follows the user; it is not a placement to
    /// restore. It is emitted flagged rather than dropped, so a caller can
    /// still see it.
    func test_windowOnManySpaces_isFlaggedStickyAndNotAPlacement() {
        let out = NativeWindowQuery.build(
            descriptors: [descriptor(1)],
            spaceIDsByWindow: [1: [30, 40, 50]],
            orderedSpaceIDs: [30, 40, 50]
        )

        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.isSticky, true)
        XCTAssertFalse(out.first?.isStandardPlacement ?? true)
    }

    /// No Space, or a Space outside the managed set (full screen, Exposé),
    /// is not restorable and must not invent an index.
    func test_windowWithNoSpaceOrUnmanagedSpace_isOmitted() {
        let out = NativeWindowQuery.build(
            descriptors: [descriptor(1), descriptor(2), descriptor(3)],
            spaceIDsByWindow: [1: [], 2: [999], 3: [40]],
            orderedSpaceIDs: [30, 40]
        )

        XCTAssertEqual(out.map(\.id), [3])
    }

    /// CoreGraphics reports a title only with Screen Recording consent, which
    /// PixPut does not ask for. A richer source wins where it has one.
    func test_titleOverride_winsOverCoreGraphicsTitle() {
        let out = NativeWindowQuery.build(
            descriptors: [descriptor(1, title: ""), descriptor(2, title: "from CG")],
            spaceIDsByWindow: [1: [30], 2: [30]],
            orderedSpaceIDs: [30],
            titlesByWindowID: [1: "from AX"]
        )

        XCTAssertEqual(out.first(where: { $0.id == 1 })?.title, "from AX")
        XCTAssertEqual(out.first(where: { $0.id == 2 })?.title, "from CG")
    }

    /// Two runs over an unchanged desktop must produce an identical plan, so
    /// the order cannot depend on dictionary iteration.
    func test_outputIsOrderedBySpaceThenWindowID() {
        let descriptors = [descriptor(9), descriptor(2), descriptor(5), descriptor(1)]
        let spaces: [CGWindowID: [UInt64]] = [9: [40], 2: [40], 5: [30], 1: [30]]

        let first = NativeWindowQuery.build(
            descriptors: descriptors, spaceIDsByWindow: spaces, orderedSpaceIDs: [30, 40]
        )
        let second = NativeWindowQuery.build(
            descriptors: descriptors.reversed(), spaceIDsByWindow: spaces, orderedSpaceIDs: [30, 40]
        )

        XCTAssertEqual(first.map(\.id), [1, 5, 2, 9])
        XCTAssertEqual(first, second)
    }

    /// The app name is for diagnostics; without one the bundle ID is a more
    /// useful fallback than an empty string.
    func test_appName_fallsBackToBundleID() {
        let out = NativeWindowQuery.build(
            descriptors: [descriptor(1, pid: 42, bundle: "co.cerebraljuice.pixlput")],
            spaceIDsByWindow: [1: [30]],
            orderedSpaceIDs: [30]
        )

        XCTAssertEqual(out.first?.app, "co.cerebraljuice.pixlput")
    }

    /// The whole point of the native query: rows it produces feed the same
    /// cross-Space index that the yabai query used to.
    func test_outputFeedsCrossSpaceWindowIndex() {
        let rows = NativeWindowQuery.build(
            descriptors: [
                descriptor(1, pid: 42, bundle: "com.apple.Stickies",
                           bounds: CGRectCodable(x: 10, y: 20, width: 400, height: 300)),
                descriptor(2, pid: 42, bundle: "com.apple.Stickies",
                           bounds: CGRectCodable(x: 50, y: 60, width: 400, height: 300)),
            ],
            spaceIDsByWindow: [1: [30], 2: [40]],
            orderedSpaceIDs: [30, 40]
        )

        let index = CrossSpaceWindowIndex.build(
            yabaiWindows: rows,
            bundleIDByPID: [42: "com.apple.Stickies"],
            displayBoundsByID: [:]
        )

        XCTAssertEqual(index.count, 2)
        XCTAssertEqual(Set(index.map(\.spaceIndex)), [0, 1])
    }
}
