import AppKit
import SwiftUI
import PixlPutCore

/// Guided "Set up deep identity" flow. Lists the scripted bundles PixlPut
/// knows about, highlights which are currently running, and walks the
/// user through granting Automation permission one app at a time.
///
/// Without this wizard, the prompts trickle in unpredictably during
/// real captures — the user clicks Capture, and macOS pops a prompt for
/// the first browser PixlPut probes, no context, no progress indicator.
/// The wizard makes it deliberate: the user can see what they're being
/// asked to grant, in what order, and skip any app they don't want.
@MainActor
public enum DeepIdentityWizard {

    private static var controller: NSWindowController?

    public static func open(lifecycle: AppLifecycle) {
        if let existing = controller, let win = existing.window {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = WizardView(lifecycle: lifecycle)
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = "Set up deep identity"
        window.setContentSize(NSSize(width: 560, height: 480))
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

private struct AppEntry: Identifiable {
    let bundleID: String
    var displayName: String
    var isRunning: Bool
    var status: Status
    var id: String { bundleID }

    enum Status: Equatable {
        case unknown
        case granted(windowCount: Int)
        case denied
        case appNotRunning
        case probing
        case error(String)
    }
}

private struct WizardView: View {
    let lifecycle: AppLifecycle

    @State private var entries: [AppEntry] = []
    @State private var isRunningAll: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "person.2.gobackward")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading) {
                    Text("Set up deep identity").font(.title2).bold()
                    Text("Lets PixlPut tell apart multiple windows of the same app.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What this does")
                        .font(.subheadline.bold())
                    Text("For each app below, PixlPut asks macOS for permission to read non-sensitive identity — the **set** of tab URLs for browsers, the **workspace path** for editors, the **current directory** for terminals. macOS will show a system prompt the first time you grant. You can grant in any order, skip any app, or deny — denied apps fall back to title-and-position matching (Story 3 best-effort).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            HStack {
                Text("Apps PixlPut can integrate with").font(.headline)
                Spacer()
                Button("Refresh") { refresh() }
                    .disabled(isRunningAll)
                Button {
                    Task { await grantAll() }
                } label: {
                    Label("Grant all running", systemImage: "checkmark.seal")
                }
                .disabled(isRunningAll || !entries.contains(where: { $0.isRunning && needsGrant($0.status) }))
                .buttonStyle(.borderedProminent)
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach($entries) { $entry in
                        AppRow(entry: $entry) {
                            Task { await grantOne(bundleID: entry.bundleID) }
                        }
                        Divider()
                    }
                }
            }
            .frame(maxHeight: .infinity)

            HStack {
                Text("Tip: an unsupported browser (Vivaldi, Opera) or terminal (Terminal.app, Warp) isn't listed — those still work, just via window-title matching.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { NSApp.keyWindow?.close() }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 560, height: 480)
        .onAppear { refresh() }
    }

    // MARK: - State

    private func refresh() {
        let bundles = DeepIdentityFetcher.allScriptedBundleIDs()
        let running = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
        entries = bundles.map { id in
            AppEntry(
                bundleID: id,
                displayName: friendlyName(for: id),
                isRunning: running.contains(id),
                status: running.contains(id) ? .unknown : .appNotRunning
            )
        }
    }

    private func friendlyName(for bundleID: String) -> String {
        switch bundleID {
        case "com.brave.Browser":           return "Brave Browser"
        case "com.microsoft.edgemac":       return "Microsoft Edge"
        case "com.google.Chrome":           return "Google Chrome"
        case "company.thebrowser.Browser":  return "Arc"
        case "com.apple.Safari":            return "Safari"
        case "com.apple.dt.Xcode":          return "Xcode"
        case "com.googlecode.iterm2":       return "iTerm2"
        default: return bundleID
        }
    }

    private func needsGrant(_ status: AppEntry.Status) -> Bool {
        switch status {
        case .granted, .denied, .appNotRunning, .probing: return false
        case .unknown, .error: return true
        }
    }

    // MARK: - Probes

    private func grantOne(bundleID: String) async {
        guard let idx = entries.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        entries[idx].status = .probing
        let outcome = await lifecycle.deepIdentityFetcher.probe(bundleID: bundleID)
        switch outcome {
        case .granted(let count):  entries[idx].status = .granted(windowCount: count)
        case .denied:              entries[idx].status = .denied
        case .appNotRunning:       entries[idx].status = .appNotRunning
        case .noScript:            entries[idx].status = .error("No script registered")
        case .error(let m):        entries[idx].status = .error(m)
        }
    }

    private func grantAll() async {
        isRunningAll = true
        defer { isRunningAll = false }
        for entry in entries where entry.isRunning && needsGrant(entry.status) {
            await grantOne(bundleID: entry.bundleID)
        }
    }
}

private struct AppRow: View {
    @Binding var entry: AppEntry
    let onGrant: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName(for: entry.bundleID))
                .font(.title3)
                .frame(width: 24)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.body.weight(.medium))
                statusLine
                    .font(.caption)
            }
            Spacer()
            if entry.isRunning && needsGrantButton {
                Button("Grant") { onGrant() }
                    .disabled(entry.status == .probing)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
    }

    private var needsGrantButton: Bool {
        switch entry.status {
        case .unknown, .error: return true
        default: return false
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch entry.status {
        case .unknown:
            Text("Not yet requested").foregroundStyle(.secondary)
        case .granted(let count):
            Label("Granted — \(count) window(s) visible", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case .denied:
            Label("Denied — falling back to title/ordinal matching", systemImage: "xmark.seal.fill")
                .foregroundStyle(.orange)
        case .appNotRunning:
            Text("App not running — launch it and Refresh").foregroundStyle(.secondary)
        case .probing:
            Label("Requesting…", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        case .error(let m):
            Label("Error: \(m)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private func iconName(for bundleID: String) -> String {
        switch bundleID {
        case "com.brave.Browser",
             "com.microsoft.edgemac",
             "com.google.Chrome",
             "company.thebrowser.Browser",
             "com.apple.Safari":
            return "globe"
        case "com.apple.dt.Xcode":
            return "hammer"
        case "com.googlecode.iterm2":
            return "terminal"
        default:
            return "app.dashed"
        }
    }
}
