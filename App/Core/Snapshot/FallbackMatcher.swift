import Foundation

/// Pairs one app's windows that neither the window ID nor identity could
/// pair — without ever trusting window-list order.
///
/// Identity resolves to `.ordinal` for every app PixlPut has no stronger
/// signal for (Teams, Outlook, Messages, Firefox, Slack, …). The ordinal is a
/// window's position in the app's AX window list, which is renumbered when the
/// app restarts and reordered when windows are focused, so pairing on it
/// alone could put one window where another belongs. Measured 2026-10-01: a
/// post-reboot "Restore windows to their Spaces" left all 19 such windows
/// alone, because the only rule available was "skip order-only windows".
///
/// Two rules replace it, applied per app, strongest first:
/// 1. **Unique title** — an exact, non-empty title that occurs exactly once
///    among the app's leftover saved windows and exactly once among its
///    leftover live windows. Firefox restores its session after a reboot, so
///    most page titles come back unchanged. A title shared by two windows on
///    either side proves nothing and pairs nothing.
/// 2. **Sole window** — after rule 1, exactly one saved and one live window
///    remain and both are order-only. An app with one window has nothing to
///    confuse it with (Teams, Outlook, Messages).
///
/// Anything else is left alone: a window not moved is recoverable by hand; a
/// window moved into another's place is a bug report.
public enum FallbackMatcher {

    /// One window's matching inputs.
    public struct Candidate: Equatable, Sendable {
        public let title: String?
        /// `true` when identity is `.ordinal` — nothing but list position.
        public let isOrderOnly: Bool

        public init(title: String?, isOrderOnly: Bool) {
            self.title = title
            self.isOrderOnly = isOrderOnly
        }

        public init(title: String?, identity: WindowIdentity) {
            self.title = title
            if case .ordinal = identity { self.isOrderOnly = true } else { self.isOrderOnly = false }
        }
    }

    public enum Reason: String, Sendable {
        case uniqueTitle = "title"
        case soleWindow = "sole-window"
    }

    /// Indices into the `saved` and `live` arrays passed to `pair`.
    public struct Pair: Equatable, Sendable {
        public let saved: Int
        public let live: Int
        public let reason: Reason
    }

    /// Pair one app's leftover saved windows with its leftover live windows.
    /// Each index appears in at most one pair. Output is in `saved` order.
    public static func pair(saved: [Candidate], live: [Candidate]) -> [Pair] {
        var pairs: [Pair] = []
        var usedSaved: Set<Int> = []
        var usedLive: Set<Int> = []

        // Rule 1 — unique exact title on both sides.
        let savedByTitle = indicesByTitle(saved)
        let liveByTitle = indicesByTitle(live)
        for (title, savedIndices) in savedByTitle where savedIndices.count == 1 {
            guard let liveIndices = liveByTitle[title], liveIndices.count == 1 else { continue }
            pairs.append(Pair(saved: savedIndices[0], live: liveIndices[0], reason: .uniqueTitle))
            usedSaved.insert(savedIndices[0])
            usedLive.insert(liveIndices[0])
        }

        // Rule 2 — exactly one order-only window left on each side.
        let savedLeft = saved.indices.filter { !usedSaved.contains($0) }
        let liveLeft = live.indices.filter { !usedLive.contains($0) }
        if savedLeft.count == 1, liveLeft.count == 1,
           saved[savedLeft[0]].isOrderOnly, live[liveLeft[0]].isOrderOnly {
            pairs.append(Pair(saved: savedLeft[0], live: liveLeft[0], reason: .soleWindow))
        }

        return pairs.sorted { $0.saved < $1.saved }
    }

    private static func indicesByTitle(_ candidates: [Candidate]) -> [String: [Int]] {
        var out: [String: [Int]] = [:]
        for (index, candidate) in candidates.enumerated() {
            guard let title = candidate.title, !title.isEmpty else { continue }
            out[title, default: []].append(index)
        }
        return out
    }
}
