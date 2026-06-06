import Foundation

/// Layer-2 provider for Xcode (`com.apple.dt.Xcode`). Identity is the
/// absolute path of the open workspace / project document.
///
/// AppleScript dictionary path: `path of document of windows` — handled
/// by `DeepIdentityFetcher`'s `xcode()` script. This file is the
/// data-transform layer (path string → `WindowIdentity.editorWorkspace`),
/// kept symmetric with the other providers.
public struct XcodeProvider: Sendable {
    public static let supportedBundleIDs: Set<String> = ["com.apple.dt.Xcode"]

    public init() {}

    public func identity(fromWorkspacePath path: String) -> WindowIdentity? {
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return .editorWorkspace(url)
    }

    public func supports(bundleID: String) -> Bool {
        Self.supportedBundleIDs.contains(bundleID)
    }
}
