import Foundation

/// Pure planning for the "Restore Spaces" command — decides which live
/// windows must be relocated to a different Space to match a saved snapshot.
/// Kept free of AX / CGS side effects so it can be unit-tested; the
/// orchestrator in `AppLifecycle` feeds it live-window facts and executes the
/// resulting relocations.
public enum SpaceRestorePlanner {

    /// Space-independent match key: bundle + identity + ordinal. Deliberately
    /// excludes `spaceIndex` (unlike the merge key) because the whole point is
    /// to match a window regardless of which Space it currently sits on.
    public static func matchKey(bundleID: String, identity: WindowIdentity, ordinalInApp: Int) -> String {
        "\(bundleID)|\(identity)|\(ordinalInApp)"
    }

    public static func matchKey(_ entry: WindowEntry) -> String {
        matchKey(bundleID: entry.bundleID, identity: entry.identity, ordinalInApp: entry.ordinalInApp)
    }

    /// Build a `matchKey -> target per-display Space index` map from a
    /// snapshot. Ordinal-only identities are EXCLUDED: matching them across an
    /// app restart (when window creation ordinals change) is unreliable, so we
    /// never relocate a window on an ordinal-only guess. A key that appears on
    /// more than one Space in the snapshot is dropped as ambiguous.
    public static func targetSpaceByKey(_ windows: [WindowEntry]) -> [String: Int] {
        var result: [String: Int] = [:]
        var ambiguous: Set<String> = []
        for entry in windows {
            if case .ordinal = entry.identity { continue }
            let key = matchKey(entry)
            if let existing = result[key], existing != entry.spaceIndex {
                ambiguous.insert(key)
            } else {
                result[key] = entry.spaceIndex
            }
        }
        for key in ambiguous { result.removeValue(forKey: key) }
        return result
    }

    /// A window that needs to move to a different Space.
    public struct Relocation: Equatable, Sendable {
        public let key: String
        public let targetSpaceIndex: Int
        public init(key: String, targetSpaceIndex: Int) {
            self.key = key
            self.targetSpaceIndex = targetSpaceIndex
        }
    }

    /// Given live windows (their match key + the Space they're currently on)
    /// and the snapshot target map, return the relocations needed — one per
    /// live window whose target Space differs from where it sits now. Live
    /// windows with no matching snapshot entry are left alone.
    public static func relocations(
        live: [(key: String, currentSpaceIndex: Int)],
        targets: [String: Int]
    ) -> [Relocation] {
        var out: [Relocation] = []
        for window in live {
            guard let target = targets[window.key] else { continue }
            if target != window.currentSpaceIndex {
                out.append(Relocation(key: window.key, targetSpaceIndex: target))
            }
        }
        return out
    }

    /// Distinct target Space indices present in a snapshot, ascending — the
    /// Spaces the frame-restoration pass needs to visit.
    public static func distinctSpaceIndices(_ windows: [WindowEntry]) -> [Int] {
        Array(Set(windows.map(\.spaceIndex))).sorted()
    }
}
