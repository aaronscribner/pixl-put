import Foundation
import CoreGraphics

/// Restoration backend abstraction. The production implementation uses
/// `AXClient` from `Core/Accessibility/`; tests inject a fixture.
public protocol RestorerBackend: Sendable {
    /// Enumerate currently-resolvable windows. Each tuple matches a window
    /// in the active OS state to its current frame + identity signal.
    func enumerateLiveWindows() async throws -> [LiveWindow]
    /// Move a window to a target frame. Returns `true` if the move
    /// completed; `false` if the user was interacting with the window
    /// (FR-012 cancellation).
    func move(window: LiveWindow, to frame: CGRectCodable) async throws -> Bool
    /// Enter or exit fullscreen on the specified display.
    func setFullscreen(window: LiveWindow, on displayFingerprintID: String) async throws -> Bool
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

    public init(
        opaqueID: ObjectIdentifier? = nil,
        bundleID: String,
        identity: WindowIdentity,
        ordinalInApp: Int = 0,
        currentFrame: CGRectCodable,
        currentDisplayFingerprintID: String,
        isFullscreen: Bool
    ) {
        self.opaqueID = opaqueID
        self.bundleID = bundleID
        self.identity = identity
        self.ordinalInApp = ordinalInApp
        self.currentFrame = currentFrame
        self.currentDisplayFingerprintID = currentDisplayFingerprintID
        self.isFullscreen = isFullscreen
    }
}

