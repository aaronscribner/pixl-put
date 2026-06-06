import Foundation

/// Layer-2 provider for browsers. Computes an identity from the set of tab
/// URLs in the window. v1 ships Brave only — other Chromium-family browsers
/// (Edge, Chrome, Arc, Vivaldi) share Brave's AppleScript dictionary and
/// can be added by registering their bundle IDs in `supportedBundleIDs`.
///
/// This provider does NOT execute AppleScript directly — that side-effect is
/// the caller's responsibility (typically the capture loop, which runs on
/// the AX dispatch queue). This file provides the deterministic parsing /
/// identity-construction logic that is unit-testable in isolation.
public struct BrowserTabSetProvider: Sendable {
    /// Bundle IDs whose AppleScript dictionary matches Brave's "windows /
    /// tabs / URL" hierarchy. Adding a new bundle here is the documented
    /// extension point (project constitution §II).
    public static let supportedBundleIDs: Set<String> = [
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.google.Chrome",
        "company.thebrowser.Browser",   // Arc
        "com.apple.Safari",
    ]

    public init() {}

    /// Build a `WindowIdentity` from a list of tab URLs.
    /// Stability rules per spec Story-3 acceptance #1:
    ///   - Tabs are sorted lexicographically (the user's tab *order* drifts
    ///     as tabs are reordered; the *set* does not for short-lived sessions).
    ///   - Empty URL list collapses to `nil` — caller should fall back to layer 3.
    public func identity(from tabURLs: [URL]) -> WindowIdentity? {
        let normalized = tabURLs
            .map(Self.normalizeURL)
            .filter { !$0.absoluteString.isEmpty }
        guard !normalized.isEmpty else { return nil }
        let sorted = normalized.sorted { $0.absoluteString < $1.absoluteString }
        return .browserTabSet(sorted)
    }

    /// Strip URL fragments + query parameters that change frequently within
    /// a single tab (e.g. analytics IDs). Keeps origin + path.
    static func normalizeURL(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        components?.query = nil
        return components?.url ?? url
    }

    public func supports(bundleID: String) -> Bool {
        Self.supportedBundleIDs.contains(bundleID)
    }
}
