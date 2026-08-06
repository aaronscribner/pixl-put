import XCTest
import CoreGraphics
@testable import PixlPutCore

/// Tests for windowID-joined identity enrichment (`SnapshotMerger.enrich`)
/// and the stable cross-Space ordinal derivation.
///
/// History this design carries: the old ADDITIVE merge retained previous
/// entries for unvisited Spaces and needed a dedupe key to avoid unbounded
/// growth (observed: 1000+ entry snapshots, 8x duplication, within an hour).
/// The all-Spaces CG pass made every capture complete, so `enrich` replaces
/// the snapshot wholesale — output is exactly the current capture, and the
/// only thing carried forward is identity, joined by CG window number.
final class SnapshotMergerTests: XCTestCase {

    // MARK: - Helpers

    private func entry(
        bundle: String,
        identity: WindowIdentity,
        ordinal: Int,
        space: Int,
        frame: CGRectCodable = CGRectCodable(x: 0, y: 0, width: 800, height: 600),
        isFullscreen: Bool = false,
        windowID: CGWindowID? = nil
    ) -> WindowEntry {
        WindowEntry(
            bundleID: bundle,
            identity: identity,
            ordinalInApp: ordinal,
            displayFingerprintID: "display-A",
            spaceIndex: space,
            frame: frame,
            isMinimized: false,
            isFullscreen: isFullscreen,
            capturedAt: Date(timeIntervalSince1970: 0),
            windowID: windowID
        )
    }

    /// Build a cross-Space entry the way `capture()` does: weak ordinal
    /// identity derived from the stable CG window number.
    private func cgEntry(bundle: String, windowID: CGWindowID, space: Int,
                         frame: CGRectCodable = CGRectCodable(x: 0, y: 0, width: 800, height: 600)) -> WindowEntry {
        entry(bundle: bundle,
              identity: .ordinal(SnapshotMerger.crossSpaceOrdinal(forWindowID: windowID)),
              ordinal: SnapshotMerger.crossSpaceOrdinal(forWindowID: windowID),
              space: space,
              frame: frame,
              windowID: windowID)
    }

    private let braveTabs = WindowIdentity.browserTabSet([URL(string: "https://a.example")!])

    // MARK: - Wholesale replace

    func test_output_isExactlyTheCurrentCapture_neverRetainsPreviousEntries() {
        // Previous snapshot has a window on Space 5 that no longer exists.
        let previous = [entry(bundle: "com.gone.app", identity: braveTabs, ordinal: 0, space: 5, windowID: 900)]
        let current = [cgEntry(bundle: "com.brave.Browser", windowID: 101, space: 3)]

        let (merged, _) = SnapshotMerger.enrich(current: current, previous: previous)

        XCTAssertEqual(merged.count, 1, "closed windows must not survive a capture")
        XCTAssertEqual(merged.first?.bundleID, "com.brave.Browser")
    }

    func test_repeatedCaptures_neverGrowTheSnapshot() {
        // The regression the old merge existed to suppress: N captures of the
        // same scene must produce N-invariant output.
        var snapshot = [cgEntry(bundle: "com.brave.Browser", windowID: 101, space: 3),
                        cgEntry(bundle: "com.brave.Browser", windowID: 102, space: 7)]
        for _ in 0..<10 {
            let current = [cgEntry(bundle: "com.brave.Browser", windowID: 101, space: 3),
                           cgEntry(bundle: "com.brave.Browser", windowID: 102, space: 7)]
            (snapshot, _) = SnapshotMerger.enrich(current: current, previous: snapshot)
        }
        XCTAssertEqual(snapshot.count, 2)
    }

    // MARK: - Identity enrichment

    func test_weakCGEntry_inheritsStrongIdentityFromPreviousCapture_byWindowID() {
        // Yesterday: Brave window 101 captured on its active Space with tabs.
        let previous = [entry(bundle: "com.brave.Browser", identity: braveTabs,
                              ordinal: 2, space: 3, isFullscreen: true, windowID: 101)]
        // Today: same window seen only via CG from another Space — weak.
        let current = [cgEntry(bundle: "com.brave.Browser", windowID: 101, space: 3,
                               frame: CGRectCodable(x: 50, y: 60, width: 1200, height: 900))]

        let (merged, stats) = SnapshotMerger.enrich(current: current, previous: previous)

        let enriched = merged[0]
        XCTAssertEqual(enriched.identity, braveTabs, "identity transfers")
        XCTAssertEqual(enriched.ordinalInApp, 2, "AX ordinal transfers with the identity")
        XCTAssertTrue(enriched.isFullscreen, "fullscreen state only AX knew transfers")
        XCTAssertEqual(enriched.frame.x, 50, "frame stays CURRENT — CG just measured it")
        XCTAssertEqual(stats, SnapshotMerger.Stats(identityUpgraded: 1, leftWeak: 0))
    }

