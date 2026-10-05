import Foundation

/// Why open windows were left alone by the cross-Space restore, per app.
///
/// The old menu message — "19 window(s) had no captured match" — lumped
/// three different situations together and read like a failed lookup, when
/// most of those windows were never compared at all (2026-10-01). They need
/// different advice:
/// - **Couldn't tell apart** — the app has saved windows still unplaced and
///   open windows nothing could pair (several windows, no unique titles).
///   This is the shortfall worth telling the user about.
/// - **Not in your saved layout** — the app has no saved windows at all.
/// - **New since capture** — every saved window of the app was placed; these
///   are extra windows. Expected; logged, not reported.
public enum UnmatchedWindows {

    public struct AppCount: Equatable, Sendable {
        public let bundleID: String
        public let count: Int
        public init(bundleID: String, count: Int) {
            self.bundleID = bundleID
            self.count = count
        }
    }

    public struct Summary: Equatable, Sendable {
        public let couldNotTellApart: [AppCount]
        public let notInSavedLayout: [AppCount]
        public let newSinceCapture: [AppCount]
    }

    /// `unmatchedLive` — bundle IDs of open windows no match claimed, one per
    /// window. `saved` and `matched` — the entries planned against and the
    /// entries that found a window.
    public static func classify(
        unmatchedLive: [String],
        saved: [WindowEntry],
        matched: [WindowEntry]
    ) -> Summary {
        var savedCount: [String: Int] = [:]
        for entry in saved { savedCount[entry.bundleID, default: 0] += 1 }
        var matchedCount: [String: Int] = [:]
        for entry in matched { matchedCount[entry.bundleID, default: 0] += 1 }
        var liveCount: [String: Int] = [:]
        for bundleID in unmatchedLive { liveCount[bundleID, default: 0] += 1 }

        var apart: [AppCount] = []
        var notSaved: [AppCount] = []
        var extra: [AppCount] = []
        for (bundleID, count) in liveCount.sorted(by: { $0.key < $1.key }) {
            let unplaced = savedCount[bundleID, default: 0] - matchedCount[bundleID, default: 0]
            let app = AppCount(bundleID: bundleID, count: count)
            if savedCount[bundleID, default: 0] == 0 {
                notSaved.append(app)
            } else if unplaced > 0 {
                apart.append(app)
            } else {
                extra.append(app)
            }
        }
        return Summary(couldNotTellApart: apart, notInSavedLayout: notSaved, newSinceCapture: extra)
    }
}
