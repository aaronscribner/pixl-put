import AppKit
import SwiftUI
import Combine
import PixlPutCore

/// The license/paywall window. Presented when:
///   - State is `.noLicense` and no trial has started (first run)
///   - State is `.trialExpired` or `.hardExpired(*)` (force user action)
///   - User clicks "Manage license…" in the menu
///
/// Subscribes to `LicenseValidator.statePublisher` so the content updates
/// live as activation / trial / validation results arrive.
public enum PaywallWindow {

    public static func makeWindowController(lifecycle: AppLifecycle) -> NSWindowController {
        let view = PaywallView(validator: lifecycle.licenseValidator)
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = "PixlPut License"
        window.setContentSize(NSSize(width: 560, height: 480))
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        return NSWindowController(window: window)
    }
}

/// External URL the "Buy License" button opens. The marketing site (Astro,
/// see `marketing/`) hosts the LemonSqueezy checkout overlay there.
private let buyURL = URL(string: "https://pixput.app/buy")!

private struct PaywallView: View {

    @ObservedObject var validator: LicenseValidator

    @State private var licenseKey: String = ""
    @State private var isWorking: Bool = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider()
            statusBlock
            Divider()
            activationBlock
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout)
            }
            if let successMessage {
                Text(successMessage).foregroundStyle(.green).font(.callout)
            }
            Spacer()
            footer
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 480)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading) {
                Text("PixlPut").font(.title).bold()
                Text("License & trial")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch validator.state {
            case .noLicense:
                Text("No license active.").font(.headline)
                Text("Start a free 14-day trial below, or enter a license key.")
                    .foregroundStyle(.secondary)
            case .trial(let exp):
                Text("Trial — \(daysRemaining(until: exp)) days left").font(.headline)
                Text("Full features unlocked through \(formatted(exp)).")
                    .foregroundStyle(.secondary)
            case .trialExpired:
                Text("Trial expired.").font(.headline).foregroundStyle(.orange)
                Text("Enter a license key below to keep using PixlPut.")
                    .foregroundStyle(.secondary)
            case .active(let lic, _):
                Text("Active — \(lic.plan)").font(.headline).foregroundStyle(.green)
                Text("\(lic.customer_email) · 1 of \(lic.max_devices) devices")
                    .foregroundStyle(.secondary)
            case .graceOverdue(let lic, let lastValidated):
                Text("License is offline — limited features").font(.headline).foregroundStyle(.orange)
                Text("Last verified \(formatted(lastValidated)). Reconnect to keep auto-features running.")
                    .foregroundStyle(.secondary)
                Text(lic.customer_email).font(.caption).foregroundStyle(.secondary)
            case .hardExpired(let reason):
                Text("License blocked").font(.headline).foregroundStyle(.red)
                Text(reasonText(reason)).foregroundStyle(.secondary)
            }
        }
    }

    private var activationBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("License key").font(.subheadline).bold()
            HStack {
                TextField("XXXX-XXXX-XXXX-XXXX", text: $licenseKey)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isWorking)
                Button("Activate") {
                    Task { await runActivate() }
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(isWorking || licenseKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack {
                if case .noLicense = validator.state {
                    Button("Start 14-day Trial") {
                        Task { await runStartTrial() }
                    }
                    .disabled(isWorking)
                }
                Button("Buy License") {
                    NSWorkspace.shared.open(buyURL)
                }
                Button("Restore Validation") {
                    Task { await runRevalidate() }
                }
                .disabled(isWorking)
                Spacer()
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Privacy: PixlPut only contacts the license server (api.pixput.app). No telemetry, no analytics, no off-device window data.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    private func runActivate() async {
        clearMessages()
        isWorking = true
        defer { isWorking = false }
        do {
            try await validator.activate(licenseKey: licenseKey.trimmingCharacters(in: .whitespaces))
            successMessage = "Activated. You can close this window."
            licenseKey = ""
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    private func runStartTrial() async {
        clearMessages()
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await validator.startTrial()
            successMessage = "Trial started."
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    private func runRevalidate() async {
        clearMessages()
        isWorking = true
        defer { isWorking = false }
        await validator.revalidateNow()
        successMessage = "Validation refreshed."
    }

    private func clearMessages() {
        errorMessage = nil
        successMessage = nil
    }

    // MARK: Helpers

    private func friendlyError(_ error: Error) -> String {
        if let api = error as? LicenseAPIClient.APIError {
            switch api {
            case .httpStatus(404, _): return "Unknown or revoked license key."
            case .httpStatus(409, _): return "Device limit reached. Release a device from another machine first."
            case .httpStatus(403, _): return "License expired."
            case .httpStatus(let code, let body):
                return "Server error \(code): \(body.prefix(120))"
            case .signatureVerificationFailed:
                return "License signature didn't verify — server may be misconfigured. Contact support."
            case .nonceMismatch:
                return "Response failed replay check. Try again."
            case .transport(let msg): return "Network error: \(msg)"
            case .decodingFailed(let msg): return "Bad server response: \(msg)"
            case .malformedURL: return "Internal configuration error."
            }
        }
        if let verr = error as? LicenseVerifier.VerificationError {
            switch verr {
            case .publicKeyNotConfigured:
                return "This build wasn't configured with a license public key. Replace the placeholder in LicenseVerifier.swift before shipping."
            case .publicKeyMalformed: return "Public key is malformed."
            case .signatureMalformed: return "Server returned a malformed signature."
            case .signatureMismatch: return "Signature verification failed."
            case .payloadEncodingFailed: return "Failed to encode license payload."
            }
        }
        return String(describing: error)
    }

    private func reasonText(_ reason: LicenseState.HardExpiredReason) -> String {
        switch reason {
        case .payloadExpiresAtPassed: return "Your license has passed its expiry date."
        case .revoked: return "This license was revoked. Contact support if this is unexpected."
        case .unknownToServer: return "The server doesn't recognize this license."
        case .graceWindowExceeded: return "Couldn't reach the license server in too long. Reconnect to validate."
        case .machineLimitExceeded: return "This device isn't activated. Use 'Manage devices' to release a slot from another machine."
        }
    }

    private func daysRemaining(until: Date) -> Int {
        max(0, Calendar.current.dateComponents([.day], from: Date(), to: until).day ?? 0)
    }

    private func formatted(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }
}
