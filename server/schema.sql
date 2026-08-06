-- PixPut license database (D1).
-- Apply with: pnpm schema:apply (remote) or schema:apply:local (local).

CREATE TABLE IF NOT EXISTS licenses (
    id              TEXT PRIMARY KEY,                -- ULID we generate
    license_key     TEXT NOT NULL UNIQUE,            -- LemonSqueezy-issued key (or our format for non-LS issuance)
    customer_email  TEXT NOT NULL,
    ls_order_id     TEXT,                            -- Lemon Squeezy order id (null for manually-issued)
    ls_product_id   TEXT,
    plan            TEXT NOT NULL DEFAULT 'standard',
    max_devices     INTEGER NOT NULL DEFAULT 3,
    issued_at       INTEGER NOT NULL,                -- unix seconds
    expires_at      INTEGER,                         -- null = perpetual; else unix seconds
    revoked_at      INTEGER,                         -- non-null = revoked, blocks all validate/activate calls
    notes           TEXT
);

CREATE INDEX IF NOT EXISTS idx_licenses_email ON licenses(customer_email);
CREATE INDEX IF NOT EXISTS idx_licenses_ls_order ON licenses(ls_order_id);

CREATE TABLE IF NOT EXISTS activations (
    license_id      TEXT NOT NULL,
    machine_id      TEXT NOT NULL,                   -- SHA256(IOPlatformUUID + salt) from the client
    activated_at    INTEGER NOT NULL,
    last_seen_at    INTEGER NOT NULL,
    last_app_version TEXT,
    PRIMARY KEY (license_id, machine_id),
    FOREIGN KEY (license_id) REFERENCES licenses(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_activations_machine ON activations(machine_id);

CREATE TABLE IF NOT EXISTS trials (
    machine_id      TEXT PRIMARY KEY,
    started_at      INTEGER NOT NULL,
    expires_at      INTEGER NOT NULL,
    first_seen_email TEXT
);

-- Audit trail. Aggressively pruned (e.g. >90d) by a scheduled cron.
CREATE TABLE IF NOT EXISTS audit_events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    ts              INTEGER NOT NULL,
    event_type      TEXT NOT NULL,                   -- activate, validate, deactivate, trial.start, webhook.ls.order_created, etc.
    license_id      TEXT,
    machine_id      TEXT,
    ip              TEXT,
    ua              TEXT,
    payload         TEXT
);

CREATE INDEX IF NOT EXISTS idx_audit_license ON audit_events(license_id, ts DESC);
CREATE INDEX IF NOT EXISTS idx_audit_machine ON audit_events(machine_id, ts DESC);
