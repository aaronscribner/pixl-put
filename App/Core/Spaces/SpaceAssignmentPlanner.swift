import Foundation
import CoreGraphics

/// Pure planning for cross-Space restore (ADR-0002).
///
/// The only mechanism that relocates another app's windows across Spaces
/// (`CGSProcessAssignToSpace`) is **process-scoped**: every window of a pid
/// moves together. A snapshot, however, records a Space per *window*. When one
/// app's windows were captured on different Spaces, that snapshot is not
/// reproducible, and this planner is where that fact gets faced explicitly
/// rather than silently half-applied.
///
/// Free of CGS/AX side effects so the decision logic is unit-testable; the
/// executor feeds it snapshot entries and applies the result.
public enum SpaceAssignmentPlanner {

    /// One app, one target Space — the unit `CGSProcessAssignToSpace` accepts.
    public struct Assignment: Equatable, Sendable {
        public let bundleID: String
        public let targetSpaceIndex: Int
        /// Windows this assignment places correctly.
        public let satisfiedWindows: Int
        /// Windows of the same app captured on a *different* Space, which this
        /// assignment necessarily moves to the wrong place. Non-zero means the
        /// restore is partial and the user should be told.
        public let displacedWindows: Int

        public var isExact: Bool { displacedWindows == 0 }

        public init(bundleID: String, targetSpaceIndex: Int, satisfiedWindows: Int, displacedWindows: Int) {
            self.bundleID = bundleID
            self.targetSpaceIndex = targetSpaceIndex
            self.satisfiedWindows = satisfiedWindows
            self.displacedWindows = displacedWindows
        }
    }

    /// An app the process-scoped mechanism cannot help: its best available
    /// target would misplace at least as many windows as it places. Left
    /// untouched rather than collapsed onto one Space.
    public struct Unrestorable: Equatable, Sendable {
        public let bundleID: String
        /// Visible windows that voted.
        public let windowCount: Int
        /// How many distinct Spaces those windows occupied.
        public let spaceCount: Int
        /// What the best target would have achieved, recorded for the log so
        /// the skip is auditable rather than a silent omission.
        public let bestCaseSatisfied: Int
        public let bestCaseDisplaced: Int

        public init(
            bundleID: String,
            windowCount: Int,
            spaceCount: Int,
            bestCaseSatisfied: Int,
            bestCaseDisplaced: Int
        ) {
            self.bundleID = bundleID
            self.windowCount = windowCount
            self.spaceCount = spaceCount
            self.bestCaseSatisfied = bestCaseSatisfied
            self.bestCaseDisplaced = bestCaseDisplaced
        }
    }

    public struct Plan: Equatable, Sendable {
        public let assignments: [Assignment]
        /// Apps deliberately left alone because moving them would do net harm.
        public let unrestorable: [Unrestorable]

        public init(assignments: [Assignment], unrestorable: [Unrestorable] = []) {
            self.assignments = assignments
            self.unrestorable = unrestorable
        }

        /// Apps whose windows spanned Spaces at capture time and so cannot be
        /// fully restored. Drives the "restored N of M" UI copy.
        public var partial: [Assignment] { assignments.filter { !$0.isExact } }
        public var totalSatisfied: Int { assignments.reduce(0) { $0 + $1.satisfiedWindows } }
        public var totalDisplaced: Int { assignments.reduce(0) { $0 + $1.displacedWindows } }
        /// Windows left where they are by the do-no-harm guard. Distinct from
        /// `totalDisplaced`, which counts windows this plan *will* misplace.
        public var totalLeftAlone: Int { unrestorable.reduce(0) { $0 + $1.windowCount } }
    }

