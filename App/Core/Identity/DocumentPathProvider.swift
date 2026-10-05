import Foundation

/// Layer 1 — strongest signal. Uses the AX `kAXDocumentAttribute` value
/// already extracted into `WindowSignal.documentURL`.
public struct DocumentPathProvider: WindowIdentityProvider {
    public let layer: Int = 1

    /// Bundles whose identity must come from the workspace *title*, never the
    /// open document. VS Code, its forks and JetBrains IDEs expose `kAXDocumentAttribute` as the
    /// currently-focused FILE — which changes every time you switch tabs — so
    /// `documentPath` drifts and restore can't re-find the window. For these we
    /// return nil here and let `EditorWorkspaceTitleProvider` key on the stable
    /// workspace name from the title instead.
    private static let titleOnlyEditors: Set<String> =
        VSCodeWorkspaceProvider.supportedBundleIDs.union(JetBrainsProjectTitle.supportedBundleIDs)

    public init() {}

    public func resolve(_ signal: WindowSignal) -> WindowIdentity? {
        guard !Self.titleOnlyEditors.contains(signal.bundleID) else { return nil }
        guard let url = signal.documentURL else { return nil }
        return .documentPath(url)
    }
}
