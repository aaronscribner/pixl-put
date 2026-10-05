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

    /// Each window's Spaces come from its own lookup. The bulk form credited
    /// every Space to the first window and dropped the rest (1 of 170 kept).
    func test_spaceMap_looksUpEachWindowSeparately() {
        var asked: [CGWindowID] = []
        let table: [CGWindowID: [UInt64]] = [10: [30], 11: [40], 12: []]

        let map = NativeWindowQuery.spaceMap(for: [10, 11, 12]) { id in
            asked.append(id)
            return table[id] ?? []
        }

        XCTAssertEqual(asked, [10, 11, 12])
        XCTAssertEqual(map, table)

        let rows = NativeWindowQuery.build(
            descriptors: [descriptor(10), descriptor(11), descriptor(12)],
            spaceIDsByWindow: map,
            orderedSpaceIDs: [30, 40]
        )
        XCTAssertEqual(rows.map(\.id), [10, 11], "a window on no Space is the only one omitted")
        XCTAssertEqual(rows.map(\.isSticky), [false, false])
    }

    /// A native list covering under half of yabai's tracked windows is broken;
    /// the restore plans from yabai instead of reporting nothing to move.
    func test_nativeCoversTracked() {
        XCTAssertFalse(NativeWindowQuery.nativeCoversTracked(kept: 0, trackedCount: 64), "the measured failure")
        XCTAssertFalse(NativeWindowQuery.nativeCoversTracked(kept: 31, trackedCount: 64))
        XCTAssertTrue(NativeWindowQuery.nativeCoversTracked(kept: 32, trackedCount: 64))
        XCTAssertTrue(NativeWindowQuery.nativeCoversTracked(kept: 63, trackedCount: 64))
    }

    func test_nativeCoversTracked_withoutYabai_usesAnyNonEmptyList() {
        XCTAssertTrue(NativeWindowQuery.nativeCoversTracked(kept: 5, trackedCount: nil))
        XCTAssertFalse(NativeWindowQuery.nativeCoversTracked(kept: 0, trackedCount: nil))
        XCTAssertTrue(NativeWindowQuery.nativeCoversTracked(kept: 5, trackedCount: 0))
    }

    /// CoreGraphics withholds titles without Screen Recording — 0 of 13 VS Code
    /// windows on the measured host — and on a Space AX cannot see, every
    /// identity is built from a title. With yabai's title a VS Code window
    /// there resolves to its workspace, exactly as capture recorded it.
    func test_yabaiTitles_identifyVSCodeWindowOnAnotherSpace() throws {
        let tracked = try YabaiJSON.windows(from: Data("""
        [{"id":613,"pid":900,"app":"Code","title":"classes.puml — Societal (Workspace)",
          "frame":{"x":0,"y":25,"w":1900,"h":1100},"role":"AXWindow","subrole":"AXStandardWindow","space":2},
         {"id":614,"pid":900,"app":"Code","title":"",
          "frame":{"x":0,"y":25,"w":1900,"h":1100},"role":"AXWindow","subrole":"AXStandardWindow","space":2}]
        """.utf8))

        let titles = NativeWindowQuery.titles(from: tracked)
        XCTAssertEqual(titles, [613: "classes.puml — Societal (Workspace)"], "empty titles are left out")

        let rows = NativeWindowQuery.build(
            descriptors: [descriptor(613, pid: 900, bundle: "com.microsoft.VSCode", title: "", onScreen: false)],
            spaceIDsByWindow: [613: [40]],
            orderedSpaceIDs: [30, 40],
            titlesByWindowID: titles
        )
        let index = CrossSpaceWindowIndex.build(
            yabaiWindows: rows, bundleIDByPID: [900: "com.microsoft.VSCode"], displayBoundsByID: [:]
        )

        XCTAssertEqual(index.first?.live.identity,
                       .titleRegex(pattern: "editor.workspace", capturedValue: "Societal"))
    }

    func test_titles_withoutYabai_isEmpty() {
        XCTAssertEqual(NativeWindowQuery.titles(from: nil), [:])
    }

    /// CoreGraphics lists off-screen placeholders and popups beside real
    /// windows — 13 beside 63 on the measured host — and yabai tracks none.
    func test_restricted_dropsWindowsYabaiDoesNotTrack() {
        let rows = NativeWindowQuery.build(
            descriptors: [
                descriptor(169),
                descriptor(179, bounds: CGRectCodable(x: 0, y: 0, width: 320, height: 136)),
                descriptor(180, bounds: CGRectCodable(x: 0, y: 0, width: 500, height: 500)),
            ],
            spaceIDsByWindow: [169: [30], 179: [30], 180: [30]],
            orderedSpaceIDs: [30]
        )

        let result = NativeWindowQuery.restricted(rows, toTrackedIDs: [169])

        XCTAssertEqual(result.kept.map(\.id), [169])
        XCTAssertEqual(result.dropped, 2)
    }

    /// A yabai that did not answer, or answered with nothing, must not empty
    /// the plan.
    func test_restricted_keepsEverythingWithoutATrackedSet() {
        let rows = NativeWindowQuery.build(
            descriptors: [descriptor(1), descriptor(2)],
            spaceIDsByWindow: [1: [30], 2: [30]],
            orderedSpaceIDs: [30]
        )

        XCTAssertEqual(NativeWindowQuery.restricted(rows, toTrackedIDs: nil).kept, rows)
        XCTAssertEqual(NativeWindowQuery.restricted(rows, toTrackedIDs: []).kept, rows)
    }

    /// The harm a placeholder does: it ranks by window id among its app's
    /// windows, so a real window created after it lost its ordinal.
    func test_placeholder_doesNotShiftRealWindowOrdinal() {
        let rows = NativeWindowQuery.build(
            descriptors: [
                descriptor(10, pid: 42, bundle: "com.apple.TextEdit"),
                descriptor(11, pid: 42, bundle: "com.apple.TextEdit",
                           bounds: CGRectCodable(x: 0, y: 0, width: 500, height: 500), onScreen: false),
                descriptor(12, pid: 42, bundle: "com.apple.TextEdit"),
            ],
            spaceIDsByWindow: [10: [30], 11: [30], 12: [30]],
            orderedSpaceIDs: [30]
        )
        let kept = NativeWindowQuery.restricted(rows, toTrackedIDs: [10, 12]).kept

        let index = CrossSpaceWindowIndex.build(
            yabaiWindows: kept, bundleIDByPID: [42: "com.apple.TextEdit"], displayBoundsByID: [:]
        )

        XCTAssertEqual(index.first { $0.live.windowID == 12 }?.live.ordinalInApp, 1)
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
