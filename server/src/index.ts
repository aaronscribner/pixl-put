import { Router, IRequest } from 'itty-router';
import type {
    Env, ActivateRequest, ActivateResponse,
    ValidateRequest, ValidateResponse, LicensePayload
} from './types.js';
import { signPayload, verifyLemonSqueezySignature, newId } from './crypto.js';

const router = Router();

router.get('/healthz', () => json({ ok: true, ts: Math.floor(Date.now() / 1000) }));

/**
 * POST /v1/activate
 * Body: ActivateRequest
 * Returns: ActivateResponse with the Ed25519-signed LicensePayload.
 * The client persists this in Keychain and re-verifies on every launch.
 */
router.post('/v1/activate', async (req: IRequest, env: Env) => {
    const body = await req.json<ActivateRequest>();
    if (!body.license_key || !body.machine_id || !body.nonce) {
        return jsonError(400, 'missing required fields');
    }
    const now = Math.floor(Date.now() / 1000);

    // Look up the license. License rows are created by the Lemon Squeezy
    // webhook (order_created). Until that exists, /activate returns
    // unknown_license — the user must have purchased to activate.
    const lic = await env.DB.prepare(
        'SELECT * FROM licenses WHERE license_key = ? AND revoked_at IS NULL'
    ).bind(body.license_key).first<LicenseRow>();
    if (!lic) {
        await audit(env, 'activate.unknown', null, body.machine_id, req);
        return jsonError(404, 'unknown or revoked license');
    }
    if (lic.expires_at && lic.expires_at < now) {
        return jsonError(403, 'license expired');
    }

    // Enforce max-devices.
    const existing = await env.DB.prepare(
        'SELECT machine_id FROM activations WHERE license_id = ?'
    ).bind(lic.id).all<{ machine_id: string }>();
    const machines = new Set(existing.results.map(r => r.machine_id));
    if (!machines.has(body.machine_id) && machines.size >= lic.max_devices) {
        return jsonError(409, 'machine limit exceeded — release a device from another machine first');
    }

    await env.DB.prepare(
        `INSERT INTO activations (license_id, machine_id, activated_at, last_seen_at, last_app_version)
         VALUES (?, ?, ?, ?, ?)
         ON CONFLICT (license_id, machine_id) DO UPDATE SET last_seen_at = excluded.last_seen_at, last_app_version = excluded.last_app_version`
    ).bind(lic.id, body.machine_id, now, now, body.app_version ?? null).run();

    const payload: LicensePayload = {
        v: 1,
        license_id: lic.id,
        license_key: lic.license_key,
        customer_email: lic.customer_email,
        plan: lic.plan,
        machine_id: body.machine_id,
        issued_at: now,
        expires_at: lic.expires_at,
        max_devices: lic.max_devices,
    };
    const { sig, kid } = await signPayload(payload as unknown as Record<string, unknown>, env.ED25519_PRIVATE_KEY);

    const resp: ActivateResponse = {
        license: { payload, sig, kid },
        nonce_echo: body.nonce,
        server_ts: now,
    };
    await audit(env, 'activate.ok', lic.id, body.machine_id, req);
    return json(resp);
});

/**
 * POST /v1/validate
 * Periodic phone-home. Server signs the response with the same Ed25519 key
 * the app embeds, so a MitM/DNS-redirect attack can't forge a "valid" reply
 * without holding the private key. The nonce_echo prevents replay.
 */
