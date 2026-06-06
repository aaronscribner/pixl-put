import Foundation

/// Information about a window that providers consume to resolve identity.
/// Mirrors the AX attributes a real `AXWindow` would expose, but is plain
/// data so providers are unit-testable without live AX access.
public struct WindowSignal: Sendable, Hashable {
    public let bundleID: String
    public let title: String
    /// `kAXDocumentAttribute` value if AX exposes one (browsers, editors with documents).
    public let documentURL: URL?
    /// Per-bundle deep-identity probe result, set by per-bundle providers
    /// before the resolver is invoked. May be nil if the bundle has no
    /// per-bundle provider or Automation was denied.
    public let appProviderIdentity: WindowIdentity?
    /// Stable ordinal: index of this window among same-bundle windows by
    /// AX creation order. Used by the layer-4 fallback.
    public let creationOrdinal: Int

    public init(
        bundleID: String,
        title: String,
        documentURL: URL? = nil,
        appProviderIdentity: WindowIdentity? = nil,
        creationOrdinal: Int
    ) {
        self.bundleID = bundleID
        self.title = title
        self.documentURL = documentURL
        self.appProviderIdentity = appProviderIdentity
        self.creationOrdinal = creationOrdinal
    }
}

/// A provider attempts to resolve a `WindowIdentity` for a given signal.
/// Returns `nil` if it cannot — the resolver then tries the next provider.
/// Project constitution §II: layered order is load-bearing; never skip layers.
public protocol WindowIdentityProvider: Sendable {
    var layer: Int { get }
    func resolve(_ signal: WindowSignal) -> WindowIdentity?
}

/// Walks providers in increasing layer order; returns the first non-nil result.
/// Falls back to `ordinal(creationOrdinal)` if every layer above misses.
public struct WindowIdentityResolver: Sendable {
    public let providers: [any WindowIdentityProvider]

    public init(providers: [any WindowIdentityProvider]) {
        // Sort once at init so callers can supply providers in any order.
        self.providers = providers.sorted { $0.layer < $1.layer }
    }

    /// Default v1 resolver: DocumentPath → AppProvider passthrough →
    /// TitleRegex (per-bundle map provided externally) → Ordinal.
    public static func defaultV1(titleRegexes: [String: TitleRegexProvider.Pattern] = [:]) -> WindowIdentityResolver {
        WindowIdentityResolver(providers: [
            DocumentPathProvider(),
            AppProviderPassthrough(),
            TitleRegexProvider(perBundle: titleRegexes),
            OrdinalProvider(),
        ])
    }

    public func resolve(_ signal: WindowSignal) -> WindowIdentity {
        for provider in providers {
            if let identity = provider.resolve(signal) {
                return identity
            }
        }
        // Defence-in-depth — OrdinalProvider always resolves; this branch is unreachable
        // in practice but preserves total-function semantics.
        return .ordinal(signal.creationOrdinal)
    }
}
