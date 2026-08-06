# SHIPIT — PixPut launch checklist

Everything you need to flip the switch on a commercial PixPut launch. Work top-to-bottom; nothing here is optional for v1. **No code changes required** — the app, server, and marketing site are already built. This document is just credentials, DNS, and "click here, paste this."

Estimate: half a day if everything goes smoothly, a day with normal friction.

---

## 0. Prerequisites you already have

- ✅ Apple Developer Program membership (Team ID: `8P9LPVFM5R`)
- ✅ Developer ID Application certificate in login Keychain
- ✅ App-specific password stored in Keychain (`xcrun notarytool store-credentials`)
- ✅ The repo (this one)

---

## 1. Generate license-signing keypair (5 min)

The app verifies licenses with Ed25519. Server signs with the private key, app verifies with the public key. Never commit either.

```bash
cd server
npm install
npm run keys:generate
# Output (DO NOT COMMIT):
#   ED25519_PRIVATE_KEY=<base64 64-byte string>
#   publicKeyB64=<base64 44-char string>
```

**Two things to do with the output:**

1. **Save the private key as a Cloudflare Worker secret** (Step 4).
2. **Paste the public key into the app:**

   Edit [App/Core/Licensing/LicenseVerifier.swift](App/Core/Licensing/LicenseVerifier.swift), line ~22:
   ```swift
   public static let publicKeyB64 = "<paste public key here>"
   ```
   This single line replacement turns the dev bypass off — every license now needs a real server signature.

---

## 2. Set up Cloudflare account + Worker + D1 (30 min)

### 2a. Create CF account, install wrangler

```bash
npm install -g wrangler   # or use the local devDep
wrangler login            # opens browser, authorizes
```

### 2b. Create D1 database

```bash
cd server
wrangler d1 create pixput-licenses
# Output includes a `database_id` UUID. Copy it.
```

Edit [server/wrangler.toml](server/wrangler.toml) line 12, replace `REPLACE_WITH_D1_ID` with the UUID.

### 2c. Apply schema

```bash
npm run schema:apply         # production D1
npm run schema:apply:local   # local D1 (for wrangler dev testing)
```

### 2d. Set Worker secrets

```bash
echo "<base64 priv key from Step 1>" | wrangler secret put ED25519_PRIVATE_KEY
# Lemon Squeezy values come in Step 3:
# wrangler secret put LEMONSQUEEZY_API_KEY
# wrangler secret put LEMONSQUEEZY_WEBHOOK_SECRET
```

### 2e. First deploy

```bash
npm run deploy:prod
# Outputs the assigned workers.dev subdomain.
# Test: curl https://pixput-license-api.<your-subdomain>.workers.dev/healthz
# Expect: {"ok":true,"ts":...}
```

---

## 3. Set up Lemon Squeezy (60 min — most of this is account verification)

LemonSqueezy is the merchant of record (handles VAT in 100+ jurisdictions for ~5% + $0.50). They take a couple of days for store activation; submit ASAP.

### 3a. Create a store at https://app.lemonsqueezy.com

- Pick "Digital products."
- Submit the verification documents they ask for (passport/ID, tax info, business info).
- Wait for approval (1-3 business days).

### 3b. Create the PixPut product

- Product name: **PixPut**
- Description: copy the lede from [marketing/src/pages/index.astro](marketing/src/pages/index.astro).
- Price: **$19 USD** (one-time).
- **Enable "License keys"** in product options. Set max activations to 3.
- Save → copy the product URL (something like `https://pixput.lemonsqueezy.com/buy/abc123-...`).

### 3c. Replace the buy URL

Edit [marketing/src/pages/buy.astro](marketing/src/pages/buy.astro) line 7:
```js
const LEMONSQUEEZY_BUY_URL = 'https://pixput.lemonsqueezy.com/buy/<your-product-id>';
```

### 3d. Generate API key + webhook secret