router.post('/v1/validate', async (req: IRequest, env: Env) => {
    const body = await req.json<ValidateRequest>();
    if (!body.license_key || !body.machine_id || !body.nonce) {
        return jsonError(400, 'missing required fields');
    }
    const now = Math.floor(Date.now() / 1000);

    const lic = await env.DB.prepare(
        'SELECT * FROM licenses WHERE license_key = ?'
    ).bind(body.license_key).first<LicenseRow>();

    let status: ValidateResponse['status'] = 'active';
    if (!lic) status = 'unknown_license';
    else if (lic.revoked_at) status = 'revoked';
    else if (lic.expires_at && lic.expires_at < now) status = 'expired';
    else {
        const act = await env.DB.prepare(
            'SELECT 1 FROM activations WHERE license_id = ? AND machine_id = ?'
        ).bind(lic.id, body.machine_id).first();
        if (!act) status = 'machine_limit_exceeded';
        else {
            await env.DB.prepare(
                'UPDATE activations SET last_seen_at = ?, last_app_version = ? WHERE license_id = ? AND machine_id = ?'
            ).bind(now, body.app_version ?? null, lic.id, body.machine_id).run();
        }
    }

    const resp: ValidateResponse = {
        status,
        nonce_echo: body.nonce,
        server_ts: now,
        expires_at: lic?.expires_at ?? null,
        next_validate_after: now + 6 * 3600,  // 6h cadence
    };
    const { sig, kid } = await signPayload(resp as unknown as Record<string, unknown>, env.ED25519_PRIVATE_KEY);
    await audit(env, `validate.${status}`, lic?.id ?? null, body.machine_id, req);
    return json({ payload: resp, sig, kid });
});

/**
 * POST /v1/license/devices — list machines activated on a license.
 * Authorization: the requesting `machine_id` must itself be activated on
 * the license. This is sufficient gating without auth tokens because
 * (a) the machine_id is a SHA256 hash, not guessable, and (b) `/activate`
 * is rate-limited at the platform layer (CF). Anyone with stolen machine_id
 * + license_key can already use the license — listing slots gives them
 * nothing they don't already have.
 */
router.post('/v1/license/devices', async (req: IRequest, env: Env) => {
    const body = await req.json<{ license_key: string; machine_id: string }>();
    if (!body.license_key || !body.machine_id) return jsonError(400, 'missing fields');
    const lic = await env.DB.prepare(
        'SELECT id FROM licenses WHERE license_key = ? AND revoked_at IS NULL'
    ).bind(body.license_key).first<{ id: string }>();
    if (!lic) return jsonError(404, 'unknown license');
    const caller = await env.DB.prepare(
        'SELECT 1 FROM activations WHERE license_id = ? AND machine_id = ?'
    ).bind(lic.id, body.machine_id).first();
    if (!caller) return jsonError(403, 'requesting device is not activated on this license');
    const rows = await env.DB.prepare(
        `SELECT machine_id, activated_at, last_seen_at, last_app_version
         FROM activations WHERE license_id = ? ORDER BY last_seen_at DESC`
    ).bind(lic.id).all<{
        machine_id: string; activated_at: number; last_seen_at: number; last_app_version: string | null;
    }>();
    await audit(env, 'license.devices.list', lic.id, body.machine_id, req);
    return json({ devices: rows.results });
});

/**
 * POST /v1/deactivate — release a machine slot.
 */
router.post('/v1/deactivate', async (req: IRequest, env: Env) => {
    const body = await req.json<{ license_key: string; machine_id: string }>();
    const lic = await env.DB.prepare('SELECT id FROM licenses WHERE license_key = ?')
        .bind(body.license_key).first<{ id: string }>();
    if (!lic) return jsonError(404, 'unknown license');
    await env.DB.prepare('DELETE FROM activations WHERE license_id = ? AND machine_id = ?')
        .bind(lic.id, body.machine_id).run();
    await audit(env, 'deactivate', lic.id, body.machine_id, req);
    return json({ ok: true });
});

/**
 * POST /v1/trial/start — issue a signed trial window for an unknown machine.
 * Trial state lives server-side; the app stores the signed start/expiry.
 */
