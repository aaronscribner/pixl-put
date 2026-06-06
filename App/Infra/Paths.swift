import Foundation

/// Centralised filesystem-path resolution. The only place in the app that
/// computes paths under `~/Library/Application Support/`. All persistence
/// callers (`SnapshotStore`, `Logging`, `Settings`) route through here so
/// the layout is consistent and the project constitution §IV ("Local-only
/// data, forever") boundary is enforced at a single seam.
public struct Paths: Sendable {

    public static let appName = "DisplayMaid-Next"

    private var fileManager: FileManager { .default }

    public init() {}

    /// `~/Library/Application Support/DisplayMaid-Next/`
    public var applicationSupport: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(Paths.appName, isDirectory: true)
    }

    public var snapshots: URL {
        applicationSupport.appendingPathComponent("snapshots", isDirectory: true)
    }

    public var preferences: URL {
        applicationSupport.appendingPathComponent("preferences.json")
    }

    public var logs: URL {
        applicationSupport.appendingPathComponent("logs", isDirectory: true)
    }

    /// Create every required directory with mode 0o700. Idempotent.
    /// Safe to call on every launch.
    public func bootstrap() throws {
        let directories = [applicationSupport, snapshots, logs]
        for dir in directories {
            if !fileManager.fileExists(atPath: dir.path) {
                try fileManager.createDirectory(
                    at: dir,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
        }
    }
}
