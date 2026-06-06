import Foundation
import CryptoKit

/// Stable, port-order-independent identifier for a single display.
/// Computed from vendor / product / serial + a hash of the CoreGraphics
/// `displayUUID`. The `id` field is the load-bearing identifier — two
/// `DisplayFingerprint`s with the same `id` are considered the same display.
///
/// See spec FR-001 and `roadmap/arch/c4/components/Core-Displays.md`.
public struct DisplayFingerprint: Codable, Hashable, Sendable {
    public let id: String
    public let vendorID: UInt32
    public let productID: UInt32
    public let modelNumber: UInt32
    public let serialNumber: UInt32 // low 24 bits only
    public let displayUUID: String? // diagnostic; not part of id

    public init(
        vendorID: UInt32,
        productID: UInt32,
        modelNumber: UInt32,
        serialNumber: UInt32,
        displayUUID: String?
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber & 0x00FFFFFF
        self.displayUUID = displayUUID
        self.id = Self.computeID(
            vendorID: vendorID,
            productID: productID,
            modelNumber: modelNumber,
            serialNumber: serialNumber & 0x00FFFFFF,
            displayUUID: displayUUID
        )
    }

    /// Recreate from persisted values without recomputing the id (round-trip).
    public init(
        id: String,
        vendorID: UInt32,
        productID: UInt32,
        modelNumber: UInt32,
        serialNumber: UInt32,
        displayUUID: String?
    ) {
        self.id = id
        self.vendorID = vendorID
        self.productID = productID
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber & 0x00FFFFFF
        self.displayUUID = displayUUID
    }

    /// SHA-256 of "vendor:product:model:serial:uuid", first 16 hex chars (8 bytes).
    public static func computeID(
        vendorID: UInt32,
        productID: UInt32,
        modelNumber: UInt32,
        serialNumber: UInt32,
        displayUUID: String?
    ) -> String {
        let input = "\(vendorID):\(productID):\(modelNumber):\(serialNumber):\(displayUUID ?? "")"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Aggregate fingerprint for a multi-display configuration. The `id`
/// is port-order-independent (FR-001) — the constituent fingerprint ids
/// are sorted before hashing.
public enum DisplayConfigurationID {
    /// Compute the configuration ID from a set of display fingerprints,
    /// independent of port order.
    public static func compute(from fingerprints: [DisplayFingerprint]) -> String {
        let sortedIDs = fingerprints.map(\.id).sorted()
        let input = sortedIDs.joined(separator: ",")
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
