import SwiftUI
import AppKit
import PixlPutCore

/// `@main` entry. `NSApplicationDelegateAdaptor` wires the AppDelegate
/// which owns the entire lifecycle. `LSUIElement` in `Info.plist` keeps
/// the Dock icon hidden. The SwiftUI body declares an empty `Settings { }`
/// scene only because SwiftUI's `App` protocol requires at least one
/// Scene; the actual Settings window is hosted via `SettingsWindowOpener`
/// (see `App/Settings/SettingsScene.swift`) because the SwiftUI Settings
/// scene + `showSettingsWindow:` selector doesn't deliver reliably to
/// LSUIElement/.accessory apps.
@main
struct DisplayMaidApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {

    @Published var lifecycle: AppLifecycle?
    private var menuBar: MenuBarController?
    private var permissionPoll: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let lc = try AppLifecycle()
            self.lifecycle = lc
            self.menuBar = MenuBarController(statusModel: lc.statusModel, lifecycle: lc)
            lc.start()
            startPermissionPolling()

            // First-run: if AX is missing, show onboarding right away.
            if lc.permissions.currentState() != .accessibilityGranted {
                menuBar?.showOnboarding()
            }
            LoggerRegistry.app.log(.info, "PixlPut launched (Spaces aware = \(lc.spaceResolver.isSpaceAware))")
        } catch {
            LoggerRegistry.app.log(.error, "Launch failed: \(error)")
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        lifecycle?.stop()
        permissionPoll?.invalidate()
        permissionPoll = nil
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func startPermissionPolling() {
        // Apple doesn't fire a notification when AX is granted — poll
        // every 3 seconds to catch the user's grant action. The initial
        // state was already synced by `AppLifecycle.start()` before this
        // timer was created, so the menu reads the correct value from
        // the moment it's first opened.
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.lifecycle?.refreshPermissionState()
            }
        }
    }
}
