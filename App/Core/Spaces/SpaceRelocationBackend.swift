import Foundation
import CoreGraphics

/// Pluggable actuator for moving windows between Spaces (ADR-0002).
///
/// Two implementations, differing only in granularity:
///
/// | Backend | Granularity | Requires |
/// |---|---|---|
/// | `CGSProcessRelocationBackend` | per **app** | nothing |
/// | `YabaiRelocationBackend` | per **window** | yabai running with its scripting addition |
///
/// The per-app backend exists because `CGSMoveWindowsToManagedSpace` — which
/// *is* window-scoped — is refused for windows the caller doesn't own. yabai
/// runs that same call from inside `Dock.app`, which does own them, so it gets
/// the granularity we can't reach in-process.
public protocol SpaceRelocationBackend: Sendable {
    /// Human-readable name for diagnostics and the menu-bar status line.
    var name: String { get }

    /// Whether this backend can act right now. Checked at call time, not
    /// cached: yabai can be started or stopped while PixPut is running.
    var isAvailable: Bool { get }

    /// `true` when individual windows of the same app can go to different
    /// Spaces. Drives whether the planner emits per-window moves or falls
    /// back to grouping by app.
    var supportsPerWindowMoves: Bool { get }

    /// Move one window. Only called when `supportsPerWindowMoves`.
    func move(windowID: CGWindowID, toSpaceIndex index: Int) -> Bool

    /// Assign every window of a process. The fallback granularity.
    func assign(pid: pid_t, toSpaceIndex index: Int, displayUUID: String?) -> Bool
}

// MARK: - In-process backend (always available)

/// Per-app relocation via `CGSProcessAssignToSpace`. No dependencies, but the
/// assignment is process-wide and sticky for the app's lifetime.
public struct CGSProcessRelocationBackend: SpaceRelocationBackend {
    public init() {}

    public var name: String { "macOS (per-app)" }
    public var isAvailable: Bool { PrivateCGS.canRelocateAcrossSpaces }
    public var supportsPerWindowMoves: Bool { false }

    /// Unsupported here — `CGSMoveWindowsToManagedSpace` silently ignores
    /// windows this process doesn't own, so claiming success would be a lie.
    public func move(windowID: CGWindowID, toSpaceIndex index: Int) -> Bool { false }

    public func assign(pid: pid_t, toSpaceIndex index: Int, displayUUID: String?) -> Bool {
        guard let spaceID = PrivateCGS.spaceID(atIndex: index, displayUUID: displayUUID) else {
            return false
        }
        return PrivateCGS.assignProcess(pid: pid, toSpaceID: spaceID)
    }
}

// MARK: - yabai backend (per-window)

/// Per-window relocation by shelling out to the `yabai` CLI.
///
/// PixPut supplies the identity and policy — which window belongs on which
/// Space — and yabai supplies the privileged actuator. yabai's window `id` is
/// the CoreGraphics window number, the same value `LiveWindow.windowID` holds,
/// so the two join directly with no extra matching.
///
/// Requires yabai's scripting addition (hence SIP disabled). If yabai is
/// installed but its service isn't running, `isAvailable` is false and the
/// caller falls back to the per-app backend rather than failing the restore.
public struct YabaiRelocationBackend: SpaceRelocationBackend {

    private let executableURL: URL
    private let timeout: TimeInterval

    /// Standard install locations. Homebrew on Apple Silicon uses `/opt`,
    /// Intel uses `/usr/local`.
    public static let defaultSearchPaths = [
        "/opt/homebrew/bin/yabai",
        "/usr/local/bin/yabai",
    ]

    /// Locate yabai on disk. Returns `nil` when it isn't installed.
    public static func locate(searchPaths: [String] = defaultSearchPaths) -> YabaiRelocationBackend? {
        for path in searchPaths where FileManager.default.isExecutableFile(atPath: path) {
            return YabaiRelocationBackend(executableURL: URL(fileURLWithPath: path))
        }
        return nil
    }

    public init(executableURL: URL, timeout: TimeInterval = 2.0) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    public var name: String { "yabai (per-window)" }
    public var supportsPerWindowMoves: Bool { true }

    /// Availability means the *service* answers, not merely that the binary
    /// exists — a stopped yabai leaves the binary in place but every command
    /// fails. `query --spaces` is read-only, so probing has no side effects.
    public var isAvailable: Bool {
        run(["-m", "query", "--spaces"]).exitCode == 0
    }

    public func move(windowID: CGWindowID, toSpaceIndex index: Int) -> Bool {
        // yabai space indices are 1-based and global across displays; PixPut
        // stores 0-based per-display indices.
        run(["-m", "window", String(windowID), "--space", String(index + 1)]).exitCode == 0
    }

    /// yabai has no per-process assignment. Moving every window of the app
    /// individually reaches the same end state without the sticky side effect
    /// the CGS path carries.
    public func assign(pid: pid_t, toSpaceIndex index: Int, displayUUID: String?) -> Bool {
        let windows = CGWindowEnumerator.enumerateAllWindows().filter { $0.ownerPID == pid }
        guard !windows.isEmpty else { return false }
        // Succeeds only if every window made it — a partial move is a failure
        // the caller needs to hear about.
        return windows.allSatisfy { move(windowID: $0.windowID, toSpaceIndex: index) }
    }

    // MARK: - Process plumbing

    private struct Result { let exitCode: Int32; let stdout: String }

    private func run(_ arguments: [String]) -> Result {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return Result(exitCode: -1, stdout: "")
        }

        // Read before waiting: a full pipe buffer would deadlock the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            return Result(exitCode: -1, stdout: "")
        }
        return Result(exitCode: process.terminationStatus,
                      stdout: String(data: data, encoding: .utf8) ?? "")
    }
}

// MARK: - Selection

public enum SpaceRelocationBackendFactory {
    /// Prefer per-window relocation when yabai is present and answering;
    /// otherwise fall back to the always-available per-app backend.
    public static func best() -> SpaceRelocationBackend {
        if let yabai = YabaiRelocationBackend.locate(), yabai.isAvailable {
            return yabai
        }
        return CGSProcessRelocationBackend()
    }
}