router.post('/v1/trial/start', async (req: IRequest, env: Env) => {
    const body = await req.json<{ machine_id: string; email?: string }>();
    if (!body.machine_id) return jsonError(400, 'missing machine_id');
    const now = Math.floor(Date.now() / 1000);
    const expiresAt = now + 14 * 24 * 3600;  // 14 days

    const existing = await env.DB.prepare('SELECT * FROM trials WHERE machine_id = ?')
        .bind(body.machine_id).first<{ started_at: number; expires_at: number }>();
    const started = existing?.started_at ?? now;
    const expires = existing?.expires_at ?? expiresAt;
    if (!existing) {
        await env.DB.prepare(
            'INSERT INTO trials (machine_id, started_at, expires_at, first_seen_email) VALUES (?, ?, ?, ?)'
        ).bind(body.machine_id, now, expiresAt, body.email ?? null).run();
    }

    const payload = {
        v: 1,
        kind: 'trial',
        machine_id: body.machine_id,
        started_at: started,
        expires_at: expires,
        server_ts: now,
    };
    const { sig, kid } = await signPayload(payload, env.ED25519_PRIVATE_KEY);
    await audit(env, 'trial.start', null, body.machine_id, req);
    return json({ payload, sig, kid });
});

/**
 * POST /v1/webhooks/lemonsqueezy
 * On `order_created`, create a license row keyed by the LS license key.
 * The user then enters that key into PixPut → /activate happens.
 */
router.post('/v1/webhooks/lemonsqueezy', async (req: IRequest, env: Env) => {
    if (!env.LEMONSQUEEZY_WEBHOOK_SECRET) return jsonError(503, 'webhook not configured');
    const sig = req.headers.get('x-signature') ?? '';
    const raw = await req.text();
    const ok = await verifyLemonSqueezySignature(raw, sig, env.LEMONSQUEEZY_WEBHOOK_SECRET);
    if (!ok) return jsonError(401, 'bad signature');

    const evt = JSON.parse(raw);
    const eventName = evt?.meta?.event_name as string | undefined;
    if (eventName !== 'order_created') return json({ ignored: eventName });

    const attrs = evt?.data?.attributes ?? {};
    const email = attrs?.user_email as string | undefined;
    const orderId = String(evt?.data?.id ?? '');
    const productId = String(attrs?.first_order_item?.product_id ?? '');
    // We expect LS to issue a license key when "License keys" is enabled
    // on the product. The key lives under `first_order_item.license_keys`.
    const licenseKey = attrs?.first_order_item?.license_keys?.[0]?.key as string | undefined;
    if (!email || !licenseKey) return jsonError(400, 'missing email or license_key in payload');

    const now = Math.floor(Date.now() / 1000);
    const id = newId('lic');
    await env.DB.prepare(
        `INSERT INTO licenses (id, license_key, customer_email, ls_order_id, ls_product_id, plan, max_devices, issued_at, expires_at)
         VALUES (?, ?, ?, ?, ?, 'standard', 3, ?, NULL)
         ON CONFLICT (license_key) DO NOTHING`
    ).bind(id, licenseKey, email, orderId, productId, now).run();
    await audit(env, 'webhook.ls.order_created', id, null, req, raw.slice(0, 2000));
    return json({ ok: true, license_id: id });
});

router.all('*', () => jsonError(404, 'not found'));

export default {
    fetch: (req: Request, env: Env, ctx: ExecutionContext) =>
        router.fetch(req, env, ctx).catch(err => jsonError(500, String(err))),
};

// ─── helpers ────────────────────────────────────────────────────────────

interface LicenseRow {
    id: string;
    license_key: string;
    customer_email: string;
    plan: string;
    max_devices: number;
    issued_at: number;
    expires_at: number | null;
    revoked_at: number | null;
}

function json(body: unknown, status = 200): Response {
    return new Response(JSON.stringify(body), {
        status,
        headers: { 'content-type': 'application/json' },
    });
}

function jsonError(status: number, message: string): Response {
    return json({ error: message }, status);
}

async function audit(
    env: Env,
    eventType: string,
    licenseId: string | null,
    machineId: string | null,
    req: IRequest,
    payload?: string
): Promise<void> {
    try {
        await env.DB.prepare(
            'INSERT INTO audit_events (ts, event_type, license_id, machine_id, ip, ua, payload) VALUES (?, ?, ?, ?, ?, ?, ?)'
        ).bind(
            Math.floor(Date.now() / 1000),
            eventType,
            licenseId,
            machineId,
            req.headers.get('cf-connecting-ip') ?? null,
            req.headers.get('user-agent') ?? null,
            payload ?? null
        ).run();
    } catch {
        // Audit must never block the request path.
    }
}
