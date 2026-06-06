import Foundation
import CryptoKit

/// Verifies Ed25519 signatures produced by the license server.
///
/// The public key is embedded at build time. The matching private key lives
/// ONLY on the server (Cloudflare Worker secret `ED25519_PRIVATE_KEY`).
/// Without the private key, no one can forge a valid license — that's the
/// load-bearing property of the whole licensing system. Replacing the
/// public key in a cracked binary would require re-signing the app
/// (breaking the Developer ID + notarization chain) AND running their own
/// fake server, which Sparkle auto-update can outpace by rotating the key
/// in a future release.
public enum LicenseVerifier {

    /// **Placeholder public key.** Replace with the output of
    /// `pnpm keys:generate` from the `server/` project before shipping.
    /// Leaving the placeholder in production means any license at all
    /// would fail to verify — by design, so an unconfigured build is
    /// safe-by-default rather than silently licensed.
    public static let publicKeyB64 = "PLACEHOLDER_REPLACE_WITH_GENERATED_KEY"

    public enum VerificationError: Error, Equatable {
        case publicKeyNotConfigured
        case publicKeyMalformed
        case signatureMalformed
        case signatureMismatch
        case payloadEncodingFailed
    }

    /// Verify a `SignedLicense` against the embedded public key.
    /// Returns the inner `LicensePayload` on success; throws otherwise.
    @discardableResult
    public static func verify(_ signed: SignedLicense) throws -> LicensePayload {
        try verifyEnvelope(payload: signed.payload, sig: signed.sig)
        return signed.payload
    }

    /// Verify a `SignedValidateResponse` against the embedded public key.
    @discardableResult
    public static func verify(_ signed: SignedValidateResponse) throws -> ValidatePayload {
        try verifyEnvelope(payload: signed.payload, sig: signed.sig)
        return signed.payload
    }

    private static func verifyEnvelope<T: Encodable>(payload: T, sig: String) throws {
        if publicKeyB64 == "PLACEHOLDER_REPLACE_WITH_GENERATED_KEY" {
            throw VerificationError.publicKeyNotConfigured
        }
        guard let pubBytes = Data(base64Encoded: publicKeyB64), pubBytes.count == 32 else {
            throw VerificationError.publicKeyMalformed
        }
        guard let sigBytes = Data(base64Encoded: sig), sigBytes.count == 64 else {
            throw VerificationError.signatureMalformed
        }
        let canonical: Data
        do {
            canonical = try CanonicalJSON.encode(payload)
        } catch {
            throw VerificationError.payloadEncodingFailed
        }
        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: pubBytes)
        } catch {
            throw VerificationError.publicKeyMalformed
        }
        guard publicKey.isValidSignature(sigBytes, for: canonical) else {
            throw VerificationError.signatureMismatch
        }
    }
}
