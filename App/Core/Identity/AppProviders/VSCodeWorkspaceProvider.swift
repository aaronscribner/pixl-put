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
    /// The app name each editor appends to its window title. Forks keep VS
    /// Code's title format and change only this suffix.
    public static let titleSuffixByBundleID: [String: String] = [
        "com.microsoft.VSCode": "Visual Studio Code",
        "com.microsoft.VSCodeInsiders": "Visual Studio Code - Insiders",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.vscodium": "VSCodium",
        "com.exafunction.windsurf": "Windsurf",
    ]

    public static let supportedBundleIDs: Set<String> = Set(titleSuffixByBundleID.keys)

    public init() {}

    /// Workspace name for any supported editor. VS Code keeps its original,
    /// lenient parse. Forks require their own suffix: without it the last
    /// title segment could be the app name itself, which would give every
    /// window of the fork one shared identity — `nil` falls through to the
    /// order-only rules instead.
    public func workspaceName(fromTitle title: String, bundleID: String) -> String? {
        if bundleID == "com.microsoft.VSCode" { return workspaceName(fromTitle: title) }
        guard let appName = Self.titleSuffixByBundleID[bundleID] else { return nil }
        let suffix = " — \(appName)"
        guard title.hasSuffix(suffix) else { return nil }
        let name = workspaceName(fromStrippedTitle: String(title.dropLast(suffix.count)))
        return name?.isEmpty == false ? name : nil
    }

    /// Extract workspace name from the title. The full absolute path is
    /// obtained at capture time via ScriptingBridge; this method handles
    /// the title-derived fallback when ScriptingBridge fails or is denied.
    public func workspaceName(fromTitle title: String) -> String? {
        workspaceName(fromStrippedTitle: title.replacingOccurrences(
            of: " — Visual Studio Code", with: ""
        ))
    }

    /// The title with the app-name suffix already removed.
    private func workspaceName(fromStrippedTitle stripped: String) -> String? {
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
