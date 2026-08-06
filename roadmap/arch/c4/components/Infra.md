# Component: Infra

**Status**: Stub | **Layer**: Infra

## Purpose

Cross-cutting infrastructure: logging, file paths, Sparkle setup. The "no business logic" layer that everything else depends on.

## Responsibilities

- `Logging` — `swift-log` + custom rotating-file destination (7-day retention, 50 MB cap, no PII in default log level)
- `Paths` — resolve and create `~/Library/Application Support/DisplayMaid-Next/` subdirectories on first run; expose `URL`s to other components
- `Updates` — Sparkle 2.x initialisation (delegate, EdDSA verification, feed URL from `Info.plist`)

## Boundaries

- The only file I/O surface for the app — `SnapshotStore` and `Settings` route their disk operations through `Paths`
- The only network call surface — `Updates` calls Sparkle's feed URL; no other component opens a network connection (project constitution §IV)
- `Logging` MUST redact identifiers per privacy review (tab URLs, document paths) at default log level; raw strings only at debug level

## Dependencies

- `swift-log` (logging façade)
- `Sparkle` 2.x (auto-update)
- Foundation (file I/O)

## Files (per plan.md)

- `Infra/Logging.swift`
- `Infra/Paths.swift`
- `Infra/Updates.swift`

## Constitution Alignment

- §IV Local-only data — all I/O under Application Support; only allowed network call is Sparkle appcast
- §VI Direct distribution — Sparkle EdDSA verification mandatory; un-notarised builds refuse to run (FR-018)

## Entitlements (Resources/Entitlements.plist)

Per project constitution §I + §VI, the entitlements file is intentionally minimal:

- `com.apple.security.automation.apple-events` = `true` — required for `DeepIdentityFetcher` to script other apps via NSAppleScript / ScriptingBridge. Lazy per-bundle Automation prompts surface from this entitlement (spec FR-014).
- `com.apple.security.app-sandbox` — intentionally **NOT** set. The Accessibility-driven workflow this product depends on is forbidden inside the macOS sandbox; outside-MAS distribution requires this anyway (vision.md "No Mac App Store distribution").
- Hardened Runtime — applied at `codesign` time via `--options runtime`, not via an entitlement key. Required for notarisation (spec FR-018).

The `Entitlements.plist` itself **must not contain XML comments** — `codesign`'s parser (AMFIUnserializeXML) is stricter than `plutil` and rejects comments with `syntax error near line N`. This rationale lives here in the C4 doc instead.

## Open Questions

- Log redaction rules: regex per identifier type, or structural redaction via a typed `Loggable` protocol — pending security review.
- Sparkle staging vs production appcast URL switching — pending release-engineering decision.
