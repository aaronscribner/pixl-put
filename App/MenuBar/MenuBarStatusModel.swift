import Foundation
import Combine

/// Observable status surface shown in the menu bar. AppLifecycle updates
/// these properties; MenuBarController reads them; future SwiftUI panes
/// (Settings → Snapshots) subscribe via `@Published` / Combine.
@MainActor
public final class MenuBarStatusModel: ObservableObject {
    @Published public var lastCapture: Date?
    @Published public var lastCaptureWindowCount: Int = 0
    @Published public var lastRestore: Date?
    @Published public var lastRestoreMoved: Int = 0
    @Published public var lastRestoreSkipped: Int = 0
    @Published public var lastRestoreDisplaced: Int = 0
    @Published public var hasAccessibilityPermission: Bool = false
    @Published public var isSpaceAware: Bool = false
    /// When true, PixlPut skips per-app deep identity (no Automation
    /// permission prompts for browsers / editors / terminals). Identity
    /// falls back to title-regex + ordinal — Story-3 still works for
    /// single-window-per-app cases; multiple-window-per-app cases use
    /// the layer-3/4 fallback. Default: true (privacy-by-default).
    @Published public var deepIdentityEnabled: Bool = false
    /// User setting: when true, PixlPut automatically restores windows to the
    /// captured layout after the machine wakes — the active Space immediately,
    /// and every other Space on the first visit after wake. When false, nothing
    /// is ever moved automatically; restore happens only when the user clicks
    /// "Restore now". Persisted; default true. (Auto-capture was removed — the
    /// snapshot only changes via manual "Capture now".)
    @Published public var restoreOnSpaceSwitch: Bool {
        didSet {
            UserDefaults.standard.set(restoreOnSpaceSwitch, forKey: Self.autoRestoreKey)
        }
    }
    private static let autoRestoreKey = "PixlPut.autoRestoreOnWake"
    /// When true, PixlPut captures a JPEG screenshot of the active display
    /// every time a Space-switch auto-capture fires. Disabled by default —
    /// requires explicit consent (the user must acknowledge that
    /// screenshots may contain sensitive information) AND Screen Recording
    /// permission. The toggle is persisted in UserDefaults so the choice
    /// survives relaunch.
    @Published public var enableSpaceScreenshots: Bool {
        didSet {
            UserDefaults.standard.set(enableSpaceScreenshots, forKey: Self.enableSpaceScreenshotsKey)
        }
    }
    private static let enableSpaceScreenshotsKey = "PixlPut.enableSpaceScreenshots"

    /// When true, thumbnails are kept for the entire rotating history —
    /// so the Restore Picker shows visual previews of older snapshots,
    /// not just the latest. When false (default), only the current
    /// snapshot has thumbnails; rotation deletes the previous slot 0
    /// thumbnails instead of promoting them. Costs ~K MB of disk per
    /// retained history slot (depends on display resolution + Space
    /// count). Only meaningful if `enableSpaceScreenshots` is also true.
    @Published public var enableSnapshotHistoryThumbnails: Bool {
        didSet {
            UserDefaults.standard.set(enableSnapshotHistoryThumbnails, forKey: Self.enableHistoryThumbnailsKey)
        }
    }
    private static let enableHistoryThumbnailsKey = "PixlPut.enableSnapshotHistoryThumbnails"

    /// Human-readable last error from a manual or auto operation. Surfaced
    /// in the menu bar so the user isn't left wondering why nothing happened.
    @Published public var lastError: String?

    public init() {
        // Default ON when the user has never set it.
        self.restoreOnSpaceSwitch = UserDefaults.standard.object(forKey: Self.autoRestoreKey) as? Bool ?? true
        self.enableSpaceScreenshots = UserDefaults.standard.bool(forKey: Self.enableSpaceScreenshotsKey)
        self.enableSnapshotHistoryThumbnails = UserDefaults.standard.bool(forKey: Self.enableHistoryThumbnailsKey)
    }
}