- Settings → API → Create a new key. `wrangler secret put LEMONSQUEEZY_API_KEY`.
- Settings → Webhooks → Add endpoint:
  - URL: `https://api.pixput.app/v1/webhooks/lemonsqueezy` (will work once Step 5 is done)
  - Events: `order_created` (only one needed for v1)
  - Signing secret: generate a random 32-char string, save it both here AND via `wrangler secret put LEMONSQUEEZY_WEBHOOK_SECRET`.

---

## 4. Generate Sparkle keypair + appcast host (20 min)

### 4a. Install Sparkle's `generate_keys`

The tool is bundled with Sparkle SPM. After `swift build` it's under `.build/artifacts/.../bin/`:

```bash
find .build/artifacts -name 'generate_keys' -type f
# Run it (one-time):
.build/artifacts/sparkle/Sparkle/bin/generate_keys
# It stores the private key in your login Keychain and prints the public key.
```

### 4b. Paste public key into Info.plist

Edit [Resources/Info.plist](Resources/Info.plist), replace `TODO_REPLACE_WITH_REAL_EDDSA_PUBLIC_KEY` with the printed value.

### 4c. Stand up the appcast host

Use Cloudflare Pages bucket OR R2 OR S3 — any static file host. The Info.plist `SUFeedURL` points to `https://updates.pixput.app/appcast.xml`, so configure DNS to that host.

Create an initial empty `appcast.xml` and upload it:

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>PixPut Updates</title>
        <link>https://updates.pixput.app/appcast.xml</link>
        <description>PixPut version history</description>
        <language>en</language>
        <!-- <item> entries appended by scripts/sparkle-release.sh per release -->
    </channel>
</rss>
```

---

## 5. DNS + domains (30 min)

You need three subdomains pointing at three different things. Cloudflare is easiest because everything is in one dashboard.

| Subdomain | Points to | Used by |
|---|---|---|
| `pixput.app` | CF Pages (`pixput-marketing`) | Marketing site |
| `api.pixput.app` | CF Workers (`pixput-license-api`) | License API |
| `updates.pixput.app` | Static host (Pages bucket or R2) | Sparkle appcast + .zip downloads |

For each: add a CNAME / route in CF DNS, then in the matching Worker/Pages settings add the custom domain. CF handles the TLS cert automatically.

### 5a. Cert-pin the API leaf SPKI

Once `api.pixput.app` resolves with a real cert:

```bash
echo | openssl s_client -servername api.pixput.app -connect api.pixput.app:443 2>/dev/null \
    | openssl x509 -pubkey -noout \
    | openssl pkey -pubin -outform DER \
    | openssl dgst -sha256 -binary \
    | base64
