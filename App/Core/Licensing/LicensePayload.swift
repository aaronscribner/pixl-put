import Foundation

/// The license blob the server signs and the app verifies.
///
/// **WIRE COMPATIBILITY**: this struct's JSON encoding MUST match the
/// server's `LicensePayload` in `server/src/types.ts`. Both sides canonicalize
/// with sorted keys + UTF-8 + no whitespace before signing/verifying.
/// Adding a field requires bumping `v` and updating both sides in lockstep.
public struct LicensePayload: Codable, Equatable, Sendable {
    public let v: Int
    public let license_id: String
    public let license_key: String
    public let customer_email: String
    public let plan: String
    public let machine_id: String
    public let issued_at: Int          // unix seconds
    public let expires_at: Int?        // nil = perpetual
    public let max_devices: Int

    public init(
        v: Int = 1,
        license_id: String,
        license_key: String,
        customer_email: String,
        plan: String,
        machine_id: String,
        issued_at: Int,
        expires_at: Int?,
        max_devices: Int
    ) {
        self.v = v
        self.license_id = license_id
        self.license_key = license_key
        self.customer_email = customer_email
        self.plan = plan
        self.machine_id = machine_id
        self.issued_at = issued_at
        self.expires_at = expires_at
        self.max_devices = max_devices
    }
}

/// Envelope returned by /activate and stored in Keychain.
public struct SignedLicense: Codable, Equatable, Sendable {
    public let payload: LicensePayload
    /// Base64 Ed25519 signature over the canonical-JSON of `payload`.
    public let sig: String
    /// Base64 SHA-256 prefix-8 of the signing public key — for key rotation
    /// diagnostics; not used for verification.
    public let kid: String

    public init(payload: LicensePayload, sig: String, kid: String) {
        self.payload = payload
        self.sig = sig
        self.kid = kid
    }
}

/// Server's signed reply to a /validate phone-home.
public struct SignedValidateResponse: Codable, Equatable, Sendable {
    public let payload: ValidatePayload
    public let sig: String
    public let kid: String
}

public struct ValidatePayload: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case active
        case expired
        case revoked
        case machine_limit_exceeded
        case unknown_license
    }
    public let status: Status
    public let nonce_echo: String
    public let server_ts: Int
    public let expires_at: Int?
    public let next_validate_after: Int
}

/// Canonical-JSON encoder for cross-platform signing compatibility.
/// Sorted keys + UTF-8 + no whitespace + no slash escaping. The bytes
/// produced here MUST exactly match what `server/src/crypto.ts#canonicalize`
/// produces for the same logical object.
public enum CanonicalJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