/// Result of a single `Restorer.apply` invocation. Surfaces what was moved,
/// skipped, displaced, or cancelled — feeds the menu-bar "Last Restore" status.
public struct RestoreReport: Sendable, Equatable {
    public let moved: Int
    public let skippedAlreadyAtFrame: Int
    public let skippedMissingWindow: Int
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
    /// Matching algorithm (revised):
    ///   1. Group both snapshot entries and live windows by
    ///      `(bundleID, identity)` — this prevents the cross-bundle
    ///      ordinal-collision that caused windows to "disappear" on
    ///      restore in earlier builds.
    ///   2. Within each group, sort both sides by `ordinalInApp` and
    ///      pair them off — this disambiguates the legitimate same-bundle
    ///      same-identity case (e.g. two iTerm2 windows both in `~/work`).
    ///   3. Snapshot entries with no remaining live window count as
    ///      `skippedMissingWindow` (FR-011). Live windows with no
    ///      matching snapshot entry are simply left alone.
    ///   4. Each live window is consumed at most once — so no window
    ///      gets moved twice or hijacks another window's target frame.
    public func apply(
        _ snapshot: Snapshot,
        activeDisplayFingerprintIDs: Set<String>,
        currentDisplayBoundsByID: [String: CGRectCodable] = [:],
        onlySpaceIndex: Int? = nil
    ) async throws -> RestoreReport {
        let live = try await backend.enumerateLiveWindows()

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

        // Group live windows by (bundleID, identity), preserving an
        // ordinal-sorted list per key for within-group pairing.
        var liveByKey: [MatchKey: [LiveWindow]] = [:]
        for w in live {
            let key = MatchKey(bundleID: w.bundleID, identity: w.identity)
            liveByKey[key, default: []].append(w)
        }
        for (k, group) in liveByKey {
            liveByKey[k] = group.sorted { $0.ordinalInApp < $1.ordinalInApp }
        }

        // Group snapshot entries the same way.
        var snapshotByKey: [MatchKey: [WindowEntry]] = [:]
        for e in entriesToConsider {
            let key = MatchKey(bundleID: e.bundleID, identity: e.identity)
            snapshotByKey[key, default: []].append(e)
        }

        // Bundles where ordinal-identity pairing is unreliable because
        // the live ordinal-count differs from the snapshot's. Ordinal
        // identity is "Nth window of bundle X by creation order" — it
        // shifts when windows open/close in between captures, so any
        // count mismatch means the ordinal mapping doesn't survive.
        //
        // Concrete case: Bambu Studio had popup + main captured (ordinals
        // 0 and 1). User closed the popup; the main window's AX ordinal
        // becomes 0. Without this check we'd pair `snapshot[ordinal=0]`
        // (the popup's small frame) with `live[ordinal=0]` (the main
        // window) and try to shrink the main window. Skipping ordinal
        // pairs for this bundle preserves the user's current arrangement.
        var snapshotOrdinalCount: [String: Int] = [:]
        var liveOrdinalCount: [String: Int] = [:]
        for entry in entriesToConsider {
            if case .ordinal = entry.identity {
                snapshotOrdinalCount[entry.bundleID, default: 0] += 1
            }
        }
        for w in live {
            if case .ordinal = w.identity {
                liveOrdinalCount[w.bundleID, default: 0] += 1
            }
        }
        let ordinalUnreliable: Set<String> = Set(snapshotOrdinalCount.keys.filter { bundle in
            snapshotOrdinalCount[bundle] != liveOrdinalCount[bundle, default: 0]
        })

        var moved = 0
        var skippedAlreadyAtFrame = 0
        var skippedMissingWindow = 0
        var displacedNoMatchingDisplay = 0
        var cancelledByUserInteraction = 0
        var fullscreenAttempts = 0
        var fullscreenSucceeded = 0

        // For determinism, iterate snapshot entries in the original order
        // (not the dictionary's). Track per-key consumption position into
        // the live-windows list. Uses the Space-filtered list when Phase C
        // restricts to a single Space.
        var consumed: [MatchKey: Int] = [:]

        DiagnosticLog.write("restore", """
            apply begin: entries=\(entriesToConsider.count) live=\(live.count) \
            onlySpaceIndex=\(String(describing: onlySpaceIndex)) \
            activeDisplays=\(activeDisplayFingerprintIDs.count)
            """)
        for (key, liveGroup) in liveByKey {
            DiagnosticLog.write("restore", """
                live group: bundle=\(key.bundleID) identity=\(key.identity) \
                count=\(liveGroup.count) \
                ordinals=\(liveGroup.map(\.ordinalInApp).map(String.init).joined(separator: ","))
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
        for entry in entriesToConsider {
            let key = MatchKey(bundleID: entry.bundleID, identity: entry.identity)
            let liveGroup = liveByKey[key] ?? []

            let entryIndexInGroup = consumed[key, default: 0]
            consumed[key] = entryIndexInGroup + 1

            // Ordinal-identity sanity check: if the bundle's ordinal-count
            // differs between snapshot and live, we can't trust ordinal
            // mappings — they shift when windows open or close. Skip
            // those entries rather than apply potentially wrong frames.
            if case .ordinal = entry.identity, ordinalUnreliable.contains(entry.bundleID) {
                skippedMissingWindow += 1
                DiagnosticLog.write("restore", """
                    decide: SKIP-ORDINAL-MISMATCH bundle=\(entry.bundleID) \
                    identity=\(entry.identity) \
                    snapshotOrdinalCount=\(snapshotOrdinalCount[entry.bundleID] ?? 0) \
                    liveOrdinalCount=\(liveOrdinalCount[entry.bundleID] ?? 0) \
                    snapshotSpaceIndex=\(entry.spaceIndex) — count mismatch, ordinal mapping unreliable
                    """)
                continue
            }

            guard entryIndexInGroup < liveGroup.count else {
                skippedMissingWindow += 1
                DiagnosticLog.write("restore", """
                    decide: SKIP-MISSING bundle=\(entry.bundleID) \
                    identity=\(entry.identity) snapshotOrdinal=\(entry.ordinalInApp) \
                    targetFrame=(\(entry.frame.x),\(entry.frame.y),\
                    \(entry.frame.width)x\(entry.frame.height)) \
                    snapshotSpaceIndex=\(entry.spaceIndex) \
                    groupPos=\(entryIndexInGroup)/\(liveGroup.count)
                    """)
                continue
            }
            let liveWindow = liveGroup[entryIndexInGroup]
            let targetFrame = reanchoredFrame(for: entry)

            DiagnosticLog.write("restore", """
                decide: PAIR bundle=\(entry.bundleID) identity=\(entry.identity) \
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
                continue
            }

            // System surfaces we never try to move (notificationcenterui,
            // dock, WindowManager, controlcenter — see unmovableBundles).
            if Self.unmovableBundles.contains(entry.bundleID) {
                skippedMissingWindow += 1
                DiagnosticLog.write("restore", """
                    decide: SKIP-UNMOVABLE bundle=\(entry.bundleID) \
                    identity=\(entry.identity) — system-managed surface, not moving
                    """)
                continue
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
                            let didMove = try await backendRef.move(window: action.window, to: target)
                            DiagnosticLog.write("restore",
                                "decide: MOVE bundle=\(action.bundleID) didMove=\(didMove)")
                            return didMove ? .moved : .cancelled
                        case .moveDisplaced(let target):
                            let didMove = try await backendRef.move(window: action.window, to: target)
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
            case .errored:                 ()  // already logged; no counter
            }
        }

        DiagnosticLog.write("restore", """
            apply done: moved=\(moved) skippedAlreadyAtFrame=\(skippedAlreadyAtFrame) \
            skippedMissingWindow=\(skippedMissingWindow) \
            displacedNoMatchingDisplay=\(displacedNoMatchingDisplay) \
            cancelledByUserInteraction=\(cancelledByUserInteraction) \
            fullscreenAttempts=\(fullscreenAttempts) fullscreenSucceeded=\(fullscreenSucceeded)
            """)

        return RestoreReport(
            moved: moved,
            skippedAlreadyAtFrame: skippedAlreadyAtFrame,
            skippedMissingWindow: skippedMissingWindow,
            displacedNoMatchingDisplay: displacedNoMatchingDisplay,
            cancelledByUserInteraction: cancelledByUserInteraction,
            fullscreenAttempts: fullscreenAttempts,
            fullscreenSucceeded: fullscreenSucceeded
        )
    }
}
