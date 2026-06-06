import Foundation

/// Derived license state. Computed fresh from Keychain + the current clock
/// on every launch and after every validate call. **Never cache this as a
/// stored property or simple Bool** — that's the first thing a cracker
/// patches. Always re-derive from the signed payload + timestamps.
public enum LicenseState: Equatable, Sendable {

    /// No license ever activated, no trial started.
    case noLicense

    /// Trial in progress.
    case trial(expiresAt: Date)

    /// Trial ran out.
    case trialExpired

    /// Active paid license. Last validated recently (within grace window).
    case active(license: LicensePayload, lastValidatedAt: Date)

    /// Active paid license but the last successful /validate is older than
    /// the grace window. Core features should degrade (per spec: disable
    /// auto-restore but keep manual capture/restore working).
    case graceOverdue(license: LicensePayload, lastValidatedAt: Date)

    /// Paid license but it's now hard-expired (way past grace window OR
    /// server returned `revoked`/`expired` on last validate). Disable
    /// everything except the buy/renew path.
    case hardExpired(reason: HardExpiredReason)

    public enum HardExpiredReason: Equatable, Sendable {
        case payloadExpiresAtPassed
        case revoked
        case unknownToServer
        case graceWindowExceeded
        case machineLimitExceeded
    }

    /// Should auto-restore + on-startup-restore run?
    /// Active and trial states: yes. Grace and beyond: no.
    public var allowsAutoFeatures: Bool {
        switch self {
        case .active, .trial: return true
        default: return false
        }
    }

    /// Should manual Capture/Restore still work?
    /// Active, trial, and grace: yes. Hard-expired and missing: no.
    public var allowsManualFeatures: Bool {
        switch self {
        case .active, .trial, .graceOverdue: return true
        default: return false
        }
    }

    /// Should the paywall window be presented at launch?
    public var requiresPaywall: Bool {
        switch self {
        case .noLicense, .trialExpired, .hardExpired: return true
        default: return false
        }
    }
}

/// Pure-function state derivation. Inputs are everything we need from the
/// outside world; the function itself is deterministic. Tests can pass
/// arbitrary clocks and Keychain contents without mocking.
public enum LicenseStateDeriver {

    /// Grace window: how long after `lastValidatedAt` we still treat the
    /// license as active before degrading to `graceOverdue`. 14 days is the
    /// recommended trade-off — long enough to survive travel/network
    /// outages, short enough to bite pirates running offline.
    public static let graceWindowSeconds: TimeInterval = 14 * 24 * 3600

    /// Hard-expire window: how long after `lastValidatedAt` we give up on
    /// the grace and refuse all features. 30 days past grace = 44 days
    /// since last successful validate.
    public static let hardExpireAfterGraceSeconds: TimeInterval = 30 * 24 * 3600

    public static func derive(
        signedLicense: SignedLicense?,
        lastValidatedAt: Date?,
        trialStartedAt: Date?,
        trialExpiresAt: Date?,
        now: Date = Date()
    ) -> LicenseState {

        // Trial path first — if a trial was issued, it dominates until a
        // real license is activated.
        if let signedLicense {
            // Verify the signature before trusting any field.
            guard (try? LicenseVerifier.verify(signedLicense)) != nil else {
                // Tampered or signed with a key we don't recognize.
                return .hardExpired(reason: .revoked)
            }
            let payload = signedLicense.payload
            if let exp = payload.expires_at, TimeInterval(exp) < now.timeIntervalSince1970 {
                return .hardExpired(reason: .payloadExpiresAtPassed)
            }
            guard let lastValidated = lastValidatedAt else {
                // We have a verified license but never successfully phoned
                // home. Treat as in-grace from `issued_at`.
                let issued = Date(timeIntervalSince1970: TimeInterval(payload.issued_at))
                return classifyAgainstClock(payload: payload, lastValidated: issued, now: now)
            }
            return classifyAgainstClock(payload: payload, lastValidated: lastValidated, now: now)
        }

        if let trialExpiresAt {
            if now < trialExpiresAt {
                return .trial(expiresAt: trialExpiresAt)
            }
            return .trialExpired
        }
        _ = trialStartedAt  // (reserved for future trial-reset detection)
        return .noLicense
    }

    private static func classifyAgainstClock(
        payload: LicensePayload, lastValidated: Date, now: Date
    ) -> LicenseState {
        let sinceValidate = now.timeIntervalSince(lastValidated)
        if sinceValidate <= graceWindowSeconds {
            return .active(license: payload, lastValidatedAt: lastValidated)
        }
        if sinceValidate <= (graceWindowSeconds + hardExpireAfterGraceSeconds) {
            return .graceOverdue(license: payload, lastValidatedAt: lastValidated)
        }
        return .hardExpired(reason: .graceWindowExceeded)
    }
}
