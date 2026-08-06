# PixPut License API

Cloudflare Worker + D1 backend for PixPut license issuance and validation.

## What's here

- `src/index.ts` — router. Endpoints: `/v1/activate`, `/v1/validate`, `/v1/deactivate`, `/v1/trial/start`, `/v1/webhooks/lemonsqueezy`, `/healthz`.
- `src/crypto.ts` — Ed25519 sign/verify, canonical-JSON encoding, Lemon Squeezy HMAC verification.
- `src/types.ts` — wire types; **must stay in sync** with `App/Core/Licensing/LicensePayload.swift`.
- `schema.sql` — D1 schema.
- `scripts/generate-keys.ts` — one-time Ed25519 keypair generation.
- `scripts/sign-test-license.ts` — sign a hand-crafted license for local app testing.

## First-time setup

```bash
cd server
npm install          # or pnpm install
npm run keys:generate
# → prints the private key (Worker secret) and the public key (Swift constant).
# Copy the public key block into App/Core/Licensing/LicenseVerifier.swift
# replacing the `PLACEHOLDER_REPLACE_WITH_GENERATED_KEY` value.

# Create D1 database (one time):
wrangler d1 create pixput-licenses
# Paste the printed database_id into wrangler.toml.

# Apply schema:
npm run schema:apply:local   # for `wrangler dev`
npm run schema:apply         # for production after first deploy

# Stash the private key as a Worker secret:
echo "<base64 priv from generate-keys>" | wrangler secret put ED25519_PRIVATE_KEY

# Lemon Squeezy creds (when ready to wire purchases):
wrangler secret put LEMONSQUEEZY_API_KEY
wrangler secret put LEMONSQUEEZY_WEBHOOK_SECRET
```

## Local dev loop

```bash
npm run dev          # wrangler dev on http://127.0.0.1:8787

# In another shell — sign a test license without going through LS:
ED25519_PRIVATE_KEY="<base64>" npm run license:sign-test -- \
  --email you@example.com --machine $(echo $HOSTNAME | shasum | head -c64)
# → prints a SignedLicense JSON. Paste it into the app (debug menu pending).
```

## Deploy

```bash
npm run deploy:prod
# Then point your domain (api.pixput.app) at the worker route in wrangler.toml.
```

## Wire-compat contract

The Ed25519 signature is over the **canonical-JSON** encoding of the payload:

- Keys sorted alphabetically.
- UTF-8, no whitespace, no slash-escaping.
- Primitives only (string | number | boolean | null) — no nested objects or arrays in the signed payload.

Both `crypto.ts#canonicalize` (server) and `CanonicalJSON.encode(_:)` (Swift) produce the same byte sequence. If you change the payload schema, bump `LicensePayload.v` on both sides and update this README.

## Endpoint contracts

### `POST /v1/activate`
**Body**: `{ license_key, machine_id, nonce, client_ts, app_version? }`
**Returns**: `{ license: { payload, sig, kid }, nonce_echo, server_ts }`
**Errors**: 404 unknown_license, 403 expired, 409 machine_limit_exceeded.

### `POST /v1/validate`
**Body**: `{ license_key, machine_id, nonce, client_ts, app_version? }`
**Returns**: `{ payload: { status, nonce_echo, server_ts, expires_at, next_validate_after }, sig, kid }`
`status` ∈ `active | expired | revoked | machine_limit_exceeded | unknown_license`.

### `POST /v1/deactivate`
**Body**: `{ license_key, machine_id }` → `{ ok: true }`

### `POST /v1/trial/start`
**Body**: `{ machine_id, email? }`
**Returns**: signed trial envelope `{ payload: { kind: 'trial', machine_id, started_at, expires_at, server_ts }, sig, kid }`.
Idempotent — re-calling for the same machine returns the existing trial window.

### `POST /v1/webhooks/lemonsqueezy`
HMAC-verified. On `order_created` creates a license row keyed by the LS-issued license key, so the customer's subsequent `/v1/activate` succeeds.
