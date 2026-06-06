import AppKit
import Combine
import PixlPutCore

/// Owns the `NSStatusItem`. Builds the menu, reflects `MenuBarStatusModel`
/// into menu titles, routes user actions back to `AppLifecycle`.
@MainActor
public final class MenuBarController {

    private let statusItem: NSStatusItem
    private let statusModel: MenuBarStatusModel
    private let lifecycle: AppLifecycle
    private var cancellables: Set<AnyCancellable> = []
    private weak var onboardingWindow: NSWindow?
    private var paywallController: NSWindowController?
    private var restorePickerController: NSWindowController?

    public init(statusModel: MenuBarStatusModel, lifecycle: AppLifecycle) {
        self.statusModel = statusModel
        self.lifecycle = lifecycle
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton()
        configureMenu()
        observeModel()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "PixlPut")
        button.image?.isTemplate = true
        button.toolTip = "PixlPut — window memory"
    }

    private func configureMenu() {
        rebuildMenu()
    }

    private func observeModel() {
        statusModel.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
        // Rebuild on license state changes too — so "Trial — N days left"
        // and "License blocked" update without a manual menu open.
        lifecycle.licenseValidator.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Status header
        let statusHeader = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        statusHeader.isEnabled = false
        menu.addItem(statusHeader)

        // License/trial status line — clickable, opens the License pane.
        if let licenseLine = licenseStatusLine() {
            let item = NSMenuItem(title: licenseLine, action: #selector(openLicense), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        if let lastCap = statusModel.lastCapture {
            let item = NSMenuItem(
                title: "Last capture: \(Self.relative(lastCap)) — \(statusModel.lastCaptureWindowCount) windows",
                action: nil, keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
        }
        if let lastRest = statusModel.lastRestore {
            var summary = "Last restore: \(Self.relative(lastRest)) — \(statusModel.lastRestoreMoved) moved"
            if statusModel.lastRestoreSkipped > 0 {
                summary += ", \(statusModel.lastRestoreSkipped) skipped"
            }
            if statusModel.lastRestoreDisplaced > 0 {
                summary += ", \(statusModel.lastRestoreDisplaced) displaced"
            }
            let item = NSMenuItem(title: summary, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        // Last error — clickable, opens an NSAlert with full details.
        if let err = statusModel.lastError {
            let truncated = err.count > 80 ? String(err.prefix(77)) + "…" : err
            let item = NSMenuItem(
                title: "⚠ \(truncated)",
                action: #selector(showLastError), keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Actions
        let capture = NSMenuItem(title: "Capture now", action: #selector(captureNow), keyEquivalent: "")
        capture.target = self
        menu.addItem(capture)

        let restore = NSMenuItem(title: "Restore now", action: #selector(restoreNow), keyEquivalent: "")
        restore.target = self
        menu.addItem(restore)

        // Restore Spaces — re-home windows that ended up on the wrong Space
        // (e.g. after an app restart), then restore frames per Space.
        let restoreSpaces = NSMenuItem(title: "Restore Spaces", action: #selector(restoreSpacesAction), keyEquivalent: "")
        restoreSpaces.target = self
        menu.addItem(restoreSpaces)

        // Restore from history… — opens a picker so the user can choose
        // an older rotated snapshot instead of "the latest one".
        let restoreFrom = NSMenuItem(title: "Restore from history…", action: #selector(openRestorePicker), keyEquivalent: "")
        restoreFrom.target = self
        menu.addItem(restoreFrom)

        // Master snapshot: save (always available) + restore (only if one
        // exists for the current display configuration).
        let configID = lifecycle.displayEnumerator.configurationID()
        let hasMaster = lifecycle.snapshotStore.hasMaster(forConfigurationID: configID)

        let saveMaster = NSMenuItem(
            title: hasMaster ? "Replace master setup" : "Save as master setup",
            action: #selector(saveMaster), keyEquivalent: ""
        )
        saveMaster.target = self
        menu.addItem(saveMaster)

        if hasMaster {
            let restoreMaster = NSMenuItem(title: "Restore master setup", action: #selector(restoreMaster), keyEquivalent: "")
            restoreMaster.target = self
            menu.addItem(restoreMaster)
        }

        let pauseTitle = statusModel.isAutoCapturePaused ? "Resume auto-capture" : "Pause auto-capture"
        let pause = NSMenuItem(title: pauseTitle, action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)

        menu.addItem(.separator())

        // Permissions / about
        if !statusModel.hasAccessibilityPermission {
            let perm = NSMenuItem(title: "Grant Accessibility permission…", action: #selector(grantAccessibility), keyEquivalent: "")
            perm.target = self
            menu.addItem(perm)
        }

        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        let wizard = NSMenuItem(title: "Set up deep identity…", action: #selector(openDeepIdentityWizard), keyEquivalent: "")
        wizard.target = self
        menu.addItem(wizard)

        let license = NSMenuItem(title: "License…", action: #selector(openLicense), keyEquivalent: "")
        license.target = self
        menu.addItem(license)

        menu.addItem(.separator())

        let checkUpdates = NSMenuItem(title: "Check for updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        checkUpdates.target = self
        menu.addItem(checkUpdates)

        let quit = NSMenuItem(title: "Quit PixlPut", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func licenseStatusLine() -> String? {
        // Only show a line when it's actionable info — active licenses don't
        // need to be reminded; trials and problems do.
        switch lifecycle.licenseValidator.state {
        case .trial(let exp):
            let days = max(0, Calendar.current.dateComponents([.day], from: Date(), to: exp).day ?? 0)
            return "Trial — \(days) day\(days == 1 ? "" : "s") left"
        case .noLicense:
            return "No license — click to set up"
        case .trialExpired:
            return "⚠ Trial expired — click to buy"
        case .graceOverdue:
            return "⚠ License needs validation"
        case .hardExpired:
            return "⚠ License blocked — click to fix"
        case .active:
            return nil
        }
    }

    private func statusLine() -> String {
        if !statusModel.hasAccessibilityPermission {
            return "⚠ Accessibility permission required"
        }
        if statusModel.isAutoCapturePaused {
            return "Paused"
        }
        return statusModel.isSpaceAware ? "Active — Spaces aware" : "Active — Spaces N/A"
    }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Actions

    @objc private func captureNow() {
        lifecycle.captureNow()
    }

    @objc private func restoreNow() {
        lifecycle.restoreNow()
    }

    @objc private func restoreSpacesAction() {
        lifecycle.restoreSpaces()
    }

    @objc private func togglePause() {
        lifecycle.togglePauseAutoCapture()
    }

    @objc private func saveMaster() {
        lifecycle.saveAsMaster()
    }

    @objc private func restoreMaster() {
        lifecycle.restoreMaster()
    }

    @objc private func openRestorePicker() {
        if restorePickerController == nil {
            restorePickerController = RestorePickerWindow.makeWindowController(lifecycle: lifecycle)
        }
        restorePickerController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showLastError() {
        guard let err = statusModel.lastError else { return }
        let alert = NSAlert()
        alert.messageText = "PixlPut"
        alert.informativeText = err
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Dismiss")
        alert.addButton(withTitle: "Copy details")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(err, forType: .string)
        }
        // Clear the surfaced error once the user acknowledges it.
        statusModel.lastError = nil
    }

    @objc private func grantAccessibility() {
        _ = lifecycle.permissions.requestAccessibility()
    }

    @objc private func openSettings() {
        SettingsWindowOpener.open(lifecycle: lifecycle)
    }

    @objc private func openDeepIdentityWizard() {
        DeepIdentityWizard.open(lifecycle: lifecycle)
    }

    @objc private func openLicense() {
        if paywallController == nil {
            paywallController = PaywallWindow.makeWindowController(lifecycle: lifecycle)
        }
        paywallController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func checkForUpdates() {
        Updates.shared.checkForUpdates()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Show the first-run onboarding window. Reused after AX permission
    /// revoke too.
    public func showOnboarding() {
        if let existing = onboardingWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = OnboardingWindow.makeWindowController(lifecycle: lifecycle)
        onboardingWindow = controller.window
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
