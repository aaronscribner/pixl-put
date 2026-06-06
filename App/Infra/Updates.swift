import Foundation
import AppKit
import Sparkle

/// Sparkle 2.x integration. Wraps `SPUStandardUpdaterController` so the rest
/// of the app calls a single static entry point (`Updates.shared.checkForUpdates()`).
///
/// Requirements (kept in sync with `Resources/Info.plist`):
///   - `SUFeedURL`  — appcast URL (https://updates.pixput.app/appcast.xml).
///   - `SUPublicEDKey` — base64 EdDSA public key from `sparkle_generate_keys`.
///   - `SUEnableAutomaticChecks` — true (default daily check).
///   - `SUEnableInstallerLauncherService` — not needed (non-sandboxed app).
///
/// Release flow lives in `scripts/release-with-sparkle.sh`:
///   1. Archive + sign + notarize the app (existing `scripts/release-app.sh`).
///   2. Wrap into a zip.
///   3. `sparkle_sign_update <zip>` → produces the `sparkle:edSignature` value.
///   4. Append a new `<item>` to `appcast.xml` with the signature.
///   5. Upload zip + appcast.xml to https://updates.pixput.app/.
public final class Updates: NSObject {

    public static let shared = Updates()

    private let updaterController: SPUStandardUpdaterController

    private override init() {
        // `startingUpdater: true` kicks off Sparkle's background scheduler
        // immediately. `updaterDelegate: nil` keeps the default behaviour.
        // `userDriverDelegate: nil` likewise — Sparkle owns its own UI.
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
        LoggerRegistry.updates.log(
            .info,
            "Sparkle updater started; feed=\(self.updaterController.updater.feedURL?.absoluteString ?? "<none>") automatic=\(self.updaterController.updater.automaticallyChecksForUpdates)"
        )
    }

    /// User-initiated update check. Sparkle presents a window with progress
    /// / "you're up to date" / "new version available" UI.
    public func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    /// Whether the background scheduler is enabled. Surfaced for a future
    /// Settings toggle.
    public var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set { updaterController.updater.automaticallyChecksForUpdates = newValue }
    }

    /// True — Sparkle is always available in release builds.
    public var isAvailable: Bool { true }
}
