import Foundation

/// A window's resolved identity. The variants form the layered strategy from
/// project constitution §II (strongest signal first).
///
/// On-disk shape: tagged-union with exactly one variant key set, matching
/// `contracts/snapshot.schema.json` `$defs/windowIdentity`.
public enum WindowIdentity: Codable, Hashable, Sendable {
    /// Layer 1 — `kAXDocumentAttribute` from the AX window (strongest).
    case documentPath(URL)
    /// Layer 2a — browser tab URL set (Brave/Edge/Chrome/Arc/Safari).
    case browserTabSet([URL])
    /// Layer 2b — editor workspace path (VS Code/Xcode/JetBrains).
    case editorWorkspace(URL)
    /// Layer 2c — terminal current working directory (iTerm2/Terminal/Ghostty/Warp).
    case terminalCWD(URL)
    /// Layer 3 — title-derived fingerprint (regex per-bundle).
    case titleRegex(pattern: String, capturedValue: String)
    /// Layer 4 — fallback by AX-window creation index.
    case ordinal(Int)

    /// Returns the layer number (1 = strongest, 4 = weakest).
    /// Used by `WindowIdentityResolver` to enforce the layered order.
    public var layer: Int {
        switch self {
        case .documentPath:      return 1
        case .browserTabSet,
             .editorWorkspace,
             .terminalCWD:       return 2
        case .titleRegex:        return 3
        case .ordinal:           return 4
        }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case documentPath, browserTabSet, editorWorkspace,
             terminalCWD, titleRegex, ordinal
    }

    private struct TitleRegexPayload: Codable {
        let pattern: String
        let capturedValue: String
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .documentPath(let url):
            try c.encode(url, forKey: .documentPath)
        case .browserTabSet(let urls):
            try c.encode(urls, forKey: .browserTabSet)
        case .editorWorkspace(let url):
            try c.encode(url, forKey: .editorWorkspace)
        case .terminalCWD(let url):
            try c.encode(url, forKey: .terminalCWD)
        case .titleRegex(let pattern, let captured):
            try c.encode(
                TitleRegexPayload(pattern: pattern, capturedValue: captured),
                forKey: .titleRegex
            )
        case .ordinal(let index):
            try c.encode(index, forKey: .ordinal)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Exactly one variant key must be present per the schema's oneOf.
        let present = c.allKeys
        guard present.count == 1, let key = present.first else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "WindowIdentity requires exactly one variant key; found \(present.count)."
            ))
        }
        switch key {
        case .documentPath:
            self = .documentPath(try c.decode(URL.self, forKey: .documentPath))
        case .browserTabSet:
            self = .browserTabSet(try c.decode([URL].self, forKey: .browserTabSet))
        case .editorWorkspace:
            self = .editorWorkspace(try c.decode(URL.self, forKey: .editorWorkspace))
        case .terminalCWD:
            self = .terminalCWD(try c.decode(URL.self, forKey: .terminalCWD))
        case .titleRegex:
            let payload = try c.decode(TitleRegexPayload.self, forKey: .titleRegex)
            self = .titleRegex(pattern: payload.pattern, capturedValue: payload.capturedValue)
        case .ordinal:
            self = .ordinal(try c.decode(Int.self, forKey: .ordinal))
        }
    }
}
