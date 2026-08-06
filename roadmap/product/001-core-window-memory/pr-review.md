# PR Review: feat(core): window-memory Core layer

**Feature**: 001-core-window-memory | **Phase**: post-implementation review | **Reviewer agents**: code-reviewer + security-reviewer | **Date**: 2026-05-27

> Stand-in PR review on the un-committed slice. When this work is staged into a PR, run `/pr-review` to refresh against the actual diff.

---

## Code Reviewer — 6-pass review

### Pass 1 — Correctness & Spec Compliance
- ✓ FR-001 to FR-004, FR-007, FR-008, FR-010 to FR-012 implemented or wired in `Restorer`
- ✓ Story-1 acceptance #1, #3, #4 covered by test cases
- ✓ Story-3 acceptance #1, #2 covered for the v1 bundles (Brave, VS Code)
- ✓ `Snapshot.schemaVersion` set on every snapshot; `SnapshotStore` rejects unknown versions
- ✓ Idempotence rule extends to fullscreen state (not just frame) — verified by `RestorerTests`

### Pass 2 — Security (macOS-informed)
- ✓ No pasteboard / URL scheme / AppleScript code in this slice (all deferred to AX-layer)
- ✓ No outbound network call (no `URLSession`, no `URL.fetch`)
- ✓ No hardcoded secrets, no credential strings
- ✓ `SnapshotStore.bootstrap()` creates the snapshot directory with mode `0o700` (verified by test) — covers project constitution §IV sensitivity of browser tab URLs / document paths
- ✓ No PII in log statements (no log statements at all in PixPutCore yet — Logging deferred to Infra)
- ⚠ Advisory (not blocking): when `Infra/Logging` is added, default-level log statements MUST redact URLs and document paths

### Pass 3 — Design & Architecture
- ✓ Strict dependency direction: `Identity` → none external to itself; `Snapshot` → `Identity`, `Displays`; `Triggers/Debouncer` → standalone. No cycles.
- ✓ Every new abstraction sits in a documented C4 component file (verified against `roadmap/arch/c4/components/`)
- ✓ Single responsibility: each type does one thing (`Restorer` orchestrates; `RestorerBackend` is the AX seam; `WindowIdentityProvider` resolves one layer)
- ✓ `WindowIdentityResolver` is the documented primary extension point per constitution §II — adding a browser is `BrowserTabSetProvider.supportedBundleIDs += "com.google.Chrome"`, no resolver edit needed
- ✓ Private CG symbols isolated to `PrivateCGS.swift` per ADR-0001 — file not in this slice but the Package.swift exclusion documents the seam
- ✓ AX boundary maintained via `RestorerBackend` protocol — production `AXClient` will conform without leaking AX types into `Restorer`

### Pass 4 — Code Quality (Swift)
- ✓ async/await in `Restorer` (`apply`, `RestorerBackend.move/setFullscreen` are async)
- ✓ Value types preferred — `Snapshot`, `WindowEntry`, `DisplayFingerprint`, `WindowIdentity`, `CGRectCodable` all `struct` or `enum`
- ✓ Reference types only where identity is required — `Debouncer` (mutable timer state), `Restorer` (actor; serial AX-queue semantics), test helpers (`FakeBackend`, `Counter`)
- ✓ Naming: intention-revealing (`isApproximately`, `displayConfigurationID`, `skippedAlreadyAtFrame`)
- ✓ No dead code, no commented-out blocks, no TODOs without context
- ✓ `Sendable` conformance set where appropriate (data types + `Restorer` is `actor`)
- ✓ `@unchecked Sendable` used sparingly — only on `Debouncer` (NSLock-protected) and the test `Counter`, both justified

