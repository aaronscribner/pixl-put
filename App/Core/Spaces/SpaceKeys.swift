import Foundation

/// The identity of each Space position: its Desktop's UUID, in Space order.
///
/// Snapshots are stored per Desktop, not per position, because positions shift
/// when a Desktop is added, removed or reordered. Measured 2026-09-14: a
/// Desktop was deleted and another created at position 5, so the layouts saved
/// for Spaces 5 and 6 were applied to the wrong Desktops and nothing matched. A
/// Desktop's UUID survives reboots — the Dock's per-app Desktop assignments
/// (`com.apple.spaces app-bindings`) are keyed by it.
public protocol SpaceKeying: Sendable {
    /// Desktop UUIDs in Space order, or `nil` when there is no single managed
    /// Space set or a Space reports no UUID. Callers then fall back to position.
    func orderedSpaceUUIDs() -> [String]?
}

/// The live Desktop list from the window server.
public struct LiveSpaceKeys: SpaceKeying {
    public init() {}

    public func orderedSpaceUUIDs() -> [String]? {
        PrivateCGS.managedSpaceUUIDs()
    }
}

/// A fixed Desktop list, for tests.
public struct FixedSpaceKeys: SpaceKeying {
    public let uuids: [String]?

    public init(_ uuids: [String]?) {
        self.uuids = uuids
    }

    /// `count` Desktops with deterministic UUIDs `DESKTOP-0`, `DESKTOP-1`, …
    public init(count: Int) {
        self.uuids = (0..<count).map { "DESKTOP-\($0)" }
    }

    public func orderedSpaceUUIDs() -> [String]? {
        uuids
    }
}
