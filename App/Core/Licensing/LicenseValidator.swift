import Foundation
import Combine

/// Orchestrates the periodic phone-home, derives `LicenseState`, and pushes
/// updates to subscribers (UI + AppLifecycle gates).
///
/// Lifecycle:
///   - `start()` — runs once at app launch + after activate. Derives state
///     from Keychain and the current clock; if a license is stored, kicks
///     off a `validate()` call to refresh `lastValidatedAt`.
///   - Periodic — re-validates on the cadence the server returned
///     (`next_validate_after`), with a floor of 6h and a ceiling of 24h.
///     Cancellable.
///   - `activate(licenseKey:)` — manual entry from the paywall UI.
///   - `startTrial()` — first launch convenience.
///
/// State is exposed via `statePublisher`. AppLifecycle gates auto-features
/// on this; the paywall window subscribes to know when to present/dismiss.
/// Public-facing device row used by the Manage Devices UI.
public struct DeviceRow: Identifiable, Equatable, Sendable {
    public let machineID: String
    public let activatedAt: Date
    public let lastSeenAt: Date
    public let lastAppVersion: String?
    public var id: String { machineID }
}

@MainActor
public final class LicenseValidator: ObservableObject {

    @Published public private(set) var state: LicenseState = .noLicense

    public var statePublisher: AnyPublisher<LicenseState, Never> {
        $state.eraseToAnyPublisher()
    }

    private let client: LicenseAPIClient
    private let machineID: String
    private var periodicTask: Task<Void, Never>?
    private var nextValidateAfter: Date?

    public init(client: LicenseAPIClient = LicenseAPIClient(), machineID: String = MachineIdentity.current()) {
        self.client = client
        self.machineID = machineID
    }

    /// Expose the machine ID so the Settings UI can mark the current device
    /// in the Manage Devices list.
    public var currentMachineID: String { machineID }

    // MARK: Lifecycle

    /// Recompute state from local storage + clock. Safe to call repeatedly.
    /// Does NOT issue any network request — call `revalidateNow()` for that.
    public func refreshStateLocally(now: Date = Date()) {
        let signed = LicenseKeychain.loadSignedLicense()
        let lastValidated = LicenseKeychain.loadLastValidatedAt()
        let trialStart = LicenseKeychain.loadTrialStartedAt()
        let trialExpiry = LicenseKeychain.loadTrialExpiresAt()
        let derived = LicenseStateDeriver.derive(
            signedLicense: signed,
            lastValidatedAt: lastValidated,
            trialStartedAt: trialStart,
            trialExpiresAt: trialExpiry,
            now: now
        )
        if derived != state {
            DiagnosticLog.write("license",
                "state: \(stateDescription(state)) → \(stateDescription(derived))")
            state = derived
        }
    }

    /// Called once from `AppLifecycle.start()`. Refreshes local state and
    /// fires a background validate if a license is stored.
    public func start() {
        refreshStateLocally()
        startPeriodicValidator()
        Task { [weak self] in
            await self?.revalidateNow()
        }
    }

    public func stop() {
        periodicTask?.cancel()
        periodicTask = nil
    }

    // MARK: Operations

    /// Manual activation from the paywall. On success persists the signed
    /// license + lastValidatedAt and recomputes state.
    public func activate(licenseKey: String) async throws {
        let signed = try await client.activate(licenseKey: licenseKey, machineID: machineID)
        try LicenseKeychain.saveSignedLicense(signed)
        try LicenseKeychain.saveLastValidatedAt(Date())
        DiagnosticLog.write("license", "activate ok: license_id=\(signed.payload.license_id)")
        refreshStateLocally()
    }

    /// Start (or re-fetch) the trial window for this machine.
    @discardableResult
    public func startTrial(email: String? = nil) async throws -> LicenseAPIClient.TrialPayload {
        let payload = try await client.startTrial(machineID: machineID, email: email)
        try LicenseKeychain.saveTrialStartedAt(Date(timeIntervalSince1970: TimeInterval(payload.started_at)))
        try LicenseKeychain.saveTrialExpiresAt(Date(timeIntervalSince1970: TimeInterval(payload.expires_at)))
        DiagnosticLog.write("license",
            "trial started: expires_at=\(payload.expires_at)")
        refreshStateLocally()
        return payload
    }

