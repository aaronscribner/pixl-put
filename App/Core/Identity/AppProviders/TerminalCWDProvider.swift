import Foundation

/// Layer-2 provider for terminals. v1 supports iTerm2 (clean AppleScript
/// dictionary exposes `path of current session of windows`).
///
/// Terminal.app, Ghostty, and Warp don't expose CWD via a usable
/// AppleScript dictionary and require lsof / process-introspection
/// workarounds — deferred to v1.1.
public struct TerminalCWDProvider: Sendable {
    public static let supportedBundleIDs: Set<String> = [
        "com.googlecode.iterm2",
        // v1.1 backlog (need lsof or proc_pidinfo paths):
        // "com.apple.Terminal",
        // "com.mitchellh.ghostty",
        // "dev.warp.Warp-Stable",
    ]

    public init() {}

    public func identity(fromCWDPath path: String) -> WindowIdentity? {
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return .terminalCWD(url)
    }

    public func supports(bundleID: String) -> Bool {
        Self.supportedBundleIDs.contains(bundleID)
    }
}
