// Sign a hand-crafted LicensePayload using the Ed25519 private key.
// Useful for end-to-end testing the app's LicenseVerifier WITHOUT needing
// the full Lemon Squeezy → webhook → /activate flow.
//
// Usage:
//   ED25519_PRIVATE_KEY=<base64> pnpm license:sign-test --email you@example.com --machine <hash>
//
// Pipe the JSON output into the Swift test harness or paste into Keychain
// via a debug menu in PixPut.

import * as ed from '@noble/ed25519';
import { sha256 } from '@noble/hashes/sha256';
import { sha512 } from '@noble/hashes/sha512';
import { parseArgs } from 'node:util';

ed.etc.sha512Sync = (...m) => sha512(ed.etc.concatBytes(...m));

const { values } = parseArgs({
    options: {
        email: { type: 'string', default: 'test@example.com' },
        machine: { type: 'string', default: 'test-machine-id' },
        plan: { type: 'string', default: 'standard' },
        days: { type: 'string', default: '' },           // '' = perpetual
        key: { type: 'string', default: 'TEST-LICENSE-KEY-0000' },
    },
});

const privB64 = process.env.ED25519_PRIVATE_KEY;
if (!privB64) {
    console.error('ED25519_PRIVATE_KEY env var required. Run `pnpm keys:generate` first.');
    process.exit(1);
}

const now = Math.floor(Date.now() / 1000);
const payload = {
    v: 1 as const,
    license_id: 'lic_test_' + now,
    license_key: values.key!,
    customer_email: values.email!,
    plan: values.plan!,
    machine_id: values.machine!,
    issued_at: now,
    expires_at: values.days ? now + parseInt(values.days, 10) * 86400 : null,
    max_devices: 3,
};

// Same canonicalization as crypto.ts canonicalize().
const sortedKeys = Object.keys(payload).sort();
const sortedObj: Record<string, unknown> = {};
for (const k of sortedKeys) sortedObj[k] = (payload as Record<string, unknown>)[k];
const message = new TextEncoder().encode(JSON.stringify(sortedObj));

const priv = Buffer.from(privB64, 'base64');
const pub = await ed.getPublicKeyAsync(priv);
const signature = await ed.signAsync(message, priv);

const kid = Buffer.from(sha256(pub).slice(0, 8)).toString('base64');

console.log(JSON.stringify({
    payload,
    sig: Buffer.from(signature).toString('base64'),
    kid,
}, null, 2));