    func test_strongCurrentEntry_isNeverOverwrittenByPrevious() {
        let newTabs = WindowIdentity.browserTabSet([URL(string: "https://new.example")!])
        let previous = [entry(bundle: "com.brave.Browser", identity: braveTabs, ordinal: 0, space: 3, windowID: 101)]
        let current = [entry(bundle: "com.brave.Browser", identity: newTabs, ordinal: 0, space: 3, windowID: 101)]

        let (merged, stats) = SnapshotMerger.enrich(current: current, previous: previous)

        XCTAssertEqual(merged[0].identity, newTabs, "fresh AX identity always wins")
        XCTAssertEqual(stats.identityUpgraded, 0)
    }

    func test_windowIDReuseAcrossApps_doesNotTransferIdentity() {
        // App quit; a NEW app's window drew the same CG window number. The
        // bundle check must block the stale identity from crossing apps.
        let previous = [entry(bundle: "com.brave.Browser", identity: braveTabs, ordinal: 0, space: 3, windowID: 101)]
        let current = [cgEntry(bundle: "com.microsoft.VSCode", windowID: 101, space: 3)]

        let (merged, stats) = SnapshotMerger.enrich(current: current, previous: previous)

        XCTAssertEqual(merged[0].identity, .ordinal(SnapshotMerger.crossSpaceOrdinal(forWindowID: 101)))
        XCTAssertEqual(stats, SnapshotMerger.Stats(identityUpgraded: 0, leftWeak: 1))
    }

    func test_weakPreviousIdentity_hasNothingToDonate() {
        // Previous entry was itself a weak CG capture — inheriting it would
        // just launder an ordinal into looking authoritative.
        let previous = [cgEntry(bundle: "com.brave.Browser", windowID: 101, space: 3)]
        let current = [cgEntry(bundle: "com.brave.Browser", windowID: 101, space: 7)]

        let (merged, stats) = SnapshotMerger.enrich(current: current, previous: previous)

        XCTAssertEqual(merged[0].spaceIndex, 7)
        XCTAssertEqual(stats, SnapshotMerger.Stats(identityUpgraded: 0, leftWeak: 1))
    }

    func test_noPreviousSnapshot_passesCurrentThroughAndCountsWeak() {
        let current = [cgEntry(bundle: "com.brave.Browser", windowID: 101, space: 3),
                       entry(bundle: "com.apple.TextEdit", identity: .documentPath(URL(string: "file:///a.rtf")!),
                             ordinal: 0, space: 0, windowID: 55)]
        let (merged, stats) = SnapshotMerger.enrich(current: current, previous: nil)
        XCTAssertEqual(merged, current)
        XCTAssertEqual(stats, SnapshotMerger.Stats(identityUpgraded: 0, leftWeak: 1))
    }

    func test_entryWithoutWindowID_staysWeakWithoutCrashing() {
        let previous = [entry(bundle: "com.brave.Browser", identity: braveTabs, ordinal: 0, space: 3, windowID: 101)]
        let current = [entry(bundle: "com.brave.Browser", identity: .ordinal(0), ordinal: 0, space: 3, windowID: nil)]

        let (merged, stats) = SnapshotMerger.enrich(current: current, previous: previous)

        XCTAssertEqual(merged[0].identity, .ordinal(0))
        XCTAssertEqual(stats.leftWeak, 1)
    }

    // MARK: - Stable ordinal

    func test_crossSpaceOrdinal_isDerivedFromWindowID_soItIsCaptureInvariant() {
        // The 1000+-entry regression: ordinals must not depend on anything
        // that changes between captures (like the AX window count did).
        XCTAssertEqual(SnapshotMerger.crossSpaceOrdinal(forWindowID: 12153),
                       SnapshotMerger.crossSpaceOrdinal(forWindowID: 12153))
        XCTAssertNotEqual(SnapshotMerger.crossSpaceOrdinal(forWindowID: 12153),
                          SnapshotMerger.crossSpaceOrdinal(forWindowID: 12154))
    }
}
