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
        // Accept only layer-2 identities to maintain resolver invariants.
        guard let id = signal.appProviderIdentity else { return nil }
        return id.layer == 2 ? id : nil
    }
}
