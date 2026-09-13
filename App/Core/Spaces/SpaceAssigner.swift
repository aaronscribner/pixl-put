import Foundation
import CoreGraphics
import AppKit

/// Applies a `SpaceAssignmentPlanner.Plan` to the running system (ADR-0002).
///
/// Every assignment is **verified by re-reading** the window's Space, because
/// `CGSProcessAssignToSpace` returns void and reports nothing about whether it
/// took effect — the same discipline `Restorer` uses for AX frame setting,
/// which silently clamps.
public struct SpaceAssigner: Sendable {

    public struct Outcome: Equatable, Sendable {
        public let bundleID: String
        public let targetSpaceIndex: Int
        public let applied: Bool
        /// Why it didn't apply, for the diagnostic log. `nil` on success.
        public let failureReason: String?
        /// Every Space-reporting window of the app was already on the target
        /// before anything was asked of the window server, so no assignment
        /// was issued. Counted separately from a real move: "restored 14
        /// apps" when 14 were already in place reads as a restore that did
        /// nothing, and issuing the (sticky, process-lifetime) assignment
        /// anyway would pin an app that never needed moving.
        public let alreadyOnTarget: Bool

        public init(
            bundleID: String,
            targetSpaceIndex: Int,
            applied: Bool,
            failureReason: String? = nil,
            alreadyOnTarget: Bool = false
        ) {
            self.bundleID = bundleID
            self.targetSpaceIndex = targetSpaceIndex
            self.applied = applied
            self.failureReason = failureReason
            self.alreadyOnTarget = alreadyOnTarget
        }
    }

    /// Where an app's windows stand relative to a target Space, judged only
    /// from windows that report exactly one Space. Windows reporting none
    /// (unmapped helpers, panels mid-teardown) or several (sticky "all
    /// Desktops" windows) carry no information about the app's placement and
    /// are excluded from the judgement rather than allowed to decide it.
    public enum Placement: Equatable, Sendable {
        /// No window of the app reports a single Space — nothing to judge by.
        case unknown
        /// Every reporting window is on the target.
        case all
        /// At least one reporting window is on the target, at least one is not.
        case some
        /// Reporting windows exist and none is on the target.
        case none
    }

    /// Pure judgement over per-window Space lists, split out so the rule can
    /// be unit-tested without a window server.
    ///
    /// The previous implementation probed **only the app's first CG window**.
    /// Measured 2026-09-10 on the target machine: for 7 of 22 running apps
    /// (VS Code, Finder, Claude, Spark, qBittorrent, RDC, 1Password) that
    /// first window is an off-screen helper that reports no Space at all, so
    /// verification could never succeed for them and every restore reported
    /// "assignment did not take effect" for apps that had in fact moved.
    public static func placement(windowSpaces: [[UInt64]],
                                 target: UInt64) -> Placement {
        let reporting = windowSpaces.filter { $0.count == 1 }
        guard !reporting.isEmpty else { return .unknown }
        let onTarget = reporting.filter { $0[0] == target }.count
        if onTarget == reporting.count { return .all }
        if onTarget == 0 { return .none }
        return .some
    }

    /// How long to wait for the window server to reflect an assignment.
    /// Measured at 2–4 ms on macOS 26.2; 750 ms is generous headroom.
    private let verifyTimeout: TimeInterval
    private let pollInterval: TimeInterval

    private let backend: SpaceRelocationBackend

    public init(
        backend: SpaceRelocationBackend = CGSProcessRelocationBackend(),
        verifyTimeout: TimeInterval = 0.75,
        pollInterval: TimeInterval = 0.02
    ) {
        self.backend = backend
        self.verifyTimeout = verifyTimeout
        self.pollInterval = pollInterval
    }

    public var isAvailable: Bool { backend.isAvailable }
    public var supportsPerWindowMoves: Bool { backend.supportsPerWindowMoves }
    public var backendName: String { backend.name }

    /// Apply per-window moves. Each is verified by re-reading the window's
    /// Space rather than trusting the backend's exit status.
    /// Returns the moves that did NOT land.
    public func applyPerWindow(
        _ moves: [SpaceAssignmentPlanner.WindowMove],
        displayUUID: String? = nil
    ) -> [SpaceAssignmentPlanner.WindowMove] {
        moves.filter { move in
            guard backend.move(windowID: move.windowID, toSpaceIndex: move.targetSpaceIndex) else {
                return true
            }
            guard let spaceID = PrivateCGS.spaceID(atIndex: move.targetSpaceIndex,
                                                   displayUUID: displayUUID) else {
                // Can't verify without a Space ID; trust the backend's success.
                return false
            }
            return !waitForWindow(move.windowID, toReach: spaceID)
        }
    }

