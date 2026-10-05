import Foundation

/// Layer-2 provider for VS Code and forks. Keys identity on the **workspace
/// name parsed from the window title** — the stable part — rather than the
/// open file. A VS Code window titled `classes.puml — Societal (Workspace)`
/// and later `main.swift — Societal (Workspace)` is the *same* window; both
/// resolve to workspace `Societal`, so restore keeps matching it no matter
/// which file/tab is focused.
///
/// `DocumentPathProvider` deliberately skips these bundles so this provider
/// wins. If the title can't be parsed, resolution falls through to the
/// ordinal fallback — never back to the (drifting) file path.
public struct EditorWorkspaceTitleProvider: WindowIdentityProvider {
    public let layer: Int = 2

    private let vscode = VSCodeWorkspaceProvider()

    public init() {}

    public func resolve(_ signal: WindowSignal) -> WindowIdentity? {
        if JetBrainsProjectTitle.supports(bundleID: signal.bundleID) {
            return JetBrainsProjectTitle.projectName(fromTitle: signal.title)
                .map { .titleRegex(pattern: "editor.workspace", capturedValue: $0) }
        }
        guard vscode.supports(bundleID: signal.bundleID) else { return nil }
        guard var workspace = vscode.workspaceName(fromTitle: signal.title, bundleID: signal.bundleID) else { return nil }
        // The current title format ends in " (Workspace)" — strip it so the
        // stored value is just the workspace name. Stable either way, but
        // cleaner in logs and the Snapshots inspector.
        if workspace.hasSuffix(" (Workspace)") {
            workspace = String(workspace.dropLast(" (Workspace)".count))
        }
        workspace = workspace.trimmingCharacters(in: .whitespaces)
        guard !workspace.isEmpty else { return nil }
        // The workspace name IS a value captured from the title. Two windows
        // of the same workspace share it; the open file is ignored.
        return .titleRegex(pattern: "editor.workspace", capturedValue: workspace)
    }
}

/// JetBrains IDEs title a project window `<project> – <file>` (en dash), or
/// just `<project>` with no file open. The project is the stable part, the
/// same way VS Code's workspace is.
public enum JetBrainsProjectTitle {
    public static let supportedBundleIDs: Set<String> = [
        "com.jetbrains.intellij", "com.jetbrains.intellij.ce",
        "com.jetbrains.pycharm", "com.jetbrains.pycharm.ce",
        "com.jetbrains.WebStorm", "com.jetbrains.rider", "com.jetbrains.goland",
        "com.jetbrains.CLion", "com.jetbrains.PhpStorm", "com.jetbrains.rubymine",
        "com.jetbrains.datagrip", "com.jetbrains.rustrover", "com.google.android.studio",
    ]

    public static func supports(bundleID: String) -> Bool {
        supportedBundleIDs.contains(bundleID)
    }

    public static func projectName(fromTitle title: String) -> String? {
        let project = title.components(separatedBy: " – ").first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return project.isEmpty ? nil : project
    }
}
