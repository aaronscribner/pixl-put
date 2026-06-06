import XCTest
import CoreGraphics
@testable import PixlPutCore

/// Tests for the additive cross-capture merge and the stable cross-Space
/// ordinal derivation. The bug these guard against: cross-Space CG windows
/// used to draw `ordinalInApp` from a running counter seeded by the
/// active-Space AX window count, so the SAME off-Space window got a
/// DIFFERENT ordinal every time the active Space changed. That defeated the
/// merge dedupe key (`spaceIndex|bundleID|identity|ordinalInApp`) and grew
/// the snapshot ~33 windows per Space-switch — observed as 1000+ entry
/// snapshots (8x duplication) in the wild.
///
/// Fix B: derive the cross-Space ordinal from the CG window number, which is
/// constant for a window's lifetime, so the key is stable across captures.
final class SnapshotMergerTests: XCTestCase {

    // MARK: - Helpers

    private func entry(
        bundle: String,
        identity: WindowIdentity,
        ordinal: Int,
        space: Int,
        frame: CGRectCodable = CGRectCodable(x: 0, y: 0, width: 800, height: 600)
    ) -> WindowEntry {
        WindowEntry(
            bundleID: bundle,
            identity: identity,
            ordinalInApp: ordinal,
            displayFingerprintID: "display-A",
            spaceIndex: space,
            frame: frame,
            isMinimized: false,
            isFullscreen: false,
            capturedAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// Build a cross-Space entry the way `capture()` does: ordinal derived
    /// from the CG window number, identity falling back to `.ordinal`.
    private func crossEntry(bundle: String, windowID: CGWindowID, space: Int) -> WindowEntry {
        let ord = SnapshotMerger.crossSpaceOrdinal(forWindowID: windowID)
        return entry(bundle: bundle, identity: .ordinal(ord), ordinal: ord, space: space)
    }

    // MARK: - Ordinal stability

    func testCrossSpaceOrdinalDependsOnlyOnWindowID() {
        // Same window number → same ordinal, regardless of when captured.
        XCTAssertEqual(
            SnapshotMerger.crossSpaceOrdinal(forWindowID: 800),
            SnapshotMerger.crossSpaceOrdinal(forWindowID: 800)
        )
        // Different window → different ordinal (no collision).
        XCTAssertNotEqual(
            SnapshotMerger.crossSpaceOrdinal(forWindowID: 800),
            SnapshotMerger.crossSpaceOrdinal(forWindowID: 801)
        )
        // It IS the window number — pins the derivation so a regression to a
        // count-based running counter fails here.
        XCTAssertEqual(SnapshotMerger.crossSpaceOrdinal(forWindowID: 12345), 12345)
    }

    // MARK: - Merge dedupe

    func testMergeRetainsOtherSpaceEntriesNotInCurrent() {
        let current = [entry(bundle: "com.a", identity: .ordinal(0), ordinal: 0, space: 0)]
        let previous = [
            entry(bundle: "com.a", identity: .ordinal(0), ordinal: 0, space: 0), // active — replaced
            crossEntry(bundle: "com.safari", windowID: 800, space: 2),           // other Space — kept
        ]
        let merged = SnapshotMerger.merge(
            current: current, previous: previous, activeSpaceIndex: 0
        ).entries
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.filter { $0.bundleID == "com.safari" }.count, 1)
    }

    /// The core regression test. The active Space changes between captures,
    /// so the active-Space window count changes — but the same off-Space
    /// Safari/Mail windows persist. With stable (window-number) ordinals the
    /// merge recognises them as the same windows and does NOT duplicate them.
    func testActiveSpaceCountChangeDoesNotDuplicateCrossSpaceWindows() {
        // PREV: captured while Space 1 was active and held two windows.
        let previous = [
            entry(bundle: "com.a", identity: .ordinal(0), ordinal: 0, space: 1),
            entry(bundle: "com.b", identity: .ordinal(0), ordinal: 0, space: 1),
            crossEntry(bundle: "com.safari", windowID: 800, space: 2),
            crossEntry(bundle: "com.mail", windowID: 900, space: 3),
        ]
        // CURRENT: Space 0 now active with a single, different window. The CG
        // pass re-sees the same off-Space Safari/Mail windows (same window
        // numbers) and assigns the same ordinals.
        let current = [
            entry(bundle: "com.c", identity: .ordinal(0), ordinal: 0, space: 0),
            crossEntry(bundle: "com.safari", windowID: 800, space: 2),
            crossEntry(bundle: "com.mail", windowID: 900, space: 3),
        ]
        let merged = SnapshotMerger.merge(
            current: current, previous: previous, activeSpaceIndex: 0
        ).entries

        XCTAssertEqual(merged.filter { $0.bundleID == "com.safari" }.count, 1,
                       "off-Space Safari window must not be duplicated by the merge")
        XCTAssertEqual(merged.filter { $0.bundleID == "com.mail" }.count, 1,
                       "off-Space Mail window must not be duplicated by the merge")
        // No duplicate merge keys anywhere.
        let keys = merged.map(SnapshotMerger.mergeDedupeKey)
        XCTAssertEqual(keys.count, Set(keys).count, "merged snapshot has duplicate window keys")
    }

    /// Capturing the identical layout repeatedly must not grow the snapshot.
    func testRepeatedIdenticalCapturesDoNotGrow() {
        let active = entry(bundle: "com.a", identity: .ordinal(0), ordinal: 0, space: 0)
        let cross = [
            crossEntry(bundle: "com.safari", windowID: 800, space: 2),
            crossEntry(bundle: "com.mail", windowID: 900, space: 3),
        ]
        let capture = [active] + cross

        var snapshot = SnapshotMerger.merge(
            current: capture, previous: nil, activeSpaceIndex: 0
        ).entries
        let baseline = snapshot.count

        for _ in 0..<10 {
            snapshot = SnapshotMerger.merge(
                current: capture, previous: snapshot, activeSpaceIndex: 0
            ).entries
        }
        XCTAssertEqual(snapshot.count, baseline,
                       "repeated identical captures must not accumulate duplicate entries")
    }

    /// Legacy duplicates already present in a previous snapshot collapse to a
    /// single retained entry rather than being preserved.
    func testLegacyDuplicatesInPreviousCollapse() {
        let dup = crossEntry(bundle: "com.safari", windowID: 800, space: 2)
        let previous = [dup, dup, dup] // a corrupted prior snapshot
        let current = [entry(bundle: "com.a", identity: .ordinal(0), ordinal: 0, space: 0)]
        let merged = SnapshotMerger.merge(
            current: current, previous: previous, activeSpaceIndex: 0
        ).entries
        XCTAssertEqual(merged.filter { $0.bundleID == "com.safari" }.count, 1)
    }
}