    /// Build the plan from snapshot entries.
    ///
    /// Target selection per app, in order:
    /// 1. The Space holding the most of that app's windows — moving the
    ///    majority is strictly better than moving the minority.
    /// 2. On a tie, the lowest Space index. Purely a determinism tie-break:
    ///    a tied top count can never clear the do-no-harm guard below (if the
    ///    top two Spaces both hold `n`, then `displaced >= n = satisfied`), so
    ///    this only decides what gets *reported* as the best case.
    ///
    /// The tie-break deliberately does **not** use `ordinalInApp`. Historically
    /// that field carried two incommensurable numberings — an AX creation
    /// ordinal (0, 1, 2…) from the active-Space pass, and the CG window number
    /// (~30000+) from the cross-Space pass — and comparing them ranked whichever
    /// Space happened to be active at capture time above every other Space, so
    /// ties collapsed the whole app onto the capture Space while the code
    /// claimed to be choosing "the earliest-created window". Per-Space storage
    /// retired the cross-Space pass, so every ordinal is an AX ordinal again,
    /// but the values still are not comparable *across* Spaces: each Space's
    /// file is captured independently. Any future heuristic here must use a
    /// field that means the same thing in every Space's config.
    ///
    /// Minimized windows are excluded from the vote: they are not visibly on
    /// any Space, so letting them outvote visible windows would move the ones
    /// the user can actually see.
    public static func plan(for windows: [WindowEntry]) -> Plan {
        var byBundle: [String: [WindowEntry]] = [:]
        for window in windows {
            byBundle[window.bundleID, default: []].append(window)
        }

        var assignments: [Assignment] = []
        var unrestorable: [Unrestorable] = []
        for (bundleID, entries) in byBundle {
            let voting = entries.filter { !$0.isMinimized }
            // An app with nothing but minimized windows has no meaningful
            // Space to be on; skip rather than pin it somewhere arbitrary.
            guard !voting.isEmpty else { continue }

            var countBySpace: [Int: Int] = [:]
            for entry in voting { countBySpace[entry.spaceIndex, default: 0] += 1 }

            // Most windows wins; lowest Space index breaks the tie.
            let target = countBySpace
                .sorted { lhs, rhs in
                    lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
                }
                .first

            guard let target else { continue }
            let satisfied = target.value
            let displaced = voting.count - satisfied

            // Do no harm. The move is process-scoped: it drags EVERY window of
            // the app onto one Space. Unless it strictly places more windows
            // than it misplaces, leaving the app where it is beats collapsing
            // it — and because the assignment is sticky for the app's process
            // lifetime (ADR-0002), a bad collapse outlives the restore and
            // captures newly opened windows too.
            guard satisfied > displaced else {
                unrestorable.append(Unrestorable(
                    bundleID: bundleID,
                    windowCount: voting.count,
                    spaceCount: countBySpace.count,
                    bestCaseSatisfied: satisfied,
                    bestCaseDisplaced: displaced
                ))
                continue
            }

            assignments.append(Assignment(
                bundleID: bundleID,
                targetSpaceIndex: target.key,
                satisfiedWindows: satisfied,
                displacedWindows: displaced
            ))
        }

        // Stable output so the plan is reproducible across runs.
        return Plan(
            assignments: assignments.sorted { $0.bundleID < $1.bundleID },
            unrestorable: unrestorable.sorted { $0.bundleID < $1.bundleID }
        )
    }

    // MARK: - Per-window planning (yabai backend)

    /// A single window to relocate. Only produced when the backend supports
    /// per-window moves.
    public struct WindowMove: Equatable, Sendable {
        public let windowID: CGWindowID
        public let targetSpaceIndex: Int
        public let bundleID: String
        public init(windowID: CGWindowID, targetSpaceIndex: Int, bundleID: String) {
            self.windowID = windowID
            self.targetSpaceIndex = targetSpaceIndex
            self.bundleID = bundleID
        }
    }

    /// Space-independent match key: bundle + identity. Deliberately excludes
    /// `spaceIndex` — the entire point is to match a window regardless of
    /// which Space it currently sits on — and excludes the creation ordinal,
    /// which is only consulted to break a tie (see `perWindowMoves`).
    static func matchKey(bundleID: String, identity: WindowIdentity) -> String {
        "\(bundleID)|\(identity)"
    }

    /// Pair snapshot entries with live windows and emit one move per window
    /// whose Space differs from the snapshot.
    ///
    /// This is where deep identity earns its keep: matching is by resolved
    /// identity (browser tab set, editor workspace, terminal CWD), so two
    /// windows of the *same* app are told apart and can be sent to different
    /// Spaces — which the per-app backend fundamentally cannot express.
    ///
    /// Matching rules are `perWindowMatches`'. Ordinals are **not** a match
    /// key: they are renumbered whenever an app restarts and reordered as
    /// windows are focused, so relocating a window on that guess moves the
    /// wrong one. Order-only windows match only by window ID (same boot), a
    /// unique title, or being their app's sole window. Windows with no
    /// `windowID` are skipped because there is nothing to address.
    public static func perWindowMoves(
        snapshot: [WindowEntry],
        live: [LiveWindow]
    ) -> [WindowMove] {
        perWindowMatches(snapshot: snapshot, live: live).map { match in
            WindowMove(windowID: match.windowID,
                       targetSpaceIndex: match.entry.spaceIndex,
                       bundleID: match.live.bundleID)
        }
    }

    /// A live window paired with the captured entry that describes where it
    /// belongs — Space *and* frame. `perWindowMoves` is the Space-only
    /// projection; the cross-Space restore uses the full pair so it can put
    /// frames right on Spaces AX cannot see.
    public struct WindowMatch: Equatable, Sendable {
        public let windowID: CGWindowID
        public let live: LiveWindow
        public let entry: WindowEntry
        /// What paired them: "windowID", "identity", "title" or "sole-window".
        public let matchedBy: String
        public init(windowID: CGWindowID, live: LiveWindow, entry: WindowEntry, matchedBy: String = "identity") {
            self.windowID = windowID
            self.live = live
            self.entry = entry
            self.matchedBy = matchedBy
        }
    }

