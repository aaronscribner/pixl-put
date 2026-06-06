import Foundation
import CoreGraphics

/// A single window's recorded state in a snapshot.
/// On-disk shape: `contracts/snapshot.schema.json` — additive changes only without a schemaVersion bump.
public struct WindowEntry: Codable, Hashable, Sendable {
    public let bundleID: String
    public let identity: WindowIdentity
    /// Per-bundle creation index of this window at capture time (0-based).
    /// Used by `Restorer` as the tiebreaker when multiple windows of the
    /// same bundle resolve to the same identity (e.g. two iTerm2 windows
    /// both in `~/work`). Decoded as 0 in legacy snapshots that pre-date
    /// this field — older snapshots fall back to insertion-order matching.
    public let ordinalInApp: Int
    public let displayFingerprintID: String
    public let spaceIndex: Int
    public let frame: CGRectCodable
    public let isMinimized: Bool
    public let isFullscreen: Bool
    public let capturedAt: Date

    public init(
        bundleID: String,
        identity: WindowIdentity,
        ordinalInApp: Int = 0,
        displayFingerprintID: String,
        spaceIndex: Int,
        frame: CGRectCodable,
        isMinimized: Bool,
        isFullscreen: Bool,
        capturedAt: Date
    ) {
        self.bundleID = bundleID
        self.identity = identity
        self.ordinalInApp = ordinalInApp
        self.displayFingerprintID = displayFingerprintID
        self.spaceIndex = spaceIndex
        self.frame = frame
        self.isMinimized = isMinimized
        self.isFullscreen = isFullscreen
        self.capturedAt = capturedAt
    }

    enum CodingKeys: String, CodingKey {
        case bundleID, identity, ordinalInApp, displayFingerprintID, spaceIndex,
             frame, isMinimized, isFullscreen, capturedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.bundleID = try c.decode(String.self, forKey: .bundleID)
        self.identity = try c.decode(WindowIdentity.self, forKey: .identity)
        // ordinalInApp is post-schema-v1; older snapshots don't have it.
        self.ordinalInApp = try c.decodeIfPresent(Int.self, forKey: .ordinalInApp) ?? 0
        self.displayFingerprintID = try c.decode(String.self, forKey: .displayFingerprintID)
        self.spaceIndex = try c.decode(Int.self, forKey: .spaceIndex)
        self.frame = try c.decode(CGRectCodable.self, forKey: .frame)
        self.isMinimized = try c.decode(Bool.self, forKey: .isMinimized)
        self.isFullscreen = try c.decode(Bool.self, forKey: .isFullscreen)
        self.capturedAt = try c.decode(Date.self, forKey: .capturedAt)
    }
}

/// `CGRect` is not directly `Codable` with stable key names across encoders — we use a
/// fixed `{x, y, width, height}` shape to match `contracts/snapshot.schema.json`.
public struct CGRectCodable: Codable, Hashable, Sendable {
    public let x: CGFloat
    public let y: CGFloat
    public let width: CGFloat
    public let height: CGFloat

    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y,
                  width: rect.size.width, height: rect.size.height)
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    /// Whether two rects are within `tolerance` points of each other in both origin and size.
    /// Used by `Restorer` per project constitution §III (no move if already at frame within 1 px).
    public func isApproximately(_ other: CGRectCodable, tolerance: CGFloat = 1.0) -> Bool {
        abs(x - other.x) <= tolerance &&
        abs(y - other.y) <= tolerance &&
        abs(width - other.width) <= tolerance &&
        abs(height - other.height) <= tolerance
    }
}
