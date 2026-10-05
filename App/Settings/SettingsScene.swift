import SwiftUI
import AppKit
import Combine
import PixlPutCore

/// Opens the Settings window. For LSUIElement apps the SwiftUI
/// `Settings { … }` scene + `NSApp.sendAction(showSettingsWindow:)`
/// pattern is unreliable — the action message has nowhere to land when
/// the app has no key window and the activation policy is `.accessory`.
/// We host the SwiftUI panes in an explicit NSWindowController instead
/// (same pattern as `OnboardingWindow`).
@MainActor
public enum SettingsWindowOpener {

    private static var controller: NSWindowController?

    public static func open(lifecycle: AppLifecycle) {
        if let existing = controller, let win = existing.window {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsHost(lifecycle: lifecycle)
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = "PixlPut Settings"
        window.setContentSize(NSSize(width: 620, height: 480))
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        let wc = NSWindowController(window: window)
        controller = wc
        wc.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct SettingsHost: View {
    let lifecycle: AppLifecycle
    var body: some View {
        TabView {
            GeneralPane(lifecycle: lifecycle)
                .tabItem { Label("General", systemImage: "gear") }
            LicensePane(lifecycle: lifecycle)
                .tabItem { Label("License", systemImage: "key.fill") }
            IdentityPane(lifecycle: lifecycle)
                .tabItem { Label("Identity & Apps", systemImage: "person.crop.rectangle") }
            UpdatesPane()
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
            DiagnosticsPane(lifecycle: lifecycle)
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
            AboutPane()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 620, height: 480)
    }
}

// MARK: - General

private struct GeneralPane: View {
    let lifecycle: AppLifecycle
    @ObservedObject var statusModel: MenuBarStatusModel

    init(lifecycle: AppLifecycle) {
        self.lifecycle = lifecycle
        self.statusModel = lifecycle.statusModel
    }

    var body: some View {
        Form {
            Section("Permissions") {
                LabeledContent("Accessibility") {
                    statusModel.hasAccessibilityPermission
                        ? Text("Granted").foregroundStyle(.green)
                        : Text("Missing").foregroundStyle(.orange)
                }
                if !statusModel.hasAccessibilityPermission {
                    Button("Open System Settings…") {
                        lifecycle.permissions.openAccessibilitySettings()
                    }
                }
                LabeledContent("Space awareness") {
                    statusModel.isSpaceAware
                        ? Text("Available").foregroundStyle(.green)
                        : Text("Degraded — private CGS unavailable").foregroundStyle(.orange)
                }
            }

            Section("Behavior") {
                Toggle("Auto-restore on Space switch & wake",
                       isOn: $statusModel.restoreOnSpaceSwitch)
                Text("When ON, PixlPut puts windows back after anything that can displace them: waking from sleep, waking the displays, unlocking, or a display change. The Space on screen is restored right away, and every other Space the first time you visit it afterwards. Later visits leave windows alone, so a window you move stays where you put it until the next wake. Windows already in place aren't touched. When OFF, nothing is moved automatically; restore happens only when you click Restore now. Either way, the saved layout only changes when you click Capture now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Restore after a restart",
                       isOn: $statusModel.restoreAfterRestart)
                Text("When ON and PixlPut starts within 15 minutes of a reboot, it waits for your apps to finish relaunching, then puts every window back on its captured Space and frame, and repeats for apps that appear later. Needs yabai running for per-window moves (scripts/setup-yabai.sh). An ordinary relaunch of PixlPut never moves windows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Snapshot history") {
                HistoryLimitControl()
                Text("Total slots to keep, including the current snapshot. Default 2 — that's the current layout plus one historical rotation. Increase if you want more time-travel history. PixlPut only creates a new historical snapshot when something actually changes (a window moved, opened, closed, or resized) — so a higher limit doesn't mean wasted history on identical states.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct HistoryLimitControl: View {
    @State private var value: Double = {
        let raw = UserDefaults.standard.integer(forKey: SnapshotStore.historyLimitDefaultsKey)
        return Double(raw == 0 ? SnapshotStore.defaultHistoryLimit : raw)
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Total snapshot slots")
                Spacer()
                Text(slotsCaption).monospaced().foregroundStyle(.secondary)
            }
            Slider(value: $value,
                   in: Double(SnapshotStore.minHistoryLimit)...Double(SnapshotStore.maxHistoryLimit),
                   step: 1)
                .onChange(of: value) { _, newValue in
                    UserDefaults.standard.set(Int(newValue), forKey: SnapshotStore.historyLimitDefaultsKey)
                }
        }
    }

    private var slotsCaption: String {
        let n = Int(value)
        if n == 1 { return "1 (current only)" }
        return "\(n) (current + \(n - 1) historical)"
    }
}

// MARK: - License

private struct LicensePane: View {
    let lifecycle: AppLifecycle
    @ObservedObject var validator: LicenseValidator
    @State private var keyEntry: String = ""
    @State private var isWorking: Bool = false
    @State private var message: String?
    @State private var devices: [DeviceRow] = []
    @State private var didLoadDevices: Bool = false

    init(lifecycle: AppLifecycle) {
        self.lifecycle = lifecycle
        self.validator = lifecycle.licenseValidator
    }

    var body: some View {
        Form {
            Section("Status") {
                stateLabel
                if case .active(let lic, let lastValidated) = validator.state {
                    LabeledContent("Plan") { Text(lic.plan) }
                    LabeledContent("Email") { Text(lic.customer_email) }
                    LabeledContent("Last validated") { Text(GeneralRelative.format(lastValidated)) }
                }
                if case .graceOverdue(_, let lastValidated) = validator.state {
                    LabeledContent("Last validated") { Text(GeneralRelative.format(lastValidated)) }
                }
                if case .trial(let exp) = validator.state {
                    LabeledContent("Trial expires") { Text(GeneralRelative.format(exp)) }
                }
            }

            Section("Actions") {
                HStack {
                    TextField("License key", text: $keyEntry)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isWorking)
                    Button("Activate") {
                        Task { await runActivate() }
                    }
                    .disabled(isWorking || keyEntry.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack {
                    Button("Re-validate now") { Task { await runRevalidate() } }
                        .disabled(isWorking)
                    Button("Deactivate this device") { Task { await runDeactivate() } }
                        .disabled(isWorking)
                    Spacer()
                    Button("Buy license") {
                        NSWorkspace.shared.open(URL(string: "https://pixput.app/buy")!)
                    }
                }
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(message.hasPrefix("⚠") ? .orange : .green)
                }
            }

            Section("Devices on this license") {
                if !didLoadDevices {
                    Button("Load devices") { Task { await loadDevices() } }
                        .disabled(!hasActiveLicense || isWorking)
                } else if devices.isEmpty {
                    Text("No other devices.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(devices) { device in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.machineID == validator.currentMachineID
                                     ? "This Mac"
                                     : "Device \(device.machineID.prefix(8))…")
                                Text("Last seen \(GeneralRelative.format(device.lastSeenAt))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if device.machineID != validator.currentMachineID {
                                Button("Release") { Task { await releaseDevice(device) } }
                                    .disabled(isWorking)
                            }
                        }
                    }
                    Button("Refresh") { Task { await loadDevices() } }
                        .disabled(isWorking)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var hasActiveLicense: Bool {
        switch validator.state {
        case .active, .graceOverdue: return true
        default: return false
        }
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch validator.state {
        case .noLicense:
            Label("No license — enter a key or buy", systemImage: "key.slash").foregroundStyle(.orange)
        case .trial:
            Label("Trial active", systemImage: "clock.badge.checkmark").foregroundStyle(.blue)
        case .trialExpired:
            Label("Trial expired", systemImage: "clock.badge.xmark").foregroundStyle(.orange)
        case .active:
            Label("Active", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        case .graceOverdue:
            Label("Active (offline — grace period)", systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
        case .hardExpired(let reason):
            Label("Blocked: \(String(describing: reason))", systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private func runActivate() async {
        message = nil; isWorking = true; defer { isWorking = false }
        do {
            try await validator.activate(licenseKey: keyEntry.trimmingCharacters(in: .whitespaces))
            message = "Activated."
            keyEntry = ""
            didLoadDevices = false
        } catch {
            message = "⚠ \(error)"
        }
    }

    private func runRevalidate() async {
        message = nil; isWorking = true; defer { isWorking = false }
        await validator.revalidateNow()
        message = "Refreshed."
    }

    private func runDeactivate() async {
        message = nil; isWorking = true; defer { isWorking = false }
        await validator.deactivate()
        message = "Deactivated locally."
        didLoadDevices = false
        devices = []
    }

    private func loadDevices() async {
        message = nil; isWorking = true; defer { isWorking = false }
        do {
            devices = try await validator.fetchDevices()
            didLoadDevices = true
        } catch {
            message = "⚠ Couldn't load devices: \(error)"
        }
    }

    private func releaseDevice(_ device: DeviceRow) async {
        message = nil; isWorking = true; defer { isWorking = false }
        do {
            try await validator.releaseDevice(machineID: device.machineID)
            await loadDevices()
            message = "Released."
        } catch {
            message = "⚠ Release failed: \(error)"
        }
    }
}

// MARK: - Identity & Apps

private struct IdentityPane: View {
    let lifecycle: AppLifecycle
    @ObservedObject var statusModel: MenuBarStatusModel
    @State private var showingScreenshotConsent: Bool = false

    init(lifecycle: AppLifecycle) {
        self.lifecycle = lifecycle
        self.statusModel = lifecycle.statusModel
    }

    var body: some View {
        Form {
            Section("Deep identity") {
                Toggle("Identify individual browser/editor windows",
                       isOn: $statusModel.deepIdentityEnabled)
                Text("When OFF (default), PixlPut never asks for Automation permission for any other app. Identity falls back to window title and creation order — fine for single-window apps; less accurate when you have multiple windows of the same browser or editor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if statusModel.deepIdentityEnabled {
                    Button("Open setup wizard…") {
                        DeepIdentityWizard.open(lifecycle: lifecycle)
                    }
                }
            }
            Section("Per-Space screenshots") {
                Toggle("Capture a thumbnail of each Space",
                       isOn: Binding(
                        get: { statusModel.enableSpaceScreenshots },
                        set: { newValue in
                            if newValue && !statusModel.enableSpaceScreenshots {
                                // Flipping ON — show consent BEFORE actually enabling.
                                showingScreenshotConsent = true
                            } else if !newValue {
                                // Flipping OFF — no confirmation. Wipe stored thumbnails.
                                statusModel.enableSpaceScreenshots = false
                                lifecycle.thumbnailStore.deleteAll()
                                DiagnosticLog.write("screenshot",
                                    "user disabled space screenshots; wiped all thumbnails on disk")
                            }
                        }))
                Text("When ON, PixlPut saves a JPEG of each Space when you visit it, so you can visually identify saved layouts. Off by default — requires explicit consent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if statusModel.enableSpaceScreenshots {
                    HStack {
                        Image(systemName: ScreenshotCapturer.hasPermission()
                              ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(ScreenshotCapturer.hasPermission() ? .green : .orange)
                        Text(ScreenshotCapturer.hasPermission()
                             ? "Screen Recording permission granted"
                             : "Screen Recording permission missing — Open System Settings → Privacy & Security → Screen Recording")
                            .font(.caption)
                    }
                    Toggle("Keep thumbnails for every history snapshot",
                           isOn: Binding(
                            get: { statusModel.enableSnapshotHistoryThumbnails },
                            set: { newValue in
                                statusModel.enableSnapshotHistoryThumbnails = newValue
                                if !newValue {
                                    lifecycle.thumbnailStore.deleteAllRotatedThumbnails()
                                    DiagnosticLog.write("screenshot",
                                        "history thumbnails disabled; wiped rotated thumbnails")
                                }
                            }))
                    Text("Off (default): only the latest snapshot has thumbnails — rotated history slots show text metadata only in the Restore Picker. On: each rotated history slot keeps its own thumbnails, so older snapshots are visually identifiable too. Costs more disk (≈1 MB per slot per Space).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section("How windows are recognized after a restart") {
                AppRuleRow(icon: "globe", name: "Brave, Edge, Chrome, Arc, Safari",
                           desc: "By the open tab — needs the setting above")
                AppRuleRow(icon: "chevron.left.forwardslash.chevron.right",
                           name: "VS Code, Cursor, VSCodium, Windsurf, JetBrains IDEs, Xcode",
                           desc: "By workspace or project")
                AppRuleRow(icon: "doc.text", name: "Terminal, TextEdit, Preview and other document apps",
                           desc: "By folder or document")
                AppRuleRow(icon: "macwindow", name: "Every other app (Teams, Outlook, Messages, Firefox…)",
                           desc: "By an exact, unique title — or as the app's only window")
                Text("Until an app quits, PixlPut recognizes each of its windows exactly. After the app or your Mac restarts, it relies on the rules above. When an app has several windows it can't tell apart, PixlPut leaves them where they are rather than guess.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showingScreenshotConsent) {
            ScreenshotConsentSheet(
                onConfirm: {
                    showingScreenshotConsent = false
                    statusModel.enableSpaceScreenshots = true
                    DiagnosticLog.write("screenshot",
                        "user consented; requesting Screen Recording permission")
                    _ = ScreenshotCapturer.requestPermission()
                },
                onCancel: {
                    showingScreenshotConsent = false
                    // Toggle was visually flipped by the Binding before the sheet showed; reset.
                    statusModel.enableSpaceScreenshots = false
                }
            )
        }
    }
}

/// Modal consent sheet. The user must check the acknowledgement checkbox
/// AND click "I understand, enable screenshots" before the toggle flips
/// on and the OS permission prompt fires. Per project constitution: any
/// new data-capture surface needs explicit informed consent.
private struct ScreenshotConsentSheet: View {
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @State private var acknowledged: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading) {
                    Text("Enable per-Space screenshots?").font(.title2).bold()
                    Text("Read this carefully before continuing.")
                        .foregroundStyle(.secondary)
                }
            }
            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Label("What gets captured", systemImage: "info.circle")
                    .font(.headline)
                Text("PixlPut will capture a JPEG image of your primary display every time you switch to a Space and dwell there for ~5 seconds. The image is saved locally next to your snapshot files in `~/Library/Application Support/DisplayMaid-Next/snapshots/`. No image ever leaves your Mac.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("What might be in the image", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("Screenshots capture **everything visible** on your screen at the moment of capture. That can include:")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    bulletRow("Bank account balances, statements, transaction details")
                    bulletRow("Email subject lines and message previews")
                    bulletRow("Passwords or 2FA codes visible in a browser tab")
                    bulletRow("Private messages, calendar events, health data")
                    bulletRow("Anything else displayed on your screen at the time")
                }
                Text("Anyone with access to your Mac (or a backup of it) could view these images. If you have any concerns, leave this off.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Toggle(isOn: $acknowledged) {
                Text("I understand that screenshots may capture sensitive personal, financial, or private information, and I consent to PixlPut saving these images locally on this Mac.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                Button("I understand, enable screenshots") { onConfirm() }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .disabled(!acknowledged)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func bulletRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").font(.callout)
            Text(text).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 12)
    }
}

private struct AppRuleRow: View {
    let icon: String
    let name: String
    let desc: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: icon).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).fixedSize(horizontal: false, vertical: true)
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Updates

private struct UpdatesPane: View {
    @State private var autoCheck: Bool = Updates.shared.automaticallyChecksForUpdates

    var body: some View {
        Form {
            Section("Auto-update") {
                Toggle("Check for updates automatically",
                       isOn: Binding(
                        get: { autoCheck },
                        set: { newVal in
                            autoCheck = newVal
                            Updates.shared.automaticallyChecksForUpdates = newVal
                        }))
                Text("Sparkle checks once per day. New versions are signed with our EdDSA key; an update with a bad signature will be rejected.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Manual") {
                HStack {
                    Button("Check now") { Updates.shared.checkForUpdates() }
                    Spacer()
                    Text(versionString).foregroundStyle(.secondary).monospaced()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(short) (\(build))"
    }
}

// MARK: - Diagnostics

private struct DiagnosticsPane: View {
    let lifecycle: AppLifecycle
    @State private var snapshots: [String] = []
    @State private var spaceThumbnails: [Int: NSImage] = [:]

    var body: some View {
        Form {
            if !spaceThumbnails.isEmpty {
                Section("Per-Space thumbnails") {
                    Text("Click a thumbnail to see it full size.")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(spaceThumbnails.keys.sorted(), id: \.self) { idx in
                                if let img = spaceThumbnails[idx] {
                                    ZoomableThumbnail(
                                        image: img,
                                        caption: "Space \(idx + 1)",
                                        thumbHeight: 140
                                    )
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            Section("Sleep / wake / Spaces") {
                LabeledContent("Last sleep") {
                    Text(lifecycle.eventLog.lastSleepAt.map { GeneralRelative.format($0) } ?? "—")
                        .foregroundStyle(.secondary).monospaced()
                }
                LabeledContent("Last wake") {
                    Text(lifecycle.eventLog.lastWakeAt.map { GeneralRelative.format($0) } ?? "—")
                        .foregroundStyle(.secondary).monospaced()
                }
                let visits = lifecycle.eventLog.allSpaceVisits().sorted { $0.key < $1.key }
                ForEach(visits, id: \.key) { (idx, date) in
                    LabeledContent("Space \(idx + 1) — last visited") {
                        Text(GeneralRelative.format(date))
                            .foregroundStyle(.secondary).monospaced()
                    }
                }
            }
            Section("Snapshots") {
                if snapshots.isEmpty {
                    Text("No snapshots yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(snapshots, id: \.self) { Text($0).monospaced().font(.caption) }
                }
                HStack {
                    Button("Refresh") { refreshSnapshots() }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([lifecycle.paths.snapshots])
                    }
                }
            }
            Section("Logs") {
                Text("Diagnostic log: ~/Library/Application Support/DisplayMaid-Next/logs/diagnostic.log")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open logs folder in Finder") {
                    let logsPath = lifecycle.paths.snapshots.deletingLastPathComponent().appendingPathComponent("logs")
                    NSWorkspace.shared.activateFileViewerSelecting([logsPath])
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { refreshSnapshots() }
    }

    private func refreshSnapshots() {
        let dir = lifecycle.paths.snapshots
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        snapshots = files.filter { $0.hasSuffix(".plist") }.sorted()
        loadThumbnails()
    }

    private func loadThumbnails() {
        // Parse `<config>.space<N>.thumb.jpg` filenames to discover which
        // Spaces have thumbnails available. Decode each as NSImage for the
        // gallery row above. Cheap (jpegs are ~150-400 KB each).
        var found: [Int: NSImage] = [:]
        let dir = lifecycle.paths.snapshots
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in files where name.contains(".thumb.jpg") {
            // Extract spaceIndex from the filename.
            // Pattern: <id>.space<N>.thumb.jpg
            guard let spaceRange = name.range(of: ".space") else { continue }
            let afterSpace = name[spaceRange.upperBound...]
            guard let dotIdx = afterSpace.firstIndex(of: ".") else { continue }
            let numStr = String(afterSpace[..<dotIdx])
            guard let idx = Int(numStr) else { continue }
            let url = dir.appendingPathComponent(name)
            if let img = NSImage(contentsOf: url) {
                found[idx] = img
            }
        }
        spaceThumbnails = found
    }
}

// MARK: - About

private struct AboutPane: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)
            Text("PixlPut").font(.title).bold()
            Text(versionString).foregroundStyle(.secondary).monospaced()
            Text("Window memory for macOS")
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 20) {
                Link("Website", destination: URL(string: "https://pixput.app")!)
                Link("Privacy", destination: URL(string: "https://pixput.app/privacy")!)
                Link("Changelog", destination: URL(string: "https://pixput.app/changelog")!)
                Link("Support", destination: URL(string: "mailto:support@pixput.app")!)
            }
            Spacer()
            Text("© 2026 Cerebral Juice Co.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(short) (\(build))"
    }
}

// MARK: - Helpers

private enum GeneralRelative {
    static func format(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}
