import Foundation
import CoreGraphics

/// Switches the active Mission Control Space by synthesizing the user's
/// "move one Space left/right" keyboard shortcut (Ctrl+Arrow, enabled by
/// default) and polling `CGSGetActiveSpace` until the switch lands. This is
/// the approach every macOS window manager uses (research.md R-7) — it keeps
/// working as long as keyboard Space switching does, and needs no write-side
/// private symbol.
///
/// The navigation *planning* (`plan`) is pure and unit-tested; the executor
/// (`switchTo`) performs the side-effecting keystrokes + polling and is
/// validated on real hardware.
public struct SpaceSwitcher: Sendable {

    public enum Direction: Equatable, Sendable { case left, right }

    public struct Plan: Equatable, Sendable {
        public let direction: Direction
        public let steps: Int
        public init(direction: Direction, steps: Int) {
            self.direction = direction
            self.steps = steps
        }
    }

    /// Right / Left arrow virtual key codes.
    private static let rightArrowKeyCode: CGKeyCode = 124
    private static let leftArrowKeyCode: CGKeyCode = 123

    private let resolver: SpaceResolver
    /// How long to wait for one Space switch to register before giving up.
    private let perStepTimeout: TimeInterval
    /// Poll cadence while waiting for a switch to land.
    private let pollInterval: TimeInterval

    public init(
        resolver: SpaceResolver = SpaceResolver(),
        perStepTimeout: TimeInterval = 1.5,
        pollInterval: TimeInterval = 0.05
    ) {
        self.resolver = resolver
        self.perStepTimeout = perStepTimeout
        self.pollInterval = pollInterval
    }

    /// Pure: how to get from `activeSpaceID` to `targetSpaceID` within an
    /// ordered Space row. Returns a zero-step plan when already there, and
    /// `nil` when either Space isn't in the row (can't plan a route).
    public static func plan(
        orderedSpaceIDs: [UInt64],
        activeSpaceID: UInt64,
        targetSpaceID: UInt64
    ) -> Plan? {
        guard let from = orderedSpaceIDs.firstIndex(of: activeSpaceID),
              let to = orderedSpaceIDs.firstIndex(of: targetSpaceID) else {
            return nil
        }
        let delta = to - from
        if delta == 0 { return Plan(direction: .right, steps: 0) }
        return Plan(direction: delta > 0 ? .right : .left, steps: abs(delta))
    }

    /// Switch to `targetSpaceID`, stepping one Space at a time and re-planning
    /// from the observed active Space after each step (so it self-corrects if
    /// the keystroke-navigable order diverges from the CGS row order, e.g.
    /// around fullscreen Spaces). Returns `true` once the active Space equals
    /// the target, `false` if it couldn't get there (shortcut disabled,
    /// timeout, or the Space isn't reachable).
    @discardableResult
    public func switchTo(targetSpaceID: UInt64) async -> Bool {
        guard let start = resolver.currentSpaceID() else { return false }
        if start == targetSpaceID { return true }

        let ordered = resolver.orderedSpaceIDsForActiveDisplay()
        let maxIterations = max(2, ordered.count * 2)

        for _ in 0..<maxIterations {
            guard let active = resolver.currentSpaceID() else { return false }
            if active == targetSpaceID { return true }
            guard let plan = Self.plan(
                orderedSpaceIDs: ordered,
                activeSpaceID: active,
                targetSpaceID: targetSpaceID
            ), plan.steps > 0 else {
                return resolver.currentSpaceID() == targetSpaceID
            }
            sendArrow(plan.direction)
            await waitForActiveSpaceChange(from: active)
        }
        return resolver.currentSpaceID() == targetSpaceID
    }

    // MARK: - Keystroke synthesis

    private func sendArrow(_ direction: Direction) {
        let keyCode = direction == .right ? Self.rightArrowKeyCode : Self.leftArrowKeyCode
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }
        down.flags = .maskControl
        up.flags = .maskControl
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Poll until the active Space differs from `from` (the switch animated
    /// in) or `perStepTimeout` elapses.
    private func waitForActiveSpaceChange(from: UInt64) async {
        let deadlineSteps = Int((perStepTimeout / pollInterval).rounded(.up))
        let pollNanos = UInt64(pollInterval * 1_000_000_000)
        for _ in 0..<deadlineSteps {
            try? await Task.sleep(nanoseconds: pollNanos)
            if resolver.currentSpaceID() != from { return }
        }
    }
}
