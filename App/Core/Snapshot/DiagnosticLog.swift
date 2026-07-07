import Foundation

/// Plain-text diagnostic log written to a file under Application Support.
/// Bypasses unified logging (whose `.info`/`.debug` levels are suppressed
/// for third-party subsystems by default) so the user can read the trace
/// with `tail -f` or `cat`. Process-scoped truncation: every app launch
/// starts a new file so old runs don't accumulate.
///
/// Path: `~/Library/Application Support/DisplayMaid-Next/logs/diagnostic.log`
public enum DiagnosticLog {

    private static let lock = NSLock()
    private static var resolved: URL? = nil
    private static var fileHandle: FileHandle? = nil

    /// True when running inside XCTest. Unit tests exercise `Restorer` /
    /// `SnapshotEngine`, which call `write` — without this guard those writes
    /// land in the developer's LIVE diagnostic log and clobber real run
    /// history. No-op the file writes under test.
    private static let isRunningTests: Bool =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil

    public static func write(_ category: String, _ message: String) {
        if isRunningTests { return }
        lock.lock(); defer { lock.unlock() }
        let handle = ensureFile()
        let ts = isoFormatter.string(from: Date())
        let line = "\(ts) [\(category)] \(message)\n"
        if let data = line.data(using: .utf8) {
            try? handle?.write(contentsOf: data)
        }
    }

    /// Force the log file to exist immediately (creates dir + truncates).
    /// Called at app launch so `tail -f` works before the first capture.
    public static func bootstrap() {
        lock.lock(); defer { lock.unlock() }
        _ = ensureFile()
    }

    private static func ensureFile() -> FileHandle? {
        if let h = fileHandle { return h }
        let fm = FileManager.default
        let appSupport = (try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = appSupport
            .appendingPathComponent("DisplayMaid-Next", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let file = dir.appendingPathComponent("diagnostic.log")
        // Truncate at launch so each session starts fresh — easier for the
        // user to share, no week-long accumulation.
        try? "".write(to: file, atomically: true, encoding: .utf8)
        guard let handle = try? FileHandle(forWritingTo: file) else { return nil }
        try? handle.seekToEnd()
        resolved = file
        fileHandle = handle
        return handle
    }

    public static var logFilePath: String? {
        lock.lock(); defer { lock.unlock() }
        _ = ensureFile()
        return resolved?.path
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