### Pass 5 — Tests
- ✓ XCTest names follow `test_<what>_<when>_<then>` pattern
- ✓ Each test asserts a single behaviour
- ✓ External dependencies (AX backend, file system, system clock) mocked at the seam (`RestorerBackend`, `tempDir`, `FastClock`)
- ✓ No `Thread.sleep` for time-dependence outside the `Debouncer` tests (where it's the system-under-test)
- ✓ Specific assertions (`XCTAssertEqual` to exact values, not `XCTAssertNotNil`)
- ✓ Coverage matches spec acceptance criteria for the testable subset (see `qa-report.md` traceability matrix)

### Pass 6 — Performance (project constitution §VII)
- ✓ Capture inner-loop budget assertion deferred to integration phase (T022) — `Restorer` itself is O(windows) with constant-time identity matching via `Dictionary`
- ✓ Restore: `Restorer.apply` is O(snapshot.windows) with `Dictionary` lookup for live-window matching — no nested iterations
- ✓ Memory: snapshots are value types; no caches; no in-memory history retained
- ✓ Debouncer uses `DispatchWorkItem` cancellation — no leaked timers
- ⚠ Advisory (not blocking): when `SnapshotEngine.capture` lands, ensure its AX-attribute reads minimize allocations in the hot path (T024 task acceptance)

### Constitution Alignment Table

| § | Verdict | Notes |
|---|---|---|
| I | PASS | Pure Swift; no cross-platform shim |
| II | PASS | Layered resolver enforces order; `OrdinalProvider` always-resolves |
| III | PASS | `Restorer` 1-px-tolerance + isFullscreen-state-match before any AX call |
| IV | PASS | No network code; persistence under Application Support; mode 0o700 |
| V | DEFERRED | `PermissionsBootstrap` in follow-up |
| VI | DEFERRED | `PrivateCGS` in follow-up; ADR-0001 already documents the contract |
| VII | PARTIAL | `Debouncer` cap honoured; capture wall-clock test deferred to integration |

### Verdict

**APPROVE** (slice). No critical issues. The 2 advisories above are tracked for follow-up sessions.

---

## Security Reviewer — 5-pass review

### Pass 1 — Secrets scan
- Grep on all added files for `AKIA*`, `xox[baprs]-*`, `sk_live_*`, `BEGIN [A-Z]+ PRIVATE KEY`, `password`, `secret`, App-Specific-Password patterns: **CLEAN**
- No `.env`, `*.cer`, `*.p12`, `*.mobileprovision`, `*.pem` files added: **CLEAN**

### Pass 2 — Threat surface (macOS-adapted OWASP)
- **Pasteboard injection**: no code reads pasteboard. N/A this slice.
- **URL scheme injection**: no `application(_:open:)` handler. N/A this slice.
- **AppleScript injection**: no `NSAppleScript` in PixPutCore. Will need re-review when `BrowserTabSetProvider` is wired to ScriptingBridge.
- **AX privilege creep**: no AX code in PixPutCore. Will need re-review when `AXClient` lands.
- **Insecure persistence**: `SnapshotStore` writes only under the user-provided `directory` URL with mode `0o700`. Caller responsibility to set `directory = ~/Library/Application Support/DisplayMaid-Next/snapshots`. Verified by test.
- **Insecure IPC**: no XPC, no distributed notifications subscribed. N/A this slice.
- **Verbose logging**: no logging code yet. Re-review when `Infra/Logging` lands.
- **Network exfiltration**: zero outbound calls. Will need re-review when Sparkle wiring lands.
- **Sparkle misconfiguration**: N/A — Sparkle not wired this slice.

### Pass 3 — Dependency advisories
- `Package.swift` declares no external dependencies. Only `CryptoKit` (system framework, used for SHA-256 in `DisplayFingerprint`) and `Foundation`/`CoreGraphics`. **CLEAN**
- When `swift-log` and `Sparkle 2.x` are added (next session), run `swift package show-dependencies` and join against the GitHub Advisory DB before opening the PR.

### Pass 4 — Info.plist / Entitlements
- N/A this slice (no Info.plist yet; tracked as T005 in `tasks.md`).
- Re-review when T005 lands. Must verify: `LSUIElement=YES`, `NSAppleEventsUsageDescription` present, `com.apple.security.app-sandbox` NOT set, Hardened Runtime enabled.

### Pass 5 — Permission-pattern audit
- `.claude/settings.json` not modified in this slice. **CLEAN**
- `.claude/settings.local.json` not modified. **CLEAN**

### Security Verdict

| Field | Value |
|---|---|
| Verdict | **PASS** |
| Stack | swift / macOS (Core layer only) |
| Critical findings | 0 |
| Advisory findings | 0 |
| Dependency advisories | 0 |
| Info.plist findings | N/A (file not present) |

### Scanners run

- secrets-grep: PASS
- swift-package-dep-advisory: SKIPPED (no external deps)
- Info.plist / Entitlements diff: SKIPPED (file not present)
- permission-pattern audit: PASS

---

## Documentation Verdict — documentation

**Verdict**: UPDATED

- `CHANGELOG.md` entry appended under `## [Unreleased] / ### Added`
- `README.md` created at repo root with project intro + dev quickstart
- `roadmap/product/001-core-window-memory/quickstart.md` updated to include the fullscreen-restoration scenario added at spec-phase amendments
- `roadmap/arch/c4/` and `roadmap/arch/decisions/0001-private-cgs-for-spaces.md` created during spec-phase architect run — no additional doc work needed this phase
- `CLAUDE.md` agent-roster table — not changed (no new agents added; the existing rewritten agents are in place)