    /// Pair live windows with captured entries, strongest evidence first:
    ///
    /// 1. **Window ID** — the same window, if it was captured in this boot
    ///    (`BootDetection.windowIDIsCurrent`). Exact for every app, including
    ///    order-only ones, while the app keeps running.
    /// 2. **Identity** — bundle + deep identity. When one identity was
    ///    captured once, that entry wins. When it was captured several times
    ///    on one Space, any of them places the window. On several Spaces, a
    ///    unique exact title decides, then an exact ordinal with a single
    ///    candidate; anything else is left alone.
    /// 3. **Fallback** — per app, whatever is left: a unique exact title, then
    ///    a sole remaining order-only window (`FallbackMatcher`). This is what
    ///    lets Teams, Outlook or Messages go back to their Space after a
    ///    restart; before it, order-only windows were never matched here.
    ///
    /// Each entry and each live window is used at most once.
    public static func perWindowMatches(
        snapshot: [WindowEntry],
        live: [LiveWindow],
        windowIDsValidSince: Date? = BootDetection.currentBootTime
    ) -> [WindowMatch] {
        var matches: [WindowMatch] = []
        var consumedEntries: Set<Int> = []
        var claimedWindowIDs: Set<CGWindowID> = []
        // Deterministic live order so runs are reproducible and diffable.
        let orderedLive = live
            .filter { $0.windowID != nil }
            .sorted { ($0.bundleID, $0.windowID ?? 0) < ($1.bundleID, $1.windowID ?? 0) }

        // 1. Window ID.
        let liveByWindowID = Dictionary(orderedLive.map { ($0.windowID!, $0) },
                                        uniquingKeysWith: { first, _ in first })
        for (index, entry) in snapshot.enumerated() {
            guard let wid = entry.windowID,
                  BootDetection.windowIDIsCurrent(capturedAt: entry.capturedAt, bootTime: windowIDsValidSince),
                  let window = liveByWindowID[wid], window.bundleID == entry.bundleID,
                  !claimedWindowIDs.contains(wid) else { continue }
            consumedEntries.insert(index)
            claimedWindowIDs.insert(wid)
            matches.append(WindowMatch(windowID: wid, live: window, entry: entry, matchedBy: "windowID"))
        }

        // 2. Identity, for entries with a real identity.
        var entriesByKey: [String: [Int]] = [:]
        for (index, entry) in snapshot.enumerated() where !consumedEntries.contains(index) {
            if case .ordinal = entry.identity { continue }
            entriesByKey[matchKey(bundleID: entry.bundleID, identity: entry.identity), default: []]
                .append(index)
        }
        for window in orderedLive {
            let windowID = window.windowID!
            if claimedWindowIDs.contains(windowID) { continue }
            if case .ordinal = window.identity { continue }
            let key = matchKey(bundleID: window.bundleID, identity: window.identity)
            // Decide on every entry with this key, consumed or not: picking
            // by elimination after an earlier pick would compound a wrong
            // guess instead of leaving the window alone.
            guard let candidates = entriesByKey[key] else { continue }

            let chosen: Int?
            let distinctSpaces = Set(candidates.map { snapshot[$0].spaceIndex })
            if candidates.count == 1 {
                chosen = candidates[0]
            } else if distinctSpaces.count == 1 {
                // Several windows of one identity, all on one Space (two
                // VS Code windows of the same workspace): any unconsumed
                // entry places this window correctly.
                chosen = candidates.first { !consumedEntries.contains($0) }
            } else {
                // Same identity on several Spaces: a unique exact title tells
                // the windows apart; failing that, an exact ordinal with a
                // single target. Anything else stays where it is.
                let byTitle = window.title.map { title in
                    candidates.filter { snapshot[$0].title == title }
                } ?? []
                if byTitle.count == 1 {
                    chosen = byTitle[0]
                } else {
                    let byOrdinal = candidates.filter { snapshot[$0].ordinalInApp == window.ordinalInApp }
                    chosen = Set(byOrdinal.map { snapshot[$0].spaceIndex }).count == 1 ? byOrdinal.first : nil
                }
            }
            guard let index = chosen, !consumedEntries.contains(index) else { continue }
            consumedEntries.insert(index)
            claimedWindowIDs.insert(windowID)
            matches.append(WindowMatch(windowID: windowID, live: window, entry: snapshot[index], matchedBy: "identity"))
        }

        // 3. Fallback, per app, for what is left on both sides.
        let entriesLeft = Dictionary(
            grouping: snapshot.indices.filter { !consumedEntries.contains($0) },
            by: { snapshot[$0].bundleID }
        )
        let liveLeft = Dictionary(
            grouping: orderedLive.filter { !claimedWindowIDs.contains($0.windowID!) },
            by: \.bundleID
        )
        for bundleID in entriesLeft.keys.sorted() {
            guard let windows = liveLeft[bundleID] else { continue }
            let entries = entriesLeft[bundleID]!
            let pairs = FallbackMatcher.pair(
                saved: entries.map { FallbackMatcher.Candidate(title: snapshot[$0].title, identity: snapshot[$0].identity) },
                live: windows.map { FallbackMatcher.Candidate(title: $0.title, identity: $0.identity) }
            )
            for pair in pairs {
                let window = windows[pair.live]
                matches.append(WindowMatch(windowID: window.windowID!, live: window,
                                           entry: snapshot[entries[pair.saved]],
                                           matchedBy: pair.reason.rawValue))
            }
        }
        return matches
    }
}
