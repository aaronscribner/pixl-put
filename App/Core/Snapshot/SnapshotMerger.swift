import Foundation
import CoreGraphics

/// Pure, testable identity-enrichment logic for `SnapshotEngine.capture()`.
///
/// Since the all-Spaces CG pass, every capture is COMPLETE — it covers every
/// Space in one shot — so each snapshot replaces the previous one wholesale.
/// The additive cross-capture merge that used to live here (retain previous
/// entries for Spaces the capture didn't touch) is gone, and with it the
/// unbounded-growth pathology it needed dedupe keys to suppress (observed in
/// the wild as 1000+ entry snapshots — ~8x duplication — within an hour).
///
/// What survives a capture is IDENTITY. CG can only describe an off-Space
/// window weakly (no document URL, no tab set, title needs Screen Recording
/// permission), but if that window's Space was active during some earlier
/// capture, the previous snapshot holds its full AX identity. The CG window
/// number is stable for the process lifetime of the owning app, so it joins
/// the weak current entry to the strong previous one exactly.
enum SnapshotMerger {

    /// Stable per-window ordinal for cross-Space CG windows.
    ///
    /// The CG window number (`kCGWindowNumber`) is constant for a window's
    /// lifetime, so deriving the ordinal from it keeps the entry's match key
    /// stable across captures even as the active Space's AX window count
    /// changes.
    ///
    /// The previous implementation seeded a running per-bundle counter from
    /// the active-Space AX window count (`max(AX ordinal) + 1`). That count
    /// changes every time the user switches to a Space with a different
    /// number of windows, so the SAME off-Space window drew a DIFFERENT
    /// ordinal each capture — defeating dedupe and growing the snapshot
    /// ~33 windows per Space-switch.
    static func crossSpaceOrdinal(forWindowID windowID: CGWindowID) -> Int {
        Int(windowID)
    }

    /// Outcome counters for diagnostics.
    struct Stats: Equatable {
        /// Weak (ordinal-identity) current entries upgraded with the full
        /// identity a previous capture recorded for the same windowID.
        var identityUpgraded: Int = 0
        /// Weak current entries with no strong previous identity to inherit
        /// (windowID never captured on an active Space, or the app restarted
        /// and the windowID is new).
        var leftWeak: Int = 0
    }

    /// Carry strong identity forward onto weak entries, joined by windowID.
    ///
    /// Output is exactly `current` — same windows, same frames, same Spaces;
    /// nothing from `previous` is retained as an entry, so the result can
    /// never grow beyond what is on screen right now. For each current entry
    /// whose identity is the weak `.ordinal` fallback, if `previous` holds an
    /// entry with the same windowID, same bundle, and a stronger identity,
    /// the identity, `ordinalInApp`, and `isFullscreen` transfer. Those three
    /// fields are the ones only AX knows; frame/Space/display stay current
    /// because CG just measured them.
    static func enrich(
        current: [WindowEntry],
        previous: [WindowEntry]?
    ) -> (entries: [WindowEntry], stats: Stats) {
        var stats = Stats()
        guard let previous, !previous.isEmpty else {
            stats.leftWeak = current.lazy.filter { isWeak($0) }.count
            return (current, stats)
        }

        // Strong previous identities by windowID. Last write wins on the
        // (theoretically impossible) duplicate windowID; entries without a
        // windowID or without strong identity have nothing to donate.
        var strongByWindowID: [CGWindowID: WindowEntry] = [:]
        for entry in previous {
            guard let wid = entry.windowID, !isWeak(entry) else { continue }
            strongByWindowID[wid] = entry
        }

        let enriched = current.map { entry -> WindowEntry in
            guard isWeak(entry),
                  let wid = entry.windowID,
                  let donor = strongByWindowID[wid],
                  donor.bundleID == entry.bundleID else {
                if isWeak(entry) { stats.leftWeak += 1 }
                return entry
            }
            stats.identityUpgraded += 1
            return WindowEntry(
                bundleID: entry.bundleID,
                identity: donor.identity,
                ordinalInApp: donor.ordinalInApp,
                displayFingerprintID: entry.displayFingerprintID,
                spaceIndex: entry.spaceIndex,
                frame: entry.frame,
                isMinimized: entry.isMinimized,
                isFullscreen: donor.isFullscreen,
                capturedAt: entry.capturedAt,
                windowID: entry.windowID
            )
        }
        return (enriched, stats)
    }

    /// Weak = the layer-4 ordinal fallback; anything else is worth keeping.
    private static func isWeak(_ entry: WindowEntry) -> Bool {
        if case .ordinal = entry.identity { return true }
        return false
    }
}
