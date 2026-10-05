import Foundation
import CoreGraphics

/// How aggressively a move verifies and retries. The right policy depends on
/// WHY the restore is running, and only the caller knows that.
///
/// The measured cost of getting this wrong (diagnostic log, 2026-08-02): a
/// single moved window took 6.7–12s because the settling-grade policy —
/// 3 attempts × (set + set + re-read), each call under a 1.5s messaging
/// timeout against a busy app — was applied to a routine Space switch. The
/// clamp pathology it defends against (AX reporting `.success` while
/// silently leaving the window in place) only occurs while displays are
/// re-attaching after wake or reconfiguration.
public enum MovePolicy: Sendable {
    /// Routine conditions — Space switch, manual restore. The window server
    /// is settled: a set either lands immediately or the app is busy, and
    /// waiting on a busy app blocks every other window behind it. One
    /// attempt, 0.5s messaging timeout.
    case fast
    /// Displays are settling — wake, monitor reconfiguration. AX silently
    /// clamps positions until the virtual coordinate region is back, so
    /// verify-and-retry is required. 3 attempts, 1.5s timeout, 150ms pauses.
    case settling

    var messagingTimeout: Float {
        switch self {
        case .fast: return 0.5
        case .settling: return 1.5
        }
    }
    var maxAttempts: Int {
        switch self {
        case .fast: return 1
        case .settling: return 3
        }
    }
    var interAttemptDelayNanos: UInt64 {
        switch self {
        case .fast: return 0
        case .settling: return 150_000_000
        }
    }
}

/// Restoration backend abstraction. The production implementation uses
/// `AXClient` from `Core/Accessibility/`; tests inject a fixture.
public protocol RestorerBackend: Sendable {
    /// Enumerate currently-resolvable windows. Each tuple matches a window
    /// in the active OS state to its current frame + identity signal.
    ///
    /// `limitToBundleIDs` — when non-nil, only apps in the set are walked.
    /// AX enumeration is serial with a 1s messaging timeout per app, so on a
    /// system with dozens of running apps the full walk dominates restore
    /// latency; a Space-switch restore only needs the apps its snapshot
    /// entries name. `nil` = walk everything (capture does).
    func enumerateLiveWindows(limitToBundleIDs: Set<String>?) async throws -> [LiveWindow]
    /// Move a window to a target frame. Returns `true` if the move
    /// completed; `false` if the user was interacting with the window
    /// (FR-012 cancellation).
    func move(window: LiveWindow, to frame: CGRectCodable, policy: MovePolicy) async throws -> Bool
    /// Enter or exit fullscreen on the specified display.
    func setFullscreen(window: LiveWindow, on displayFingerprintID: String) async throws -> Bool
}

public extension RestorerBackend {
    /// Unfiltered enumeration, kept for capture-side callers.
    func enumerateLiveWindows() async throws -> [LiveWindow] {
        try await enumerateLiveWindows(limitToBundleIDs: nil)
    }
}

/// A window currently present in the active OS state, paired with the
/// signals needed to match a snapshot `WindowEntry`.
public struct LiveWindow: Sendable, Equatable {
    public let opaqueID: ObjectIdentifier?  // stable per-session AX handle
    public let bundleID: String
    public let identity: WindowIdentity
    /// Per-bundle creation index — must match the value stored in
    /// `WindowEntry.ordinalInApp` at capture time for reliable matching
    /// when multiple windows of the same bundle resolve to the same
    /// identity. Required (not optional) because the live-side AX
    /// enumeration always knows it.
    public let ordinalInApp: Int
    public let currentFrame: CGRectCodable
    public let currentDisplayFingerprintID: String
    public let isFullscreen: Bool
    /// CoreGraphics window number, when the AX→CG bridge resolved it.
    /// Required to address a single window for per-window Space relocation
    /// (ADR-0002); `nil` falls back to the per-app relocation path.
    public let windowID: CGWindowID?
    /// The window's current title, when known. Feeds `FallbackMatcher`.
    public let title: String?

