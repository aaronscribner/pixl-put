import AppKit
import SwiftUI
import PixlPutCore

/// First-run onboarding. Two-step flow:
///   1. Grant Accessibility (mandatory).
///   2. Tour — explains the auto-capture model and that the user is on a
///      14-day trial (or licensed). Sets expectations: just use your Mac
///      normally, PixlPut handles the rest.
///
/// Step 2 (per-app deep identity) is intentionally NOT in the mandatory
/// flow — it's an optional power-user feature behind a Settings toggle.
public enum OnboardingWindow {

    public static func makeWindowController(lifecycle: AppLifecycle) -> NSWindowController {
        let view = OnboardingView(lifecycle: lifecycle)
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = "Welcome to PixlPut"
        window.setContentSize(NSSize(width: 560, height: 460))
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        return NSWindowController(window: window)
    }
}

private struct OnboardingView: View {
    let lifecycle: AppLifecycle
    @State private var hasAX: Bool = false
    @State private var step: Step = .accessibility
    @ObservedObject private var validator: LicenseValidator

    init(lifecycle: AppLifecycle) {
        self.lifecycle = lifecycle
        self.validator = lifecycle.licenseValidator
    }

    enum Step { case accessibility, tour }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            switch step {
            case .accessibility: accessibilityStep
            case .tour: tourStep
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 560, height: 460)
        .onAppear { refresh() }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in refresh() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading) {
                Text("PixlPut").font(.title).bold()
                Text("Remembers where every window was — and puts each one back.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Step 1

    private var accessibilityStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Step 1 of 2 · Grant Accessibility")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("Grant Accessibility permission").font(.headline)
            Text("PixlPut needs the macOS Accessibility permission to read and move windows. Without it, capture and restore can't work. No data leaves your machine.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)

            HStack {
                if hasAX {
                    Label("Granted", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Continue") { step = .tour }
                        .keyboardShortcut(.return)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Open System Settings…") {
                        lifecycle.permissions.openAccessibilitySettings()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Request prompt") {
                        _ = lifecycle.permissions.requestAccessibility()
                        refresh()
                    }
                    Spacer()
                }
            }

            if !hasAX {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Already added PixlPut but it still says missing?", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.bold()).foregroundStyle(.orange)
                        Text("Unsigned development builds get a new code identity on every rebuild, so the existing entry in Accessibility no longer matches.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Fix: in System Settings, toggle the existing **PixlPut** entry **OFF**, wait a second, then toggle it back **ON**. Permission re-binds to the new binary.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: Step 2

    private var tourStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Step 2 of 2 · How PixlPut works").font(.subheadline).foregroundStyle(.secondary)

            licenseStatusBlock

            tourRow(icon: "wand.and.stars",
                    title: "Nothing to think about",
                    body: "PixlPut watches sleep, wake, lock, display changes, and Space switches automatically. Just use your Mac.")
            tourRow(icon: "square.stack.3d.up",
                    title: "Capture as you go",
                    body: "Every time you visit a Space, PixlPut silently captures its layout. After one normal workday, all your Spaces are covered.")
            tourRow(icon: "menubar.rectangle",
                    title: "The menu bar is the control panel",
                    body: "Click the PixlPut icon for Capture Now, Restore Now, License, Settings. Manual control whenever you want it.")
            tourRow(icon: "lock.shield",
                    title: "Local-only by design",
                    body: "Snapshots stay on your Mac. The only network call is license validation (api.pixput.app). No telemetry. Ever.")

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Done") { NSApp.keyWindow?.close() }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private var licenseStatusBlock: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: licenseIcon)
                    .font(.title2)
                    .foregroundStyle(licenseTint)
                VStack(alignment: .leading) {
                    Text(licenseTitle).bold()
                    Text(licenseSubtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    private var licenseIcon: String {
        switch validator.state {
        case .trial: return "clock.badge.checkmark"
        case .active: return "checkmark.seal.fill"
        case .noLicense, .trialExpired, .hardExpired: return "key.slash"
        case .graceOverdue: return "wifi.exclamationmark"
        }
    }
    private var licenseTint: Color {
        switch validator.state {
        case .trial: return .blue
        case .active: return .green
        case .graceOverdue: return .orange
        case .noLicense, .trialExpired, .hardExpired: return .red
        }
    }
    private var licenseTitle: String {
        switch validator.state {
        case .trial(let exp):
            let days = max(0, Calendar.current.dateComponents([.day], from: Date(), to: exp).day ?? 0)
            return "You're on a 14-day trial — \(days) days left"
        case .active: return "Licensed"
        case .noLicense: return "No license yet"
        case .trialExpired: return "Trial expired"
        case .graceOverdue: return "License needs validation"
        case .hardExpired: return "License blocked"
        }
    }
    private var licenseSubtitle: String {
        switch validator.state {
        case .trial: return "Full features unlocked. Buy any time from Settings → License."
        case .active: return "Thanks for supporting PixlPut."
        case .noLicense: return "Couldn't reach the license server. Start a trial from Settings → License."
        case .trialExpired: return "Open Settings → License to enter a key or buy."
        case .graceOverdue: return "Reconnect to validate. Manual capture/restore still works."
        case .hardExpired: return "Open Settings → License to fix."
        }
    }

    private func tourRow(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).bold()
                Text(body).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func refresh() {
        hasAX = lifecycle.permissions.currentState() == .accessibilityGranted
        // Auto-advance to the tour as soon as AX flips on — saves a click.
        if hasAX && step == .accessibility {
            step = .tour
        }
    }
}
