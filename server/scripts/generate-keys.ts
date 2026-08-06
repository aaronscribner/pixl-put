// One-time setup: generate the Ed25519 keypair used for license signing.
// Run with: pnpm keys:generate
//
// Output:
//   - private key (base64) → set as Worker secret: `wrangler secret put ED25519_PRIVATE_KEY`
//   - public key (base64)  → paste into Swift LicenseVerifier.swift
//   - public key (Swift literal) → ready-to-paste constant
//
// Never commit either output to git.

import * as ed from '@noble/ed25519';
import { sha512 } from '@noble/hashes/sha512';
import { randomBytes } from 'node:crypto';

ed.etc.sha512Sync = (...m) => sha512(ed.etc.concatBytes(...m));

const privateKey = randomBytes(32);
const publicKey = await ed.getPublicKeyAsync(privateKey);

const privB64 = Buffer.from(privateKey).toString('base64');
const pubB64 = Buffer.from(publicKey).toString('base64');

// Swift Data literal — paste into LicenseVerifier.swift.
const swiftBytes = Array.from(publicKey)
    .map(b => '0x' + b.toString(16).padStart(2, '0'))
    .join(', ');

console.log('# Ed25519 keypair generated.');
console.log('# DO NOT COMMIT either of these.\n');
console.log('## Server side — set as Worker secret:');
console.log(`echo "${privB64}" | wrangler secret put ED25519_PRIVATE_KEY\n`);
console.log('## App side — paste into Swift LicenseVerifier.swift:');
console.log(`static let publicKeyB64 = "${pubB64}"\n`);
console.log('## Or as raw Swift bytes:');
console.log(`static let publicKeyBytes: [UInt8] = [${swiftBytes}]`);
