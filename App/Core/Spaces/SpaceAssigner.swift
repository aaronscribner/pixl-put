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

        public init(bundleID: String, targetSpaceIndex: Int, applied: Bool, failureReason: String? = nil) {
            self.bundleID = bundleID
            self.targetSpaceIndex = targetSpaceIndex
            self.applied = applied
            self.failureReason = failureReason
        }
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
    /// skipped — there is no window to move.
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

            _ = backend.assign(pid: pid,
                               toSpaceIndex: assignment.targetSpaceIndex,
                               displayUUID: displayUUID)

            let landed = verify(pid: pid, reachedSpaceID: spaceID)
            return Outcome(bundleID: assignment.bundleID,
                           targetSpaceIndex: assignment.targetSpaceIndex,
                           applied: landed,
                           failureReason: landed ? nil : "assignment did not take effect")
        }
    }

    /// Poll until at least one of the process's windows reports the target
    /// Space. Reading one window is sufficient: the assignment is process-wide,
    /// so the whole app moves or none of it does.
    private func verify(pid: pid_t, reachedSpaceID spaceID: PrivateCGS.CGSSpaceID) -> Bool {
        let windowIDs = CGWindowEnumerator.enumerateAllWindows()
            .filter { $0.ownerPID == pid }
            .map(\.windowID)
        // No enumerable windows: nothing to verify against. The assignment is
        // still recorded on the process and will apply to windows it opens
        // later, so this is not a failure.
        guard let probe = windowIDs.first else { return true }

        let deadline = Date().addingTimeInterval(verifyTimeout)
        while Date() < deadline {
            if PrivateCGS.spaces(forWindow: probe).contains(spaceID) { return true }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return PrivateCGS.spaces(forWindow: probe).contains(spaceID)
    }
}
