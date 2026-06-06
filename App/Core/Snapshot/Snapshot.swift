import Foundation

/// Top-level snapshot: an ordered set of `WindowEntry` records taken at a
/// single capture event, scoped to a `DisplayConfiguration`.
///
/// On-disk shape: `contracts/snapshot.schema.json` (schemaVersion = 1).
public struct Snapshot: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let id: UUID
    public let name: String?
    public let displayConfigurationID: String
    public let displays: [DisplaySnapshot]
    public let capturedAt: Date
    public let trigger: CaptureTrigger
    public let windows: [WindowEntry]

    public init(
        id: UUID = UUID(),
        name: String? = nil,
        displayConfigurationID: String,
        displays: [DisplaySnapshot],
        capturedAt: Date = Date(),
        trigger: CaptureTrigger,
        windows: [WindowEntry]
    ) {
        self.schemaVersion = Snapshot.currentSchemaVersion
        self.id = id
        self.name = name
        self.displayConfigurationID = displayConfigurationID
        self.displays = displays
        self.capturedAt = capturedAt
        self.trigger = trigger
        self.windows = windows
    }

    /// Bumped only when the on-disk shape changes incompatibly. Additive
    /// changes do NOT bump this version.
    public static let currentSchemaVersion: Int = 1

    enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, displayConfigurationID,
             displays, capturedAt, trigger, windows
    }
}

/// Capture trigger source — matches `contracts/snapshot.schema.json` `trigger` enum.
public enum CaptureTrigger: String, Codable, Sendable, CaseIterable {
    case screensaverStart, displaySleep, screenLock, manual, displayConfigChange, spaceSwitch
}

/// A display as it existed in the configuration at capture time.
public struct DisplaySnapshot: Codable, Hashable, Sendable {
    public let fingerprint: DisplayFingerprint
    public let bounds: CGRectCodable
    public let isPrimary: Bool
    public let scaleFactor: Double

    public init(
        fingerprint: DisplayFingerprint,
        bounds: CGRectCodable,
        isPrimary: Bool,
        scaleFactor: Double
    ) {
        self.fingerprint = fingerprint
        self.bounds = bounds
        self.isPrimary = isPrimary
        self.scaleFactor = scaleFactor
    }
}
