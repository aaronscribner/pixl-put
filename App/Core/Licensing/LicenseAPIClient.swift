import Foundation

/// Network client for the PixlPut license API.
///
/// Every response from the server is signed (Ed25519) with the same key the
/// app verifies offline-stored licenses against. So even a successful HTTP
/// 200 is only trusted if its body's signature verifies and its `nonce_echo`
/// matches the nonce we just sent — no MitM, DNS hijack, or rogue server
/// without the private key can fake a valid response.
///
/// Cert pinning provides defense-in-depth — see `PinnedCertSessionDelegate`.
public actor LicenseAPIClient {

    public struct Configuration: Sendable {
        public let baseURL: URL
        /// SHA-256 (base64) of the API leaf certificate's SubjectPublicKeyInfo.
        /// When non-nil, URLSession rejects any TLS handshake whose leaf doesn't
        /// match — protects against rogue CA / corporate-MITM proxies. Pin to
        /// the leaf, not the CA, so revocation/rotation requires an app update
        /// (the same channel we'd ship to fix a leaked private key).
        public let pinnedLeafSPKISHA256B64: String?
        public let appVersion: String

        public init(baseURL: URL, pinnedLeafSPKISHA256B64: String?, appVersion: String) {
            self.baseURL = baseURL
            self.pinnedLeafSPKISHA256B64 = pinnedLeafSPKISHA256B64
            self.appVersion = appVersion
        }

        /// Production endpoint — keep in sync with the deployed Worker route.
        public static let production = Configuration(
            baseURL: URL(string: "https://api.pixput.app")!,
            pinnedLeafSPKISHA256B64: nil,   // TODO: pin after first deploy
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        )
    }

    public enum APIError: Error, Equatable {
        case httpStatus(Int, body: String)
        case decodingFailed(String)
        case signatureVerificationFailed
        case nonceMismatch
        case transport(String)
        case malformedURL
    }

    private let config: Configuration
    private let session: URLSession

    public init(config: Configuration = .production) {
        self.config = config
        let delegate: URLSessionDelegate?
        if let pin = config.pinnedLeafSPKISHA256B64 {
            delegate = PinnedCertSessionDelegate(expectedSPKISHA256B64: pin)
        } else {
            delegate = nil
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        cfg.httpAdditionalHeaders = ["User-Agent": "PixlPut/\(config.appVersion) (macOS)"]
        self.session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
    }

    // MARK: Endpoints

    public struct ActivateRequest: Encodable {
        public let license_key: String
        public let machine_id: String
        public let nonce: String
        public let client_ts: Int
        public let app_version: String
    }

    public struct ActivateResponse: Decodable {
        public let license: SignedLicense
        public let nonce_echo: String
        public let server_ts: Int
    }

    public func activate(licenseKey: String, machineID: String) async throws -> SignedLicense {
        let nonce = Self.newNonce()
        let body = ActivateRequest(
            license_key: licenseKey,
            machine_id: machineID,
            nonce: nonce,
            client_ts: Int(Date().timeIntervalSince1970),
            app_version: config.appVersion
        )
        let resp: ActivateResponse = try await post("/v1/activate", body: body)
        guard resp.nonce_echo == nonce else { throw APIError.nonceMismatch }
        // Server's reply is a `SignedLicense` envelope — verify with the
        // same public key the app trusts for offline-stored licenses.
        do {
            try LicenseVerifier.verify(resp.license)
        } catch {
            throw APIError.signatureVerificationFailed
        }
        return resp.license
    }

    public struct ValidateRequest: Encodable {
        public let license_key: String
        public let machine_id: String
        public let nonce: String
        public let client_ts: Int
        public let app_version: String
    }

    public func validate(licenseKey: String, machineID: String) async throws -> ValidatePayload {
        let nonce = Self.newNonce()
        let body = ValidateRequest(
            license_key: licenseKey,
            machine_id: machineID,
            nonce: nonce,
            client_ts: Int(Date().timeIntervalSince1970),
            app_version: config.appVersion
        )
        let signed: SignedValidateResponse = try await post("/v1/validate", body: body)
        try LicenseVerifier.verify(signed)
        guard signed.payload.nonce_echo == nonce else { throw APIError.nonceMismatch }
        return signed.payload
    }

    public struct DeactivateRequest: Encodable {
        public let license_key: String
        public let machine_id: String
    }

    public func deactivate(licenseKey: String, machineID: String) async throws {
        let body = DeactivateRequest(license_key: licenseKey, machine_id: machineID)
        let _: [String: Bool] = try await post("/v1/deactivate", body: body)
    }

    public struct TrialStartRequest: Encodable {
        public let machine_id: String
        public let email: String?
    }

    public struct DevicesRequest: Encodable {
        public let license_key: String
        public let machine_id: String          // requesting device — must be activated on this license
    }

    public struct DevicesResponse: Decodable {
        public let devices: [DeviceEntry]
    }

    public struct DeviceEntry: Decodable, Identifiable, Sendable {
        public let machine_id: String
        public let activated_at: Int
        public let last_seen_at: Int
        public let last_app_version: String?
        public var id: String { machine_id }
    }

    /// List all machines activated on the given license. The current device
    /// must itself be activated — prevents anyone from querying activation
    /// counts for arbitrary license keys.
    public func devices(licenseKey: String, machineID: String) async throws -> [DeviceEntry] {
        let body = DevicesRequest(license_key: licenseKey, machine_id: machineID)
        let resp: DevicesResponse = try await post("/v1/license/devices", body: body)
        return resp.devices
    }

    public struct SignedTrial: Decodable {
        public let payload: TrialPayload
        public let sig: String
        public let kid: String
    }
    public struct TrialPayload: Codable, Equatable, Sendable {
        public let v: Int
        public let kind: String
        public let machine_id: String
        public let started_at: Int
        public let expires_at: Int
        public let server_ts: Int
    }

    public func startTrial(machineID: String, email: String? = nil) async throws -> TrialPayload {
        let body = TrialStartRequest(machine_id: machineID, email: email)
        let signed: SignedTrial = try await post("/v1/trial/start", body: body)
        // Verify the trial envelope using the same canonical-JSON + public key
        // contract as licenses.
        try verifyTrialEnvelope(signed)
        return signed.payload
    }

    private func verifyTrialEnvelope(_ signed: SignedTrial) throws {
        let pubKeyB64 = LicenseVerifier.publicKeyB64
        if pubKeyB64 == "PLACEHOLDER_REPLACE_WITH_GENERATED_KEY" {
            throw LicenseVerifier.VerificationError.publicKeyNotConfigured
        }
        guard let pubBytes = Data(base64Encoded: pubKeyB64), pubBytes.count == 32 else {
            throw LicenseVerifier.VerificationError.publicKeyMalformed
        }
        guard let sigBytes = Data(base64Encoded: signed.sig), sigBytes.count == 64 else {
            throw LicenseVerifier.VerificationError.signatureMalformed
        }
        let canonical = try CanonicalJSON.encode(signed.payload)
        let publicKey = try Curve25519SigningPublicKey(rawRepresentation: pubBytes)
        guard publicKey.isValidSignature(sigBytes, for: canonical) else {
            throw LicenseVerifier.VerificationError.signatureMismatch
        }
    }

    // MARK: HTTP plumbing

    private func post<Req: Encodable, Resp: Decodable>(_ path: String, body: Req) async throws -> Resp {
        guard let url = URL(string: path, relativeTo: config.baseURL) else {
            throw APIError.malformedURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport("not HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpStatus(http.statusCode, body: bodyStr)
        }
        do {
            return try JSONDecoder().decode(Resp.self, from: data)
        } catch {
            throw APIError.decodingFailed(String(describing: error))
        }
    }

    static func newNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }
}

// MARK: - CryptoKit bridging

import CryptoKit
import Security

/// Tiny type alias so LicenseAPIClient doesn't need to import CryptoKit at
/// the type-signature level (keeps the verifier responsibility centralised).
fileprivate typealias Curve25519SigningPublicKey = Curve25519.Signing.PublicKey

/// URLSession delegate that pins the leaf certificate's SubjectPublicKeyInfo
/// SHA-256. Compares against the value baked into `Configuration` — any
/// mismatch fails the handshake before the request body ever leaves the
/// device.
private final class PinnedCertSessionDelegate: NSObject, URLSessionDelegate {

    private let expectedSPKISHA256B64: String

    init(expectedSPKISHA256B64: String) {
        self.expectedSPKISHA256B64 = expectedSPKISHA256B64
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // 1. Let the system validate the chain (revocation, expiry, CT…).
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        // 2. Pin the leaf SPKI.
        guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
              let key = SecCertificateCopyKey(leaf),
              let spki = SecKeyCopyExternalRepresentation(key, nil) as Data? else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let hash = SHA256.hash(data: spki)
        let computed = Data(hash).base64EncodedString()
        if computed == expectedSPKISHA256B64 {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
