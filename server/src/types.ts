// Shared types. The LicensePayload shape MUST match the Swift `LicensePayload`
// struct exactly — both sides canonicalize via sorted-key JSON before signing.

export interface LicensePayload {
    /** Schema version. Bump if fields change. */
    v: 1;
    /** Server-issued ULID, primary key in our DB. */
    license_id: string;
    /** Customer-visible key (LemonSqueezy or our format). */
    license_key: string;
    customer_email: string;
    plan: string;
    /** SHA256(IOPlatformUUID + salt) — bound to one machine on activate. */
    machine_id: string;
    /** Unix seconds. */
    issued_at: number;
    /** Unix seconds. null/undefined = perpetual. */
    expires_at: number | null;
    max_devices: number;
}

export interface SignedEnvelope<T> {
    /** Canonical-JSON of the payload (sorted keys, no whitespace, UTF-8). */
    payload: T;
    /** base64 Ed25519 signature over the canonical-JSON bytes. */
    sig: string;
    /** base64 Ed25519 public key fingerprint (SHA256 prefix-8). For key rotation diagnostics. */
    kid: string;
}

export interface ValidateRequest {
    license_key: string;
    machine_id: string;
    /** base64 32-byte random nonce. Server echoes back, signed. */
    nonce: string;
    /** Client clock (unix seconds). For drift detection only — never trusted for expiry. */
    client_ts: number;
    app_version?: string;
}

export interface ValidateResponse {
    status: 'active' | 'expired' | 'revoked' | 'machine_limit_exceeded' | 'unknown_license';
    nonce_echo: string;
    server_ts: number;
    expires_at: number | null;
    /** Suggested next validation time (server-controlled cadence). */
    next_validate_after: number;
}

export interface ActivateRequest {
    license_key: string;
    machine_id: string;
    nonce: string;
    client_ts: number;
    app_version?: string;
}

export interface ActivateResponse {
    /** Signed license payload — client persists this in Keychain. */
    license: SignedEnvelope<LicensePayload>;
    nonce_echo: string;
    server_ts: number;
}

export interface Env {
    DB: D1Database;
    ED25519_PRIVATE_KEY: string;            // base64
    LEMONSQUEEZY_API_KEY?: string;
    LEMONSQUEEZY_WEBHOOK_SECRET?: string;
}