    public init(
        opaqueID: ObjectIdentifier? = nil,
        bundleID: String,
        identity: WindowIdentity,
        ordinalInApp: Int = 0,
        currentFrame: CGRectCodable,
        currentDisplayFingerprintID: String,
        windowID: CGWindowID? = nil,
        isFullscreen: Bool,
        title: String? = nil
    ) {
        self.opaqueID = opaqueID
        self.bundleID = bundleID
        self.identity = identity
        self.ordinalInApp = ordinalInApp
        self.currentFrame = currentFrame
        self.currentDisplayFingerprintID = currentDisplayFingerprintID
        self.windowID = windowID
        self.isFullscreen = isFullscreen
        self.title = title
    }
}

/// Result of a single `Restorer.apply` invocation. Surfaces what was moved,
/// skipped, displaced, or cancelled — feeds the menu-bar "Last Restore" status.
public struct RestoreReport: Sendable, Equatable {
    public let moved: Int
    public let skippedAlreadyAtFrame: Int
    public let skippedMissingWindow: Int
    /// Saved windows whose app has open windows PixlPut could not tell apart
    /// (order-only, no unique title, more than one window). Left alone.
    public let skippedUnidentified: Int
    public let displacedNoMatchingDisplay: Int
    public let cancelledByUserInteraction: Int
    public let fullscreenAttempts: Int
    public let fullscreenSucceeded: Int
}

