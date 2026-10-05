import Foundation

/// Apps whose windows PixPut neither captures nor restores, because macOS
/// already puts them back.
///
/// Finder reopens its windows on their own Spaces after a restart, so a PixPut
/// restore can only get in its way; and with no AX document to identify them,
/// Finder windows matched by creation order, which a restart renumbers.
/// Decided 2026-09-13.
///
/// Enforced at every boundary: capture skips these apps, the store drops them
/// from snapshots as they are read (so snapshots captured before an app was
/// listed behave as if captured after), and the live window lists restore
/// plans against leave them out.
public enum ExcludedApps {
    public static let bundleIDs: Set<String> = ["com.apple.finder"]

    public static func contains(_ bundleID: String) -> Bool {
        bundleIDs.contains(bundleID)
    }

    /// `snapshot` without the windows of excluded apps. Returned unchanged —
    /// same id, same value — when it has none.
    public static func removing(from snapshot: Snapshot) -> Snapshot {
        let kept = snapshot.windows.filter { !contains($0.bundleID) }
        guard kept.count != snapshot.windows.count else { return snapshot }
        return Snapshot(
            id: snapshot.id,
            name: snapshot.name,
            displayConfigurationID: snapshot.displayConfigurationID,
            displays: snapshot.displays,
            capturedAt: snapshot.capturedAt,
            trigger: snapshot.trigger,
            windows: kept
        )
    }
}
