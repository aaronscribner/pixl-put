import * as ed from '@noble/ed25519';
import { sha256 } from '@noble/hashes/sha256';
import { sha512 } from '@noble/hashes/sha512';

// @noble/ed25519 v2 requires a sync sha512 to be set before any sync call.
ed.etc.sha512Sync = (...m) => sha512(ed.etc.concatBytes(...m));

/**
 * Canonical-JSON encoding for cross-platform signing.
 * Both this and Swift's `JSONEncoder(.sortedKeys)` produce the same byte
 * sequence for the same logical object — that's the contract.
 *
 * Rules: sorted keys, no insignificant whitespace, UTF-8. We do NOT support
 * nested objects with non-sortable orderings or numeric quirks — keep the
 * payload shape flat and primitive (string | number | null | boolean).
 */
export function canonicalize(obj: Record<string, unknown>): Uint8Array {
    const sortedKeys = Object.keys(obj).sort();
    const sortedObj: Record<string, unknown> = {};
    for (const k of sortedKeys) {
        sortedObj[k] = obj[k];
    }
    const json = JSON.stringify(sortedObj);
    return new TextEncoder().encode(json);
}

export function b64encode(bytes: Uint8Array): string {
    let binary = '';
    for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
    return btoa(binary);
}

export function b64decode(s: string): Uint8Array {
    const binary = atob(s);
    const out = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
    return out;
}

/** Sign canonical-JSON bytes with the bundled Ed25519 private key. */
export async function signPayload(
    payload: Record<string, unknown>,
    privateKeyB64: string
): Promise<{ sig: string; kid: string }> {
    const privateKey = b64decode(privateKeyB64);
    const publicKey = await ed.getPublicKeyAsync(privateKey);
    const message = canonicalize(payload);
    const signature = await ed.signAsync(message, privateKey);
    const kid = b64encode(sha256(publicKey).slice(0, 8));
    return { sig: b64encode(signature), kid };
}

/** Constant-time signature verification (Ed25519 verify is naturally CT). */
export async function verifyPayload(
    payload: Record<string, unknown>,
    sigB64: string,
    publicKeyB64: string
): Promise<boolean> {
    const message = canonicalize(payload);
    const signature = b64decode(sigB64);
    const publicKey = b64decode(publicKeyB64);
    try {
        return await ed.verifyAsync(signature, message, publicKey);
    } catch {
        return false;
    }
}

/**
 * Lemon Squeezy webhook signature verification.
 * HMAC-SHA256 over the raw body using the webhook signing secret.
 */
export async function verifyLemonSqueezySignature(
    rawBody: string,
    signatureHex: string,
    secret: string
): Promise<boolean> {
    const key = await crypto.subtle.importKey(
        'raw',
        new TextEncoder().encode(secret),
        { name: 'HMAC', hash: 'SHA-256' },
        false,
        ['sign']
    );
    const computed = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(rawBody));
    const computedHex = Array.from(new Uint8Array(computed))
        .map(b => b.toString(16).padStart(2, '0'))
        .join('');
    // Constant-time comparison.
    if (computedHex.length !== signatureHex.length) return false;
    let diff = 0;
    for (let i = 0; i < computedHex.length; i++) {
        diff |= computedHex.charCodeAt(i) ^ signatureHex.charCodeAt(i);
    }
    return diff === 0;
}

/** Generate a ULID-ish identifier. Not strict ULID — sortable + random. */
export function newId(prefix = ''): string {
    const ts = Date.now().toString(36);
    const rand = b64encode(crypto.getRandomValues(new Uint8Array(9)))
        .replace(/[+/=]/g, '')
        .slice(0, 12);
    return prefix ? `${prefix}_${ts}${rand}` : `${ts}${rand}`;
}
