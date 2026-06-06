import Foundation
import IOKit
import CryptoKit

/// Derives a stable per-machine identifier suitable for license binding.
///
/// `machine_id = SHA256(IOPlatformUUID + bundleID + appSalt)`, hex-encoded.
///
/// Properties:
///  - Stable across reboots and macOS upgrades (IOPlatformUUID is bound to
///    the logic-board UUID burned at provisioning).
///  - Unique per physical machine — two MacBooks never collide.
///  - Bundle-scoped: re-installing under a different bundle ID would produce
///    a different machine_id (that scenario shouldn't happen for our app
///    but the scope is defensive).
///  - Not reversible to anything PII-bearing — we never send the raw
///    IOPlatformUUID over the wire.
///
/// **Privacy**: machine_id is the only persistent device identifier we ever
/// transmit. No MAC address, no IDFA, no system serial — just a salted hash
/// that's useless outside our license database.
public enum MachineIdentity {

    /// Process-wide salt. Embed at build time. Rotating this would
    /// invalidate every existing activation, so don't.
    private static let appSalt = "PixlPut-v1-machine-salt-7Rq2Zk"

    public static func current() -> String {
        let raw = ioPlatformUUID() ?? fallbackHostBased()
        let bundleID = Bundle.main.bundleIdentifier ?? "co.cerebraljuice.PixlPut"
        let input = raw + "|" + bundleID + "|" + appSalt
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func ioPlatformUUID() -> String? {
        let entry = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let cf = IORegistryEntryCreateCFProperty(
            entry, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0
        ) else { return nil }
        return cf.takeRetainedValue() as? String
    }

    /// Last-resort fallback if IOPlatformUUID is somehow unavailable
    /// (it shouldn't be on real Macs). Uses gethostname() — stable across
    /// reboots but trivially user-spoofable. Activation will still work;
    /// only the "device limit" enforcement gets weaker on this machine.
    private static func fallbackHostBased() -> String {
        var name = [CChar](repeating: 0, count: 256)
        gethostname(&name, 256)
        return String(cString: name)
    }
}
