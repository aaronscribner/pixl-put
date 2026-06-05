import Foundation
import CoreGraphics

/// Pure, testable merge logic for `SnapshotEngine.capture()`.
///
/// `capture()` produces entries for the active Space (via AX) plus entries
/// for OTHER Spaces (via the cross-Space CG pass). To avoid wiping the
/// other-Space layout every time the user captures on a single Space, the
/// engine performs an ADDITIVE MERGE: the current capture's entries win, and
/// the previous snapshot's entries for Spaces NOT touched by this capture are
/// retained.
///
/// The merge identity of a window is `mergeDedupeKey`. It MUST be stable for
/// the same physical window across consecutive captures, otherwise the same
/// off-Space window is retained again and again and the snapshot grows
/// without bound (observed in the wild as 1000+ entry snapshots — ~8x
/// duplication — within an hour of normal use).
enum SnapshotMerger {

    /// Stable per-window ordinal for cross-Space CG windows.
    ///
    /// The CG window number (`kCGWindowNumber`) is constant for a window's
    /// lifetime, so deriving the ordinal from it keeps `mergeDedupeKey`
    /// stable across captures even as the active Space's AX window count
    /// changes.
    ///
    /// The previous implementation seeded a running per-bundle counter from
    /// the active-Space AX window count (`max(AX ordinal) + 1`). That count
    /// changes every time the user switches to a Space with a different
    /// number of windows, so the SAME off-Space window drew a DIFFERENT
    /// ordinal each capture — defeating the dedupe key and growing the
    /// snapshot ~33 windows per Space-switch.
    static func crossSpaceOrdinal(forWindowID windowID: CGWindowID) -> Int {
        Int(windowID)
    }

    /// Dedupe key for the additive cross-capture merge. Identifies a
    /// "logical window" independent of frame (so window movement between
    /// captures doesn't break dedupe). Per-Space scoped so a window
    /// legitimately existing on two Spaces (e.g. a notification widget) is
    /// not collapsed.
    static func mergeDedupeKey(_ entry: WindowEntry) -> String {
        "\(entry.spaceIndex)|\(entry.bundleID)|\(entry.identity)|\(entry.ordinalInApp)"
    }

    /// Outcome counters for diagnostics.
    struct Stats: Equatable {
        /// Entries retained from the previous snapshot's other Spaces.
        var keptFromOtherSpaces: Int = 0
        /// Previous entries dropped because the current capture already
        /// covers them (fresh data wins).
        var droppedToCurrent: Int = 0
        /// Previous entries dropped as legacy duplicates of an earlier
        /// previous entry (collapses corruption from older snapshots).
        var droppedAsLegacyDuplicate: Int = 0
        /// Current entries that replaced the previous active-Space layout.
        var replacedActiveSpace: Int = 0
    }

    /// Additive merge: `current` wins; `previous` entries for Spaces other
    /// than `activeSpaceIndex` are retained unless their key already appears
    /// in `current` (fresh data wins) or earlier in `previous` (legacy
    /// duplicate collapse).
    static func merge(
        current: [WindowEntry],
        previous: [WindowEntry]?,
        activeSpaceIndex: Int
    ) -> (entries: [WindowEntry], stats: Stats) {
        var stats = Stats()
        stats.replacedActiveSpace = current.lazy.filter { $0.spaceIndex == activeSpaceIndex }.count

        var merged = current
        guard let previous else { return (merged, stats) }

        // Keys present in the current capture — used both for the running
        // dedupe set and to classify why a previous entry was dropped.
        let currentKeys = Set(current.map(mergeDedupeKey))
        var seen = currentKeys
        var retained: [WindowEntry] = []
        for entry in previous where entry.spaceIndex != activeSpaceIndex {
            let key = mergeDedupeKey(entry)
            if !seen.insert(key).inserted {
                if currentKeys.contains(key) {
                    stats.droppedToCurrent += 1
                } else {
                    stats.droppedAsLegacyDuplicate += 1
                }
                continue
            }
            retained.append(entry)
        }
        merged.append(contentsOf: retained)
        stats.keptFromOtherSpaces = retained.count
        return (merged, stats)
    }
}