    /// List devices on the current license. Requires an active license
    /// stored locally — uses its key to authorize the call.
    public func fetchDevices() async throws -> [DeviceRow] {
        guard let signed = LicenseKeychain.loadSignedLicense() else { return [] }
        let entries = try await client.devices(
            licenseKey: signed.payload.license_key, machineID: machineID
        )
        return entries.map {
            DeviceRow(
                machineID: $0.machine_id,
                activatedAt: Date(timeIntervalSince1970: TimeInterval($0.activated_at)),
                lastSeenAt: Date(timeIntervalSince1970: TimeInterval($0.last_seen_at)),
                lastAppVersion: $0.last_app_version
            )
        }
    }

    /// Release another device's slot. Requires an active license stored
    /// locally — the server enforces that the caller is itself activated.
    public func releaseDevice(machineID otherMachineID: String) async throws {
        guard let signed = LicenseKeychain.loadSignedLicense() else { return }
        try await client.deactivate(licenseKey: signed.payload.license_key, machineID: otherMachineID)
    }

    /// Release this machine's slot on the server side and wipe local state.
    public func deactivate() async {
        guard let signed = LicenseKeychain.loadSignedLicense() else { return }
        do {
            try await client.deactivate(licenseKey: signed.payload.license_key, machineID: machineID)
            DiagnosticLog.write("license", "deactivate ok: license_id=\(signed.payload.license_id)")
        } catch {
            DiagnosticLog.write("license", "deactivate network failed: \(error) — wiping local anyway")
        }
        LicenseKeychain.clearSignedLicense()
        LicenseKeychain.clearLastValidatedAt()
        refreshStateLocally()
    }

    /// Force-issue a /validate call right now. Used by the periodic loop
    /// and after wake events.
    public func revalidateNow() async {
        guard let signed = LicenseKeychain.loadSignedLicense() else {
            DiagnosticLog.write("license", "revalidate skipped: no license stored")
            return
        }
        do {
            let result = try await client.validate(
                licenseKey: signed.payload.license_key,
                machineID: machineID
            )
            DiagnosticLog.write("license",
                "validate ok: status=\(result.status.rawValue) next_after=\(result.next_validate_after)")
            switch result.status {
            case .active:
                try LicenseKeychain.saveLastValidatedAt(Date())
                nextValidateAfter = Date(timeIntervalSince1970: TimeInterval(result.next_validate_after))
            case .expired:
                state = .hardExpired(reason: .payloadExpiresAtPassed)
            case .revoked:
                state = .hardExpired(reason: .revoked)
            case .unknown_license:
                state = .hardExpired(reason: .unknownToServer)
            case .machine_limit_exceeded:
                state = .hardExpired(reason: .machineLimitExceeded)
            }
            refreshStateLocally()
        } catch {
            DiagnosticLog.write("license", "validate network failed: \(error) — staying in current state, grace will degrade if it persists")
        }
    }

    // MARK: Periodic loop

    private func startPeriodicValidator() {
        periodicTask?.cancel()
        periodicTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let delay = self?.nextValidationDelay() ?? (6 * 3600)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.revalidateNow()
            }
        }
    }

    /// Seconds until the next validation. Floor 6h, ceiling 24h.
    private func nextValidationDelay() -> TimeInterval {
        let floor: TimeInterval = 6 * 3600
        let ceiling: TimeInterval = 24 * 3600
        guard let next = nextValidateAfter else { return floor }
        let delta = next.timeIntervalSinceNow
        return min(ceiling, max(floor, delta))
    }

    private func stateDescription(_ s: LicenseState) -> String {
        switch s {
        case .noLicense: return "noLicense"
        case .trial(let exp): return "trial(expires=\(exp))"
        case .trialExpired: return "trialExpired"
        case .active: return "active"
        case .graceOverdue: return "graceOverdue"
        case .hardExpired(let r): return "hardExpired(\(r))"
        }
    }
}

