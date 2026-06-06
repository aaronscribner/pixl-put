import Foundation

/// Layer 3 — title-derived fingerprint via a per-bundle regular expression.
/// The regex extracts a stable substring from the window title (e.g. VS Code
/// workspace name appears in the title bar). The captured value forms the
/// identity, not the raw title (which drifts).
public struct TitleRegexProvider: WindowIdentityProvider {
    public let layer: Int = 3

    /// A pattern paired with a human-readable label. The pattern must include
    /// at least one capture group; the first capture is the stable value.
    public struct Pattern: Sendable, Hashable {
        public let regex: String
        public let label: String

        public init(regex: String, label: String) {
            self.regex = regex
            self.label = label
        }
    }

    public let perBundle: [String: Pattern]

    public init(perBundle: [String: Pattern] = [:]) {
        self.perBundle = perBundle
    }

    /// Defaults for common bundles. Kept narrow on purpose — the registry is
    /// expanded as new bundle-specific quirks emerge.
    public static let defaults: [String: Pattern] = [
        "com.microsoft.VSCode": Pattern(
            regex: #"^.*— ([^—]+) — Visual Studio Code$"#,
            label: "VS Code workspace name"
        ),
        "com.apple.dt.Xcode": Pattern(
            regex: #"^([^—]+) — .+$"#,
            label: "Xcode project/document"
        ),
    ]

    public func resolve(_ signal: WindowSignal) -> WindowIdentity? {
        guard let pattern = perBundle[signal.bundleID] ?? Self.defaults[signal.bundleID] else {
            return nil
        }
        guard let captured = Self.firstCapture(of: pattern.regex, in: signal.title) else {
            return nil
        }
        return .titleRegex(pattern: pattern.regex, capturedValue: captured)
    }

    static func firstCapture(of pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }
}