# → base64-encoded SHA256 of the leaf SubjectPublicKeyInfo
```

Paste into [App/Core/Licensing/LicenseAPIClient.swift](App/Core/Licensing/LicenseAPIClient.swift), in `Configuration.production`:
```swift
pinnedLeafSPKISHA256B64: "<paste here>",
```

Note: CF rotates certs ~90 days, so you'll need to update this pin and ship a new app release before each rotation OR pin the intermediate (slightly weaker). For v1, just track rotation manually.

---

## 6. Deploy the marketing site (15 min)

### 6a. Assets

Drop these into [marketing/public/](marketing/public/) before building:
- `favicon.svg` — vector logo
- `apple-touch-icon.png` — 180×180 PNG
- `og.png` — **1200×630** social-share image (hero shot + title)
- Optional: `/screenshots/*.png` for the marketing site (mention in feature cards)

### 6b. Build + deploy

```bash
cd marketing
npm install
npm run build
npm run deploy
# Or: wire CF Pages to the GitHub repo for auto-deploy on push to main.
```

### 6c. Point pixput.app at it

CF dashboard → Pages → `pixput-marketing` → Custom domains → Add `pixput.app`.

---

## 7. App icon + final app polish (60 min — partly designer time)

### 7a. Real app icon

Currently the bundle uses no icon (Finder shows the default). You need a real `.icns`:

1. Design a 1024×1024 PNG (designer task).
2. `iconutil -c icns AppIcon.iconset` to build the multi-size `.icns`.
3. Drop into `Resources/AppIcon.icns`.
4. Add to [Resources/Info.plist](Resources/Info.plist):
   ```xml
   <key>CFBundleIconFile</key>
   <string>AppIcon</string>
   ```
5. Update [scripts/build-app.sh](scripts/build-app.sh) to copy `Resources/AppIcon.icns` into `Contents/Resources/`.

### 7b. Pre-flight in-app checks

Open the app → exercise this matrix:

- [ ] Menu bar shows trial countdown line.
- [ ] Onboarding window appears on first launch and walks through both steps.
- [ ] Settings → License pane shows current state, allows Activate, allows Manage Devices.
- [ ] Settings → Updates pane shows version and "Check now" works.
- [ ] Capture Now / Restore Now still work.
- [ ] Sleep machine → wake → windows snap back.

---

## 8. First release (signed, notarized, stapled, Sparkle-signed) (15 min)

```bash
# Set up notarytool credentials (once):
xcrun notarytool store-credentials AC_PASSWORD \
    --apple-id "aaron.scribner@cerebraljuice.co" \
    --team-id "8P9LPVFM5R"

# Build + notarize + staple:
IDENTITY="Developer ID Application: Aaron Scribner (8P9LPVFM5R)" \
KEYCHAIN_PROFILE="AC_PASSWORD" \
./scripts/release-app.sh

# Sparkle-sign the zip + generate appcast snippet:
VERSION=0.1.0 ./scripts/sparkle-release.sh

# Upload outputs:
#   build/PixPut-0.1.0.zip → https://updates.pixput.app/PixPut-0.1.0.zip
#   merge build/appcast-snippet-0.1.0.xml into appcast.xml
#   upload appcast.xml → https://updates.pixput.app/appcast.xml
```

---

## 9. Smoke test the full chain end-to-end (15 min)

This is the moment of truth. Do it BEFORE you tell anyone the site is live.

1. **Buy.** Open [https://pixput.app/buy](https://pixput.app/buy) → complete purchase using a real card. (You can refund yourself.)
2. **Email arrives.** Lemon Squeezy emails your license key within a minute.
3. **Webhook fires.** Check D1: `wrangler d1 execute pixput-licenses --remote --command "SELECT * FROM licenses"`. Your row should be there.
4. **Activate.** Open PixPut → menu bar → License… → paste key → Activate. Status flips to "Active."
5. **Validate.** Quit + relaunch PixPut. License state should still be "Active" (cached in Keychain + signature still verifies).
6. **Device list.** Settings → License → "Load devices" shows this Mac.
7. **Update check.** Settings → Updates → Check now. Should report "Up to date" (you're on the latest).
8. **(Future-test) Issue a 0.1.1 release.** Bump `CFBundleShortVersionString`, run release scripts. From an installed 0.1.0 app, Sparkle should offer the update.

---

## 10. Support and ops

- `support@pixput.app` should forward to your inbox. Set up an autoresponder confirming receipt.
- Add yourself to the Lemon Squeezy email notifications for new orders/disputes.
- Set up a Cloudflare alert for Worker 5xx errors (>1% over 5 min).
- Have the "release a device for a customer" runbook handy: `wrangler d1 execute pixput-licenses --remote --command "DELETE FROM activations WHERE license_id = (SELECT id FROM licenses WHERE customer_email = 'X') AND machine_id = 'Y'"`.

---

## What's optional for v1 (skip without regret)

- Subscription pricing — start with one-time, simpler refund flow.
- Team licenses — add later if you see demand.
- Multi-platform — Mac-only is fine.
- Crash reporting — file-based diagnostic log is enough for v1.
- Anti-debug (`PT_DENY_ATTACH`) — diminishing returns on Apple Silicon, the existing notarization + verify-with-retry crypto is plenty.
- Translation / i18n — English only for v1.

## When to revisit

- After 10 paid sales: review whether trial-to-paid conversion needs tweaks (extend trial? add a reminder email?).
- After 100 paid sales: consider Stripe Tax + direct Stripe Checkout instead of LS for ~3% margin gain.
- After 1000 paid sales: time to think about a real "support" plan (canned responses, FAQ, knowledge base).
