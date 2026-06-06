import Foundation

/// Layer 1 — strongest signal. Uses the AX `kAXDocumentAttribute` value
/// already extracted into `WindowSignal.documentURL`.
public struct DocumentPathProvider: WindowIdentityProvider {
    public let layer: Int = 1
    public init() {}

    public func resolve(_ signal: WindowSignal) -> WindowIdentity? {
        guard let url = signal.documentURL else { return nil }
        return .documentPath(url)
    }
}
