import Foundation

/// Layer 4 — always-resolves fallback. Uses the AX-window creation ordinal
/// for windows of the same bundle. This is the weakest signal and surfaces
/// a "best-effort" badge to the user when it's the resolved layer
/// (Story-3 acceptance #3).
public struct OrdinalProvider: WindowIdentityProvider {
    public let layer: Int = 4
    public init() {}

    public func resolve(_ signal: WindowSignal) -> WindowIdentity? {
        // OrdinalProvider always returns a value. It's the terminal fallback.
        .ordinal(signal.creationOrdinal)
    }
}
