import Foundation
import AppKit

/// Orchestrates `capture()` — walks every visible window via `AXClient`,
/// invokes `DeepIdentityFetcher` once per scripted bundle, resolves identity
/// via `WindowIdentityResolver`, builds a `Snapshot`, and hands it to
/// `SnapshotStore` for persistence.
///
/// `capture()` must complete in ≤ 500 ms wall clock for 100 windows on
/// Apple Silicon (spec SC-003 inner budget + project constitution §VII).
/// The capture loop avoids per-window allocations beyond the resulting
/// `WindowEntry` values themselves, and the per-app AppleScript fetch
/// runs ONCE per running scripted app (not per window).
public actor SnapshotEngine {

    private let axClient: AXClient
    private let store: SnapshotStore
    private let displayEnumerator: DisplayEnumerator
    private let spaceResolver: SpaceResolver
    private let resolver: WindowIdentityResolver
    private let deepIdentityFetcher: DeepIdentityFetcher

    public init(
        axClient: AXClient,
        store: SnapshotStore,
        displayEnumerator: DisplayEnumerator = DisplayEnumerator(),
        spaceResolver: SpaceResolver = SpaceResolver(),
        resolver: WindowIdentityResolver = WindowIdentityResolver.defaultV1(),
        deepIdentityFetcher: DeepIdentityFetcher = DeepIdentityFetcher()
    ) {
        self.axClient = axClient
        self.store = store
        self.displayEnumerator = displayEnumerator
        self.spaceResolver = spaceResolver
        self.resolver = resolver
        self.deepIdentityFetcher = deepIdentityFetcher
    }

    /// Capture the current arrangement. The returned snapshot is also
    /// written to disk via `SnapshotStore` UNLESS the corruption guard
    /// (described below) refuses the save.
    ///
    /// **Corruption guard**: if the previous snapshot for this display
    /// config had ≥ 4 AX windows and the new capture has < 25% of that
    /// (i.e. AX appears to have collapsed because the display is dimming
    /// during a sleep trigger), the new snapshot is RETURNED to the caller
    /// but NOT saved. Auto-restore on next wake reads the previous good
    /// snapshot instead of the corrupted one. Manual captures bypass the
    /// guard because the user explicitly chose this moment.
    ///
    /// - Parameter useDeepIdentity: when true, batch-fetches per-bundle
    ///   deep identity (browser tab sets, editor workspace paths) via
    ///   AppleScript — triggers macOS Automation permission prompts on
    ///   first use per bundle. When false, identity falls back to layer-3
    ///   (title regex) / layer-4 (ordinal) only. Default false — see
    ///   constitution §V "graceful permission degradation": PixlPut must
    ///   work as-well-as-the-permissions-allow without forcing prompts.
    @discardableResult
    public func capture(trigger: CaptureTrigger, useDeepIdentity: Bool = false) async throws -> Snapshot {
        let displays = displayEnumerator.enumerate()
        let configID = DisplayConfigurationID.compute(from: displays.map(\.fingerprint))
        let displayUUIDByFingerprintID = Dictionary(uniqueKeysWithValues:
            displays.compactMap { d -> (String, String)? in
                guard let uuid = d.fingerprint.displayUUID else { return nil }
                return (d.fingerprint.id, uuid)
            }
        )

        // ENUMERATE, THEN SETTLE ON WHICH SPACE THESE WINDOWS BELONG TO.
        //
        // AX lags a Space switch. For a moment after you arrive it still reports
        // the ORIGIN Space's windows while the managed display already reports
        // the destination — observed three times on 2026-08-12/13, always as
        // "display says 4, windows on 3", and twice for the same Desktop. It is
        // a lag, not a coin flip: nine seconds later the same display value was
        // accepted because the windows had caught up.
        //
        // With storage keyed per Space, saving that mismatch would overwrite a
        // different Space's config. So rather than trusting either source, or
        // refusing outright and making the user retry by hand, re-enumerate
        // until the two agree. Only windows belonging to exactly ONE Space may
        // vote — a sticky "all Desktops" window reports every Space and its
        // lowest ID masquerades as an answer.
        var axWindows: [AXWindow] = []
        var activeSpaceIndex = 0
        var settleAttempt = 0
        while true {
            settleAttempt += 1
            axWindows = try await axClient.enumerateWindows()
            activeSpaceIndex = spaceResolver.activeSpaceIndex()
            let observed = Self.modalSpaceIndex(
                of: axWindows.compactMap(\.windowID),
                resolve: { spaceResolver.unambiguousSpaceIndex(forWindowID: $0) }
            )
            // Agreement, or no window able to vote (an empty Space) — proceed.
            guard let observed, observed != activeSpaceIndex else { break }

            guard settleAttempt < Self.spaceSettleAttempts else {
                DiagnosticLog.write("capture", """
                    REFUSE-SAVE: Space still disagreeing after \(settleAttempt) attempts \
                    over \(Int(Double(settleAttempt - 1) * Self.spaceSettleDelaySeconds * 1000))ms. \
                    Managed display says space \(activeSpaceIndex), windows are on \(observed). \
                    Writing either would overwrite a good config. trigger=\(trigger)
                    """)
                throw CaptureError.spaceChangedDuringCapture(reported: activeSpaceIndex,
                                                             observed: observed)
            }
            DiagnosticLog.write("capture", """
                SETTLING: display says space \(activeSpaceIndex) but windows are on \(observed) \
                — AX has not caught up with the Space switch. Re-enumerating \
                (attempt \(settleAttempt)/\(Self.spaceSettleAttempts)).
                """)
            try? await Task.sleep(nanoseconds: UInt64(Self.spaceSettleDelaySeconds * 1_000_000_000))
        }
        let capturedAt = Date()

        // Batch deep-identity fetch — only when explicitly enabled.
        // One AppleScript per scripted bundle that has at least one window.
        var deepByBundle: [String: [Int: WindowIdentity]] = [:]
        if useDeepIdentity {
            let scriptedBundleIDs = Set(axWindows.map(\.bundleID))
                .filter { ScriptRegistry.script(forBundleID: $0) != nil }
            for bundleID in scriptedBundleIDs {
                if let result = await deepIdentityFetcher.identitiesForApp(bundleID: bundleID) {
                    deepByBundle[bundleID] = result
                }
            }
        }

        var entries: [WindowEntry] = []
        entries.reserveCapacity(axWindows.count)

        // Track which (bundleID, frame-origin) combinations we've already
        // emitted from AX so later dedupe can skip them. AX windows are all on
        // the active Space, so attributing them to `activeSpaceIndex` is correct.
        var emittedAXFingerprints: Set<String> = []

        for axWindow in axWindows {
            // Attributes were pre-fetched on the AX queue inside
            // `enumerateWindows()`; this loop must NOT issue any AX call.
            guard let frame = axWindow.frame else { continue }

            // Bundle blocklist — these are never user windows. The login
            // window in particular shows up at full-display dimensions
            // when the screen is locked, so the size filter below won't
            // catch it.
            if Self.bundleBlocklist.contains(axWindow.bundleID) { continue }

            // Reject windows with zero or sub-real dimensions. macOS
            // sometimes hands AX a "Finder" window with frame
            // (0,2160,0×0) during screen-saver fade / display dim —
            // capturing that would overwrite a good snapshot with a
            // bogus target frame that, on restore, moves the real
            // Finder to (0, 2160) and squishes it to nothing.
            if frame.width < 100 || frame.height < 100 { continue }

            // Identify which display this window is on by bounds intersection.
            let displayFingerprintID = displays
                .max(by: { intersectionArea($0.bounds, frame) < intersectionArea($1.bounds, frame) })?
                .fingerprint.id ?? (displays.first?.fingerprint.id ?? "")

            // Per-app deep identity, if available for this bundle/window.
            let appProviderIdentity = deepByBundle[axWindow.bundleID]?[axWindow.indexInApp]

            let signal = WindowSignal(
                bundleID: axWindow.bundleID,
                title: axWindow.title,
                documentURL: axWindow.documentURL,
                appProviderIdentity: appProviderIdentity,
                creationOrdinal: axWindow.creationOrdinal
            )
            let identity = resolver.resolve(signal)

            entries.append(WindowEntry(
                bundleID: axWindow.bundleID,
                identity: identity,
                ordinalInApp: axWindow.creationOrdinal,
                displayFingerprintID: displayFingerprintID,
                spaceIndex: activeSpaceIndex,
                frame: frame,
                isMinimized: axWindow.isMinimized,
                isFullscreen: axWindow.isFullscreen,
                capturedAt: capturedAt,
                windowID: axWindow.windowID
            ))
            emittedAXFingerprints.insert(Self.dedupeKey(bundleID: axWindow.bundleID, frame: frame))

            DiagnosticLog.write("capture", """
                AX entry: bundle=\(axWindow.bundleID) ordinal=\(axWindow.creationOrdinal) \
                title='\(axWindow.title)' \
                frame=(\(frame.x),\(frame.y),\(frame.width)x\(frame.height)) \
                spaceIndex=\(activeSpaceIndex) \
                identity=\(identity) \
                isFullscreen=\(axWindow.isFullscreen) \
                isMinimized=\(axWindow.isMinimized)
                """)
        }

        // NO CROSS-SPACE PASS. A capture records exactly the Space it is
        // standing on, and storage is keyed per Space (SnapshotStore), so the
        // other Spaces' configs are left untouched rather than guessed at.
        //
        // The removed CG pass existed to fill in Spaces AX cannot see. It did
        // cover them, but only with `.ordinal(windowID)` identity, because CG
        // exposes no document URL or tab set and `kCGWindowName` is gated
        // behind Screen Recording (measured: 0 of 88 titles readable). That
        // placeholder identity is unusable for matching after an app restart
        // and is skipped outright by per-window relocation planning — so the
        // pass bought coverage at the cost of every entry's identity, and
        // forced a wholesale-replace/additive-merge dilemma on the store.
        //
        // Per-Space files dissolve all of it: each entry here comes from the AX
        // pass while its Space was active, so every entry carries full deep
        // identity, and a window moved between Spaces needs no reconciliation
        // (re-capturing the source Space rewrites it from what is there now).
        _ = displayUUIDByFingerprintID
        DiagnosticLog.write("capture", """
            capture done: trigger=\(trigger) spaceIndex=\(activeSpaceIndex) \
            windows=\(entries.count) isSpaceAware=\(self.spaceResolver.isSpaceAware)
            """)

        // CORRUPTION GUARD: an auto-capture that fires AFTER the display
        // has dimmed will collect almost no AX windows (the AX hierarchy
        // collapses with the display). If we save that snapshot we'd
        // overwrite the good user arrangement with garbage. Compare the
        // new AX count to the previous good snapshot for the same display
        // config. Only applies to AUTO triggers (the user manually chose
        // a `.manual` trigger, trust that intent).
        let isAutoTrigger = (trigger != .manual)
        let newAXCount = emittedAXFingerprints.count
        let previousSnapshot = try? store.loadLatest(forConfigurationID: configID,
                                                     spaceIndex: activeSpaceIndex)

        // ABSOLUTE REFUSAL: an auto-capture with zero windows is never
        // legitimate — it's always a transient AX-collapsed state during
        // screen lock / sleep / fast user switch. Refuse regardless of
        // whether a previous snapshot exists, to prevent any future load
        // path from picking up an empty snapshot.
        if isAutoTrigger && newAXCount == 0 && entries.isEmpty {
            DiagnosticLog.write("capture", """
                REFUSE-SAVE: auto-capture has zero windows. \
                trigger=\(trigger). Keeping previous snapshot (if any).
                """)
            return previousSnapshot ?? Snapshot(
                displayConfigurationID: configID, displays: displays,
                capturedAt: capturedAt, trigger: trigger, windows: entries)
        }

        if isAutoTrigger, let prev = previousSnapshot {
            // No spaceIndex filter needed: `prev` IS this Space's config.
            let prevAXCount = prev.windows.count
            // Tiny-capture rule: ≤ 1 window on an auto-trigger when prev
            // had a multi-window arrangement is always the screensaver-
            // fade pattern (Finder ghost window), never legitimate.
            //
            // The previous "drastic-shrink" rule (refuse if new < prev/2)
            // was removed because it false-positives whenever the user
            // legitimately closes apps between sessions: the next capture
            // legitimately has fewer windows than prev, but the guard
            // would freeze the snapshot for hours. The lock-state gate
            // (skip capture while locked) + bundle blocklist + zero-
            // window refusal already cover the screensaver attack
            // surface that drastic-shrink was added for.
            let tinyCapture = (newAXCount <= 1 && prevAXCount >= 2)
            if tinyCapture {
                DiagnosticLog.write("capture", """
                    REFUSE-SAVE: auto-capture would corrupt good snapshot. \
                    trigger=\(trigger) newAX=\(newAXCount) prevAX=\(prevAXCount) \
                    reason=tiny-capture. Keeping previous snapshot.
                    """)
                return prev
            }
        }

        // No merge, and no identity enrichment to carry forward. This file is
        // one Space, written from the AX pass that just ran on that Space, so
        // `entries` is already both complete and strongly identified. The
        // previous snapshot is consulted only by the corruption guards above.
        let snapshot = Snapshot(
            displayConfigurationID: configID,
            displays: displays,
            capturedAt: capturedAt,
            trigger: trigger,
            windows: entries
        )

        // CHANGE GUARD: if the new snapshot has the exact same set of
        // windows at the same frames as the previous one, skip the save.
        // Avoids burning a history slot on every Space-switch when the
        // user isn't actually moving anything (the common case during
        // normal work — they just navigate between Spaces).
        if let prev = previousSnapshot,
           Self.snapshotsAreEquivalent(prev.windows, entries) {
            DiagnosticLog.write("capture", """
                SKIP-SAVE: snapshot unchanged since last capture. \
                trigger=\(trigger) spaceIndex=\(activeSpaceIndex) windows=\(entries.count). \
                Keeping previous snapshot.
                """)
            return prev
        }

        try store.save(snapshot, spaceIndex: activeSpaceIndex)
        return snapshot
    }

    /// How many times to re-enumerate when AX and the managed display disagree
    /// about which Space we are on, and how long to wait between attempts.
    /// Worst case adds ~750ms, and only on a capture taken mid-transition; an
    /// agreeing first pass costs nothing.
    static let spaceSettleAttempts = 4
    static let spaceSettleDelaySeconds = 0.25

    public enum CaptureError: Error, Equatable {
        /// The Space changed while the capture was being taken, so the window
        /// data and the Space index describe different Spaces. Retrying once the
        /// transition settles is the fix; the caller should say so.
        case spaceChangedDuringCapture(reported: Int, observed: Int)
    }

    /// The Space index most of `windowIDs` sit on, or `nil` when none of them
    /// can be resolved to a Space.
    ///
    /// Ties break toward the lowest index so the answer is deterministic rather
    /// than dependent on dictionary ordering. A tie means the window server is
    /// mid-transition and either answer is defensible; what matters is that the
    /// same input always produces the same file.
    static func modalSpaceIndex(
        of windowIDs: [CGWindowID],
        resolve: (CGWindowID) -> Int?
    ) -> Int? {
        var counts: [Int: Int] = [:]
        for id in windowIDs {
            guard let index = resolve(id) else { continue }
            counts[index, default: 0] += 1
        }
        return counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .first?.key
    }

    /// Bundles that should never appear in a snapshot. These are system
    /// surfaces (lock screen, screensaver, fast-user-switching, TCC
    /// permission dialogs, the System Settings window) and PixlPut's own
    /// process. None of them are user-positionable layout windows, and
    /// capturing them just pollutes the snapshot — observed in the wild
    /// as dozens of stale duplicate entries for `co.cerebraljuice.pixlput`
    /// and `com.apple.accessibility.universalAccessAuthWarn` accumulating
    /// across captures, then surviving the merge dedupe because no later
    /// capture matched their keys.
    private static let bundleBlocklist: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.ScreenSaver.Engine",
        "com.apple.ScreenSaverEngine",
        "com.apple.WindowManager",
        "com.apple.systempreferences",
        "com.apple.accessibility.universalAccessAuthWarn",
        "com.apple.SecurityAgent",
        "com.apple.coreservices.uiagent",
        "co.cerebraljuice.pixlput",
        // System UI surfaces, not user windows. Notification Center in
        // particular puts 2 full-size windows on EVERY Space; captured, they
        // outvote real windows in Space planning (measured: 12 of the 38
        // displaced windows in the 2026-08-04 dry run) and pad every restore.
        "com.apple.notificationcenterui",
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.PasswordManagerAutoFillAgent",
        "com.apple.WindowServer",
    ]

    /// Stable dedupe key for "same window appears in both AX and CG passes".
    /// Bundle ID + integer-rounded frame is sufficient: a window has the
    /// same frame whether you read it from AX or CG.
    private static func dedupeKey(bundleID: String, frame: CGRectCodable) -> String {
        "\(bundleID)@\(Int(frame.x)),\(Int(frame.y)),\(Int(frame.width))x\(Int(frame.height))"
    }

    /// Tolerance used by `snapshotsAreEquivalent` when comparing frames.
    /// Matches the Restorer's idempotence tolerance — a 1pt drift isn't
    /// a real change.
    private static let equivalenceFrameTolerance: CGFloat = 1.0

    /// Equivalence key for the change guard. windowID-first: identity
    /// enrichment can upgrade an entry's identity between two captures of
    /// the SAME physical window, and that must not read as a layout change.
    /// Space stays in the key — the same window on a different Space IS a
    /// change. Composite fallback for entries without a windowID.
    private static func equivalenceKey(_ entry: WindowEntry) -> String {
        if let wid = entry.windowID { return "w\(wid)|\(entry.spaceIndex)" }
        return "\(entry.spaceIndex)|\(entry.bundleID)|\(entry.identity)|\(entry.ordinalInApp)"
    }

    /// True when two window sets describe the same logical layout:
    ///  - Same set of `equivalenceKey`s (windowID+Space, or composite).
    ///  - Each matched pair has frames within `equivalenceFrameTolerance`.
    ///  - `isFullscreen` and `isMinimized` match.
    ///
    /// Used to skip saves when nothing has actually changed since the
    /// last capture — auto-captures that fire on Space-switch shouldn't
    /// burn history slots when the user is just navigating, not moving
    /// windows.
    private static func snapshotsAreEquivalent(
        _ a: [WindowEntry], _ b: [WindowEntry]
    ) -> Bool {
        guard a.count == b.count else { return false }
        // Build keyed lookup of b. Use last-write-wins on collision —
        // safer than trapping when an older corrupted snapshot has
        // duplicates dedupe didn't catch.
        var bByKey: [String: WindowEntry] = [:]
        for entry in b { bByKey[Self.equivalenceKey(entry)] = entry }
        for entry in a {
            let key = Self.equivalenceKey(entry)
            guard let bMatch = bByKey.removeValue(forKey: key) else { return false }
            if entry.isFullscreen != bMatch.isFullscreen { return false }
            if entry.isMinimized != bMatch.isMinimized { return false }
            let f1 = entry.frame, f2 = bMatch.frame
            if abs(f1.x - f2.x) > equivalenceFrameTolerance { return false }
            if abs(f1.y - f2.y) > equivalenceFrameTolerance { return false }
            if abs(f1.width - f2.width) > equivalenceFrameTolerance { return false }
            if abs(f1.height - f2.height) > equivalenceFrameTolerance { return false }
        }
        return bByKey.isEmpty
    }

    private func intersectionArea(_ a: CGRectCodable, _ b: CGRectCodable) -> CGFloat {
        let intersection = a.cgRect.intersection(b.cgRect)
        if intersection.isNull || intersection.isEmpty { return 0 }
        return intersection.width * intersection.height
    }
}
