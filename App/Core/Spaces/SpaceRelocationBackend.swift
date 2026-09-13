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

    /// Install locations, most preferred first. The `yabai.app` bundle is the
    /// copy PixPut's own build installs (scripts/build-yabai.sh): built from
    /// the vendored fork and signed with the app's Developer ID so its
    /// Accessibility grant survives rebuilds. It has to be a bundle rather
    /// than a bare executable because TCC will not record an Accessibility
    /// decision for a Mach-O it cannot attribute to one. The bare paths are
    /// earlier install layouts and Homebrew's own copy, kept so an existing
    /// install still resolves.
    public static let defaultSearchPaths = [
        "/Applications/Utilities/yabai.app/Contents/MacOS/yabai",
        "/Applications/Utilities/yabai",
        "/Applications/yabai",
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

    // MARK: - Cross-Space queries and frames

    /// Every window yabai knows about, on every Space. This is the view AX
    /// cannot give: AX enumerates only the active Space's windows, which is
    /// why the per-window path used to restore one Space per visit.
    public func queryWindows() -> [YabaiWindow]? {
        let result = run(["-m", "query", "--windows"])
        guard result.exitCode == 0, let data = result.stdout.data(using: .utf8) else { return nil }
        return try? YabaiJSON.windows(from: data)
    }

    public func querySpaces() -> [YabaiSpace]? {
        let result = run(["-m", "query", "--spaces"])
        guard result.exitCode == 0, let data = result.stdout.data(using: .utf8) else { return nil }
        return try? YabaiJSON.spaces(from: data)
    }

    /// Position and size one window in global top-left coordinates — the
    /// same system AX and CoreGraphics use, so snapshot frames apply as-is.
    /// Works on any Space, which AX cannot do.
    public func setFrame(windowID: CGWindowID, frame: CGRectCodable) -> Bool {
        let id = String(windowID)
        let moved = run(["-m", "window", id, "--move",
                         "abs:\(Int(frame.x.rounded())):\(Int(frame.y.rounded()))"]).exitCode == 0
        let resized = run(["-m", "window", id, "--resize",
                           "abs:\(Int(frame.width.rounded())):\(Int(frame.height.rounded()))"]).exitCode == 0
        return moved && resized
    }

    /// Why a `--space` move can fail even though the service answers: the
    /// scripting addition is not injected into Dock.app. yabai reports it on
    /// stderr; the exit code alone cannot tell it from a bad window id.
    public func moveDiagnostic(windowID: CGWindowID, toSpaceIndex index: Int) -> String? {
        let result = run(["-m", "window", String(windowID), "--space", String(index + 1)])
        guard result.exitCode != 0 else { return nil }
        let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "yabai exit \(result.exitCode)" : text
    }

    /// Start (installing if needed) yabai's launch agent, then wait briefly
    /// for the socket. Returns whether the service answers afterwards.
    /// yabai does not come back on its own after a reboot unless its launch
    /// agent is installed; this is the in-app path to that.
    public func startService(timeout: TimeInterval = 5.0) -> Bool {
        _ = run(["--start-service"])
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isAvailable { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return isAvailable
    }

    // MARK: - Process plumbing

    private struct Result { let exitCode: Int32; let stdout: String; let stderr: String }

    private func run(_ arguments: [String]) -> Result {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return Result(exitCode: -1, stdout: "", stderr: "\(error)")
        }

        // Read before waiting: a full pipe buffer would deadlock the child.
        // stderr is read on its own thread for the same reason — a query
        // that fails can write its error while stdout is still open.
        var errData = Data()
        let errThread = Thread {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        }
        errThread.start()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            return Result(exitCode: -1, stdout: "", stderr: "timed out")
        }
        while !errThread.isFinished && Date() < deadline.addingTimeInterval(0.5) {
            Thread.sleep(forTimeInterval: 0.005)
        }
        return Result(exitCode: process.terminationStatus,
                      stdout: String(data: data, encoding: .utf8) ?? "",
                      stderr: String(data: errData, encoding: .utf8) ?? "")
    }
}

// MARK: - Selection

public enum SpaceRelocationBackendFactory {
    /// The chosen backend plus, when the per-window backend was installed
    /// but could not be used, a one-line reason for the status surface.
    public struct Selection {
        public let backend: SpaceRelocationBackend
        /// Non-nil when yabai is on disk but its service didn't answer. The
        /// fallback is silent otherwise, and on the per-app backend an app
        /// whose windows were captured across several Spaces is deliberately
        /// left alone — so a user who normally runs yabai (which does not
        /// come back on its own after a reboot) sees a restore that "does
        /// nothing" with no hint why.
        public let fallbackReason: String?
    }

    /// Prefer per-window relocation when yabai is present and answering;
    /// otherwise fall back to the always-available per-app backend.
    public static func select() -> Selection {
        if let yabai = YabaiRelocationBackend.locate() {
            if yabai.isAvailable {
                return Selection(backend: yabai, fallbackReason: nil)
            }
            return Selection(
                backend: CGSProcessRelocationBackend(),
                fallbackReason: "yabai is installed but its service isn't running, "
                    + "so windows of one app can't be split across Spaces."
            )
        }
        return Selection(backend: CGSProcessRelocationBackend(), fallbackReason: nil)
    }

    /// Backend only — see `select()` for the fallback reason.
    public static func best() -> SpaceRelocationBackend {
        select().backend
    }
}
