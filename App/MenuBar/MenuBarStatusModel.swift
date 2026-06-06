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
    @Published public var isAutoCapturePaused: Bool = false
    @Published public var hasAccessibilityPermission: Bool = false
    @Published public var isSpaceAware: Bool = false
    /// When true, PixlPut skips per-app deep identity (no Automation
    /// permission prompts for browsers / editors / terminals). Identity
    /// falls back to title-regex + ordinal — Story-3 still works for
    /// single-window-per-app cases; multiple-window-per-app cases use
    /// the layer-3/4 fallback. Default: true (privacy-by-default).
    @Published public var deepIdentityEnabled: Bool = false
    /// Phase D — when true, switching to a Space the user hasn't visited
    /// since the last wake auto-restores that Space's windows. When false,
    /// only the active-Space-at-wake gets restored automatically; other
    /// Spaces remain at their pre-sleep arrangement (or whatever the user
    /// has rearranged them to). Default: true — this is the documented
    /// product behaviour the user asked for.
    @Published public var restoreOnSpaceSwitch: Bool = true
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
        self.enableSpaceScreenshots = UserDefaults.standard.bool(forKey: Self.enableSpaceScreenshotsKey)
        self.enableSnapshotHistoryThumbnails = UserDefaults.standard.bool(forKey: Self.enableHistoryThumbnailsKey)
    }
}