    private func waitForWindow(_ windowID: CGWindowID, toReach spaceID: PrivateCGS.CGSSpaceID) -> Bool {
        let deadline = Date().addingTimeInterval(verifyTimeout)
        while Date() < deadline {
            if PrivateCGS.spaces(forWindow: windowID).contains(spaceID) { return true }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return PrivateCGS.spaces(forWindow: windowID).contains(spaceID)
    }

    /// Apply every assignment, returning one outcome per app.
    ///
    /// `displayUUID` scopes per-display Space indices; pass the display the
    /// snapshot was captured on. Apps in the plan that aren't running are
    /// skipped — there is no window to move. Apps whose windows already sit
    /// on the target are reported `alreadyOnTarget` and left untouched.
    @discardableResult
    public func apply(
        _ plan: SpaceAssignmentPlanner.Plan,
        displayUUID: String? = nil
    ) -> [Outcome] {
        guard isAvailable else {
            return plan.assignments.map {
                Outcome(bundleID: $0.bundleID, targetSpaceIndex: $0.targetSpaceIndex,
                        applied: false, failureReason: "\(backend.name) unavailable")
            }
        }

        let runningByBundle = Dictionary(
            NSWorkspace.shared.runningApplications.compactMap { app -> (String, pid_t)? in
                guard let bundleID = app.bundleIdentifier else { return nil }
                return (bundleID, app.processIdentifier)
            },
            uniquingKeysWith: { first, _ in first }
        )

        return plan.assignments.map { assignment in
            guard let pid = runningByBundle[assignment.bundleID] else {
                return Outcome(bundleID: assignment.bundleID,
                               targetSpaceIndex: assignment.targetSpaceIndex,
                               applied: false, failureReason: "app not running")
            }
            guard let spaceID = PrivateCGS.spaceID(atIndex: assignment.targetSpaceIndex,
                                                   displayUUID: displayUUID) else {
                return Outcome(bundleID: assignment.bundleID,
                               targetSpaceIndex: assignment.targetSpaceIndex,
                               applied: false,
                               failureReason: "Space index \(assignment.targetSpaceIndex) no longer exists")
            }

            let windowIDs = Self.windowIDs(ofPID: pid)

            // Already there: don't issue a sticky assignment for a no-op.
            if Self.placement(windowSpaces: windowIDs.map(PrivateCGS.spaces(forWindow:)),
                              target: spaceID) == .all {
                return Outcome(bundleID: assignment.bundleID,
                               targetSpaceIndex: assignment.targetSpaceIndex,
                               applied: true, alreadyOnTarget: true)
            }

            _ = backend.assign(pid: pid,
                               toSpaceIndex: assignment.targetSpaceIndex,
                               displayUUID: displayUUID)

            let landed = verify(windowIDs: windowIDs, reachedSpaceID: spaceID)
            return Outcome(bundleID: assignment.bundleID,
                           targetSpaceIndex: assignment.targetSpaceIndex,
                           applied: landed,
                           failureReason: landed ? nil : "assignment did not take effect")
        }
    }

    /// Layer-0 CG windows of a process — the same population the planner and
    /// the yabai backend reason about.
    private static func windowIDs(ofPID pid: pid_t) -> [CGWindowID] {
        CGWindowEnumerator.enumerateAllWindows()
            .filter { $0.ownerPID == pid }
            .map(\.windowID)
    }

    /// Poll until the process's windows report the target Space. The
    /// assignment is process-wide, so one reporting window on the target is
    /// proof the whole app moved; windows that report no Space or several
    /// are not evidence either way (see `placement`).
    private func verify(windowIDs: [CGWindowID], reachedSpaceID spaceID: PrivateCGS.CGSSpaceID) -> Bool {
        // No enumerable windows: nothing to verify against. The assignment is
        // still recorded on the process and will apply to windows it opens
        // later, so this is not a failure.
        guard !windowIDs.isEmpty else { return true }

        func read() -> Placement {
            Self.placement(windowSpaces: windowIDs.map(PrivateCGS.spaces(forWindow:)),
                           target: spaceID)
        }
        func landed(_ p: Placement) -> Bool { p == .all || p == .some }

        let deadline = Date().addingTimeInterval(verifyTimeout)
        while Date() < deadline {
            let p = read()
            if landed(p) { return true }
            // Only helper windows with no Space of their own: unverifiable,
            // and treated like the no-windows case rather than as a failure.
            if p == .unknown { return true }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        let final = read()
        return landed(final) || final == .unknown
    }
}