public actor Restorer {

    public let backend: any RestorerBackend
    /// Tolerance for the "already-at-frame" check. Project constitution §III + spec FR-010.
    public let tolerancePoints: CGFloat

    public init(backend: any RestorerBackend, tolerancePoints: CGFloat = 1.0) {
        self.backend = backend
        self.tolerancePoints = tolerancePoints
    }

    /// Composite key for matching snapshot entries to live windows.
    /// `WindowIdentity` alone is not unique — two different bundles can
    /// produce identical identity values (e.g. both `.ordinal(0)`). This
    /// struct includes the bundle ID so a Brave window and an iTerm2
    /// window never collide.
    private struct MatchKey: Hashable {
        let bundleID: String
        let identity: WindowIdentity
    }

    /// A work item produced by the decision phase and consumed by the
    /// concurrent execution phase. Sendable so it can cross the TaskGroup
    /// boundary.
    private struct PendingAction: Sendable {
        let bundleID: String
        let window: LiveWindow
        let kind: Kind
        enum Kind: Sendable {
            case move(target: CGRectCodable)
            case moveDisplaced(target: CGRectCodable)
            case fullscreen(displayFingerprintID: String)
        }
    }

    /// Outcome of a single PendingAction. Tallied back into the
    /// `RestoreReport` counters after the TaskGroup completes.
    private enum MoveOutcome: Sendable {
        case moved
        case cancelled
        case movedDisplaced
        case cancelledDisplaced
        case fullscreenSucceeded
        case fullscreenCancelled
        case errored
    }

    /// Bundles whose windows we never attempt to move at restore time.
    /// These are system-managed surfaces (Notification Center widgets,
    /// Dock, Mission Control overlay) where the AX setter returns
    /// unexpected status codes or the OS silently re-positions them.
    /// They can be captured (real widgets have real frames), but moving
    /// them risks throwing and aborting the rest of the restore loop.
    private static let unmovableBundles: Set<String> = [
        "com.apple.notificationcenterui",
        "com.apple.dock",
        "com.apple.WindowManager",
        "com.apple.controlcenter",
    ]

    /// Apply a snapshot to the current OS state.
    ///
    /// Matching, strongest evidence first:
    ///   0. Window ID, for entries captured in this boot
    ///      (`windowIDsValidSince`, default the current boot time).
    ///   1. `(bundleID, identity)` for entries with a real identity. Within
    ///      a group both sides pair in `ordinalInApp` order — the ordinal
    ///      only breaks ties between windows sharing an identity (two iTerm2
    ///      windows in `~/work`).
    ///   2. Per app, what is left: a unique exact title, then a sole
    ///      remaining order-only window (`FallbackMatcher`). Order-only
    ///      entries never pair on list position alone.
    ///   3. Leftover entries count as `skippedUnidentified` when their app
    ///      still has unclaimed open windows, else `skippedMissingWindow`
    ///      (FR-011). Live windows with no entry are left alone.
    ///   4. Each live window is consumed at most once — so no window
    ///      gets moved twice or hijacks another window's target frame.
    public func apply(
        _ snapshot: Snapshot,
        activeDisplayFingerprintIDs: Set<String>,
        currentDisplayBoundsByID: [String: CGRectCodable] = [:],
        onlySpaceIndex: Int? = nil,
        movePolicy: MovePolicy = .fast,
        windowIDsValidSince: Date? = BootDetection.currentBootTime
    ) async throws -> RestoreReport {
        // Only apps named by the entries we'll consider need enumerating —
        // live windows of other apps are left alone regardless (constructive
        // matching), and the full AX walk is the dominant restore cost.
        let relevantBundles: Set<String>
        if let only = onlySpaceIndex {
            relevantBundles = Set(snapshot.windows.lazy.filter { $0.spaceIndex == only }.map(\.bundleID))
        } else {
            relevantBundles = Set(snapshot.windows.map(\.bundleID))
        }
        let live = try await backend.enumerateLiveWindows(limitToBundleIDs: relevantBundles)

        // Re-anchoring: window frames are stored in GLOBAL desktop
        // coordinates, which are only valid while each display sits at the
        // same origin. When the same physical monitor is present but at a
        // different origin (because another display was added/removed/
        // rearranged), the raw saved frame lands in the wrong place — often
        // off-screen (e.g. a frame at x=-3763 saved when the monitor was at
        // x=-3840, applied now that the monitor is at x=0). Translate each
        // frame by the delta between its display's SAVED origin and its
        // CURRENT origin so the window lands in the same spot ON that
        // monitor regardless of where the monitor now sits in the global
        // layout. Falls back to the raw frame when either origin is unknown
        // (e.g. the empty map used by unit tests) or the delta is zero.
        let savedDisplayBoundsByID: [String: CGRectCodable] = Dictionary(
            snapshot.displays.map { ($0.fingerprint.id, $0.bounds) },
            uniquingKeysWith: { first, _ in first }
        )
        func reanchoredFrame(for entry: WindowEntry) -> CGRectCodable {
            guard let saved = savedDisplayBoundsByID[entry.displayFingerprintID],
                  let current = currentDisplayBoundsByID[entry.displayFingerprintID] else {
                return entry.frame
            }
            let dx = current.x - saved.x
            let dy = current.y - saved.y
            if dx == 0 && dy == 0 { return entry.frame }
            return CGRectCodable(
                x: entry.frame.x + dx, y: entry.frame.y + dy,
                width: entry.frame.width, height: entry.frame.height
            )
        }

        // Phase C — restrict the snapshot to entries on the requested Space.
        // `nil` (default) preserves the original "restore everything" behaviour
        // used by the manual restore command. `Restorer.applyForActiveSpace(...)`
        // calls in AppLifecycle's wake / Space-switch handlers pass the
        // currently-active Space so only that Space's entries fire.
        //
        // The filter is on snapshot ENTRIES, not live windows: live windows
        // not in the snapshot are already left alone (constructive matching),
        // and live windows for OTHER Spaces aren't enumerable by AX anyway.
        let entriesToConsider: [WindowEntry]
        if let only = onlySpaceIndex {
            entriesToConsider = snapshot.windows.filter { $0.spaceIndex == only }
        } else {
            entriesToConsider = snapshot.windows
        }

        // PHASE 0 — windowID join. The CG window number is stable for the
        // process lifetime of the owning app, so an entry whose windowID is
        // alive RIGHT NOW identifies its window with an integer compare — no
        // identity resolution, no ordinal heuristics, immune to the
        // ordinal-shift and same-identity-group ambiguities below. Identity
        // matching remains only for entries whose app restarted since
        // capture (windowID gone) and legacy snapshots (windowID nil).
        var liveByWindowID: [CGWindowID: LiveWindow] = [:]
        for w in live {
            if let wid = w.windowID { liveByWindowID[wid] = w }
        }
        var pairedByWindowID: [(entry: WindowEntry, window: LiveWindow)] = []
        var pairedLiveIDs: Set<CGWindowID> = []
        var remainingEntries: [WindowEntry] = []
        for entry in entriesToConsider {
            // A window ID from an earlier boot names whatever the window
            // server handed that number to this time — often another window
            // of the same app (BootDetection.windowIDIsCurrent).
            if let wid = entry.windowID,
               BootDetection.windowIDIsCurrent(capturedAt: entry.capturedAt, bootTime: windowIDsValidSince),
               let liveWindow = liveByWindowID[wid],
               liveWindow.bundleID == entry.bundleID,
               !pairedLiveIDs.contains(wid) {
                pairedByWindowID.append((entry, liveWindow))
                pairedLiveIDs.insert(wid)
            } else {
                remainingEntries.append(entry)
            }
        }
        // Windows claimed by the join are out of the identity pool — a
        // window must not be movable twice under two different keys.
        let identityLive = live.filter { w in
            guard let wid = w.windowID else { return true }
            return !pairedLiveIDs.contains(wid)
        }

        // Group the remaining live windows by (bundleID, identity), keeping
        // each window's index into `identityLive` so the fallback pass knows
        // which ones identity left unclaimed. Ordinal-sorted within a key: the
        // ordinal breaks ties between windows that share a real identity (two
        // iTerm2 windows in ~/work), and is never a match key on its own.
        var liveByKey: [MatchKey: [Int]] = [:]
        for (index, w) in identityLive.enumerated() {
            liveByKey[MatchKey(bundleID: w.bundleID, identity: w.identity), default: []].append(index)
        }
        for (k, group) in liveByKey {
            liveByKey[k] = group.sorted { identityLive[$0].ordinalInApp < identityLive[$1].ordinalInApp }
        }

        // Group the remaining snapshot entries the same way.
        var snapshotByKey: [MatchKey: [WindowEntry]] = [:]
        for e in remainingEntries {
            let key = MatchKey(bundleID: e.bundleID, identity: e.identity)
            snapshotByKey[key, default: []].append(e)
        }

        var moved = 0
        var skippedAlreadyAtFrame = 0
        var skippedMissingWindow = 0
        var skippedUnidentified = 0
        var errored = 0
        var displacedNoMatchingDisplay = 0
        var cancelledByUserInteraction = 0
        var fullscreenAttempts = 0
        var fullscreenSucceeded = 0

        DiagnosticLog.write("restore", """
            apply begin: entries=\(entriesToConsider.count) live=\(live.count) \
            windowIDPaired=\(pairedByWindowID.count) identityFallback=\(remainingEntries.count) \
            onlySpaceIndex=\(String(describing: onlySpaceIndex)) \
            activeDisplays=\(activeDisplayFingerprintIDs.count)
            """)
        for (key, liveGroup) in liveByKey {
            DiagnosticLog.write("restore", """
                live group: bundle=\(key.bundleID) identity=\(key.identity) \
                count=\(liveGroup.count) \
                ordinals=\(liveGroup.map { String(identityLive[$0].ordinalInApp) }.joined(separator: ","))
                """)
        }
        for (key, snapGroup) in snapshotByKey {
            DiagnosticLog.write("restore", """
                snap group: bundle=\(key.bundleID) identity=\(key.identity) \
                count=\(snapGroup.count) \
                ordinals=\(snapGroup.map(\.ordinalInApp).map(String.init).joined(separator: ","))
                """)
        }

        // PHASE 1 — Decision (fast, no awaits). Walk every entry, classify
        // it as either an immediate skip (counted now) or a pending
        // backend action (queued for phase 2). Counters mutate only here.
        var pendingActions: [PendingAction] = []

        // Shared decide tail for both match routes: idempotence check,
        // unmovable check, then queue the appropriate backend action.
        func decide(entry: WindowEntry, liveWindow: LiveWindow, matchedBy: String) {
            let targetFrame = reanchoredFrame(for: entry)

            DiagnosticLog.write("restore", """
                decide: PAIR[\(matchedBy)] bundle=\(entry.bundleID) identity=\(entry.identity) \
                snapshotOrdinal=\(entry.ordinalInApp) liveOrdinal=\(liveWindow.ordinalInApp) \
                liveFrame=(\(liveWindow.currentFrame.x),\(liveWindow.currentFrame.y),\
                \(liveWindow.currentFrame.width)x\(liveWindow.currentFrame.height)) \
                targetFrame=(\(targetFrame.x),\(targetFrame.y),\
                \(targetFrame.width)x\(targetFrame.height)) \
                savedFrame=(\(entry.frame.x),\(entry.frame.y)) \
                snapshotSpaceIndex=\(entry.spaceIndex)
                """)

            // §III idempotence: don't move if already at recorded frame + state.
            if liveWindow.currentDisplayFingerprintID == entry.displayFingerprintID,
               liveWindow.currentFrame.isApproximately(targetFrame, tolerance: tolerancePoints),
               liveWindow.isFullscreen == entry.isFullscreen {
                skippedAlreadyAtFrame += 1
                DiagnosticLog.write("restore", "decide: SKIP-IDEMPOTENT bundle=\(entry.bundleID)")
                return
            }

            // System surfaces we never try to move (notificationcenterui,
            // dock, WindowManager, controlcenter — see unmovableBundles).
            if Self.unmovableBundles.contains(entry.bundleID) {
                skippedMissingWindow += 1
                DiagnosticLog.write("restore", """
                    decide: SKIP-UNMOVABLE bundle=\(entry.bundleID) \
                    identity=\(entry.identity) — system-managed surface, not moving
                    """)
                return
            }

            let targetDisplayMissing = !activeDisplayFingerprintIDs.contains(entry.displayFingerprintID)
            if targetDisplayMissing {
                displacedNoMatchingDisplay += 1
                pendingActions.append(.init(
                    bundleID: entry.bundleID,
                    window: liveWindow,
                    kind: .moveDisplaced(target: entry.frame)
                ))
            } else if entry.isFullscreen {
                fullscreenAttempts += 1
                pendingActions.append(.init(
                    bundleID: entry.bundleID,
                    window: liveWindow,
                    kind: .fullscreen(displayFingerprintID: entry.displayFingerprintID)
                ))
            } else {
                pendingActions.append(.init(
                    bundleID: entry.bundleID,
                    window: liveWindow,
                    kind: .move(target: targetFrame)
                ))
            }
        }

        // PHASE 1a — windowID-joined pairs: already matched exactly, no
        // ordinal or grouping heuristics apply.
        for (entry, liveWindow) in pairedByWindowID {
            decide(entry: entry, liveWindow: liveWindow, matchedBy: "windowID")
        }

        // PHASE 1b — identity, for entries with a real identity. Within a key,
        // entries and live windows pair in ordinal order. Order-only entries
        // never pair here: an ordinal is a list position, renumbered when the
        // app restarts and reordered as windows are focused, so equal counts
        // don't make positions agree — that pairing could swap two windows.
        var claimedLive: Set<Int> = []
        var leftoverEntries: [WindowEntry] = []
        let strongKeys = snapshotByKey.keys
            .filter { if case .ordinal = $0.identity { return false } else { return true } }
            .sorted { "\($0.bundleID)|\($0.identity)" < "\($1.bundleID)|\($1.identity)" }
        for key in strongKeys {
            let entries = snapshotByKey[key]!.sorted { $0.ordinalInApp < $1.ordinalInApp }
            let liveGroup = liveByKey[key] ?? []
            for (position, entry) in entries.enumerated() {
                guard position < liveGroup.count else {
                    leftoverEntries.append(entry)
                    continue
                }
                claimedLive.insert(liveGroup[position])
                decide(entry: entry, liveWindow: identityLive[liveGroup[position]], matchedBy: "identity")
            }
        }
        for entry in remainingEntries {
            if case .ordinal = entry.identity { leftoverEntries.append(entry) }
        }

        // PHASE 1c — what identity could not pair, per app: a unique exact
        // title, then a sole remaining order-only window (FallbackMatcher).
        // An entry left over while its app still has unclaimed live windows
        // is unidentified, not missing — the window may well be open; PixlPut
        // just can't tell which one it is, so it leaves them all alone.
        let liveLeftByBundle = Dictionary(
            grouping: identityLive.indices.filter { !claimedLive.contains($0) },
            by: { identityLive[$0].bundleID }
        )
        let entriesLeftByBundle = Dictionary(grouping: leftoverEntries, by: \.bundleID)
        for bundleID in entriesLeftByBundle.keys.sorted() {
            let entries = entriesLeftByBundle[bundleID]!
            let liveIndices = liveLeftByBundle[bundleID] ?? []
            let pairs = FallbackMatcher.pair(
                saved: entries.map { FallbackMatcher.Candidate(title: $0.title, identity: $0.identity) },
                live: liveIndices.map {
                    FallbackMatcher.Candidate(title: identityLive[$0].title, identity: identityLive[$0].identity)
                }
            )
            var pairedEntries: Set<Int> = []
            for pair in pairs {
                pairedEntries.insert(pair.saved)
                decide(entry: entries[pair.saved],
                       liveWindow: identityLive[liveIndices[pair.live]],
                       matchedBy: pair.reason.rawValue)
            }
            let liveUnclaimed = liveIndices.count - pairs.count
            for (index, entry) in entries.enumerated() where !pairedEntries.contains(index) {
                if liveUnclaimed > 0 {
                    skippedUnidentified += 1
                    DiagnosticLog.write("restore", """
                        decide: SKIP-UNIDENTIFIED bundle=\(entry.bundleID) identity=\(entry.identity) \
                        savedLeft=\(entries.count - pairs.count) liveLeft=\(liveUnclaimed) \
                        snapshotSpaceIndex=\(entry.spaceIndex) — no unique title or sole window to tell them apart
                        """)
                } else {
                    skippedMissingWindow += 1
                    DiagnosticLog.write("restore", """
                        decide: SKIP-MISSING bundle=\(entry.bundleID) \
                        identity=\(entry.identity) snapshotOrdinal=\(entry.ordinalInApp) \
                        targetFrame=(\(entry.frame.x),\(entry.frame.y),\
                        \(entry.frame.width)x\(entry.frame.height)) \
                        snapshotSpaceIndex=\(entry.spaceIndex)
                        """)
                }
            }
        }

        // PHASE 2 — Execute concurrently. AX moves are serialized at the
        // AXClient queue level, but the verify-with-retry sleeps inside
        // each move() release the queue, so concurrent invocations
        // interleave their AX work. Net effect: N moves take ~max(per-move
        // time) instead of N × per-move time. Empirically drops a Space-
        // switch with 6 movers from ~5s to ~1s.
        let backendRef = self.backend
        let outcomes: [MoveOutcome] = await withTaskGroup(of: MoveOutcome.self) { group in
            for action in pendingActions {
                group.addTask {
                    do {
                        switch action.kind {
                        case .move(let target):
                            let didMove = try await backendRef.move(window: action.window, to: target, policy: movePolicy)
                            DiagnosticLog.write("restore",
                                "decide: MOVE bundle=\(action.bundleID) didMove=\(didMove)")
                            return didMove ? .moved : .cancelled
                        case .moveDisplaced(let target):
                            let didMove = try await backendRef.move(window: action.window, to: target, policy: movePolicy)
                            DiagnosticLog.write("restore",
                                "decide: MOVE-DISPLACED bundle=\(action.bundleID) didMove=\(didMove)")
                            return didMove ? .movedDisplaced : .cancelledDisplaced
                        case .fullscreen(let display):
                            let ok = try await backendRef.setFullscreen(window: action.window, on: display)
                            DiagnosticLog.write("restore",
                                "decide: SET-FULLSCREEN bundle=\(action.bundleID) ok=\(ok)")
                            return ok ? .fullscreenSucceeded : .fullscreenCancelled
                        }
                    } catch {
                        let label: String = {
                            switch action.kind {
                            case .move: return "MOVE-ERROR"
                            case .moveDisplaced: return "MOVE-DISPLACED-ERROR"
                            case .fullscreen: return "SET-FULLSCREEN-ERROR"
                            }
                        }()
                        DiagnosticLog.write("restore",
                            "decide: \(label) bundle=\(action.bundleID) error=\(error) — continuing")
                        return .errored
                    }
                }
            }
            var collected: [MoveOutcome] = []
            collected.reserveCapacity(pendingActions.count)
            for await result in group { collected.append(result) }
            return collected
        }

        // PHASE 3 — Tally outcomes back into the report counters.
        for outcome in outcomes {
            switch outcome {
            case .moved:                   moved += 1
            case .cancelled:               cancelledByUserInteraction += 1
            case .movedDisplaced:          moved += 1
            case .cancelledDisplaced:      cancelledByUserInteraction += 1
            case .fullscreenSucceeded:     fullscreenSucceeded += 1; moved += 1
            case .fullscreenCancelled:     cancelledByUserInteraction += 1
            case .errored:                 errored += 1
            }
        }

        // `space=` and `entries=` so the log answers "which Space did this act
        // on, and did every entry land somewhere" without cross-referencing the
        // config files. Their absence turned a one-line question into a
        // multi-step investigation on 2026-08-13.
        //
        // `errored` used to increment nothing, so a failed move silently
        // vanished from the totals and they no longer summed to `entries`.
        let accounted = moved + skippedAlreadyAtFrame + skippedMissingWindow + skippedUnidentified
            + cancelledByUserInteraction + errored
        DiagnosticLog.write("restore", """
            apply done: space=\(onlySpaceIndex.map(String.init) ?? "all") \
            entries=\(entriesToConsider.count) accounted=\(accounted) \
            moved=\(moved) skippedAlreadyAtFrame=\(skippedAlreadyAtFrame) \
            skippedMissingWindow=\(skippedMissingWindow) skippedUnidentified=\(skippedUnidentified) \
            displacedNoMatchingDisplay=\(displacedNoMatchingDisplay) \
            cancelledByUserInteraction=\(cancelledByUserInteraction) errored=\(errored) \
            fullscreenAttempts=\(fullscreenAttempts) fullscreenSucceeded=\(fullscreenSucceeded)\
            \(accounted == entriesToConsider.count ? "" : "  !! UNACCOUNTED=\(entriesToConsider.count - accounted)")
            """)

        return RestoreReport(
            moved: moved,
            skippedAlreadyAtFrame: skippedAlreadyAtFrame,
            skippedMissingWindow: skippedMissingWindow,
            skippedUnidentified: skippedUnidentified,
            displacedNoMatchingDisplay: displacedNoMatchingDisplay,
            cancelledByUserInteraction: cancelledByUserInteraction,
            fullscreenAttempts: fullscreenAttempts,
            fullscreenSucceeded: fullscreenSucceeded
        )
    }
}
