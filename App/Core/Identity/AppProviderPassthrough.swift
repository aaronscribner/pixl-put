import Foundation

/// Layer 2 — exposes the per-bundle deep identity already computed by an
/// app-specific provider (BrowserTabSetProvider, VSCodeWorkspaceProvider,
/// etc.) and attached to `WindowSignal.appProviderIdentity`.
///
/// Per-bundle providers run before the resolver (during the capture loop's
/// AX-attribute read), because they may need ScriptingBridge/AppleScript
/// access that's bundle-scoped. The resolver itself stays oblivious to
/// AppleScript — this passthrough is the seam.
public struct AppProviderPassthrough: WindowIdentityProvider {
    public let layer: Int = 2
    public init() {}

    public func resolve(_ signal: WindowSignal) -> WindowIdentity? {
        // Accept layer-1 and layer-2 identities. A layer-1 identity arriving
        // through this seam (a document read over AppleScript for a window AX
        // reports none for) does not skip a
        // layer: `DocumentPathProvider` already ran and found nothing. Lower
        // layers are still refused so a title or ordinal can't masquerade as
        // deep identity.
        guard let id = signal.appProviderIdentity else { return nil }
        return id.layer <= 2 ? id : nil
    }
}
