import Foundation
import Security

/// Persists the signed license and last-validated-at timestamp in the
/// macOS Keychain.
///
/// **Why Keychain, not a plist?** The plist file would be trivially editable
/// by any user; a cracker could set `isLicensed = true` and we'd never know.
/// Keychain items are tied to the app's code-signing identity — a re-signed
/// or unsigned build cannot read this app's Keychain items, so even an
/// attacker who replaces the binary can't lift an existing license.
public enum LicenseKeychain {

    private static let service = "co.cerebraljuice.PixlPut.license"
    private static let signedLicenseAccount = "signed-license-v1"
    private static let lastValidatedAccount = "last-validated-at"

    // MARK: Signed license

    public static func saveSignedLicense(_ license: SignedLicense) throws {
        let data = try JSONEncoder().encode(license)
        try save(account: signedLicenseAccount, data: data)
    }

    public static func loadSignedLicense() -> SignedLicense? {
        guard let data = load(account: signedLicenseAccount) else { return nil }
        return try? JSONDecoder().decode(SignedLicense.self, from: data)
    }

    public static func clearSignedLicense() {
        delete(account: signedLicenseAccount)
    }

    // MARK: Last-validated-at

    public static func saveLastValidatedAt(_ date: Date) throws {
        let bytes = withUnsafeBytes(of: date.timeIntervalSince1970) { Data($0) }
        try save(account: lastValidatedAccount, data: bytes)
    }

    public static func loadLastValidatedAt() -> Date? {
        guard let data = load(account: lastValidatedAccount), data.count >= 8 else { return nil }
        let interval = data.withUnsafeBytes { $0.load(as: TimeInterval.self) }
        return Date(timeIntervalSince1970: interval)
    }

    public static func clearLastValidatedAt() {
        delete(account: lastValidatedAccount)
    }

    // MARK: Trial timestamps

    private static let trialStartedAccount = "trial-started-at"
    private static let trialExpiresAccount = "trial-expires-at"

    public static func saveTrialStartedAt(_ d: Date) throws {
        try saveDate(account: trialStartedAccount, date: d)
    }
    public static func loadTrialStartedAt() -> Date? {
        loadDate(account: trialStartedAccount)
    }
    public static func saveTrialExpiresAt(_ d: Date) throws {
        try saveDate(account: trialExpiresAccount, date: d)
    }
    public static func loadTrialExpiresAt() -> Date? {
        loadDate(account: trialExpiresAccount)
    }

    private static func saveDate(account: String, date: Date) throws {
        let bytes = withUnsafeBytes(of: date.timeIntervalSince1970) { Data($0) }
        try save(account: account, data: bytes)
    }
    private static func loadDate(account: String) -> Date? {
        guard let data = load(account: account), data.count >= 8 else { return nil }
        let t = data.withUnsafeBytes { $0.load(as: TimeInterval.self) }
        return Date(timeIntervalSince1970: t)
    }

    // MARK: Keychain primitives

    private static func save(account: String, data: Data) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Update first; if no item exists, add.
        let updateAttrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpected(status: updateStatus)
        }
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpected(status: addStatus)
        }
    }

    private static func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var ref: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &ref)
        guard status == errSecSuccess else { return nil }
        return ref as? Data
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    public enum KeychainError: Error, Equatable {
        case unexpected(status: OSStatus)
    }
}
