import Foundation

/// Layer-2 provider for VS Code (`com.microsoft.VSCode`) and forks that share
/// its title format (Cursor, VSCodium). Identity is the absolute filesystem
/// path of the open workspace folder, derived from the AX title.
///
/// VS Code title formats (observed):
///   - "<file> — <workspace> — Visual Studio Code"
///   - "<file> — <workspace> [Working Tree] — Visual Studio Code"
///   - "<workspace> — Visual Studio Code"   (no file open)
public struct VSCodeWorkspaceProvider: Sendable {
    public static let supportedBundleIDs: Set<String> = [
        "com.microsoft.VSCode",
        // v1.1 candidates:
        // "com.todesktop.230313mzl4w4u92",   // Cursor
        // "com.vscodium",
    ]

    public init() {}

    /// Extract workspace name from the title. The full absolute path is
    /// obtained at capture time via ScriptingBridge; this method handles
    /// the title-derived fallback when ScriptingBridge fails or is denied.
    public func workspaceName(fromTitle title: String) -> String? {
        let stripped = title.replacingOccurrences(
            of: " — Visual Studio Code", with: ""
        )
        // Strip trailing "[Working Tree]" or similar git decorations.
        let cleaned = stripped.replacingOccurrences(
            of: #"\s*\[[^\]]+\]\s*$"#,
            with: "",
            options: .regularExpression
        )
        // Last em-dash-separated segment is the workspace name; if no dash,
        // the whole string is the workspace.
        let segments = cleaned.components(separatedBy: " — ")
        return segments.last?.trimmingCharacters(in: .whitespaces)
    }

    /// Construct the identity from an absolute workspace folder path.
    public func identity(fromWorkspaceURL url: URL) -> WindowIdentity? {
        guard url.isFileURL else { return nil }
        return .editorWorkspace(url.standardizedFileURL)
    }

    public func supports(bundleID: String) -> Bool {
        Self.supportedBundleIDs.contains(bundleID)
    }
}
