# Analysis: Core Window Memory

**Feature**: 001-core-window-memory | **Phase**: analyze | **Generated**: 2026-05-27

Cross-artefact analysis. Each reviewer agent appends its analyze-phase verdict here. The `pre-implement-analyze.sh` hook checks this file before allowing any Swift source-file write; clearance requires (a) all three blocks present, (b) no `BLOCKING` / `IDIOM-GAP` / `CONSTITUTION-GAP` verdicts.

## Artefacts under review

- [`spec.md`](./spec.md) — feature spec, amendments dated 2026-05-27 (SC-003 inner budget, SC-008 memory, Story-1 fullscreen acceptance)
- [`plan.md`](./plan.md) — implementation plan, plan-phase ALIGNED verdict appended
- [`tasks.md`](./tasks.md) — 60 tasks (T001–T125), tasks-phase OK verdict appended
- [`data-model.md`](./data-model.md) — Codable types (no changes this phase)
- [`research.md`](./research.md) — design research (no changes this phase)
- [`quickstart.md`](./quickstart.md) — manual-test scenarios (will be amended at impl time to cover fullscreen restoration)
- [`contracts/snapshot.schema.json`](./contracts/snapshot.schema.json) — on-disk JSON shape
- [`../../arch/c4/`](../../arch/c4/) — C4 model (skeleton created spec-phase)
- [`../../arch/decisions/0001-private-cgs-for-spaces.md`](../../arch/decisions/0001-private-cgs-for-spaces.md) — ADR

---

## Architect Review — analyze phase

**Verdict**: ALIGNED

**Cross-artefact consistency:**
- **Spec ↔ Plan**: Every spec functional requirement (FR-001 through FR-019) maps to a plan section or a task. The plan's Project Structure 1:1 with C4 components. Performance budgets in plan (Technical Context) match spec SCs.
- **Spec ↔ Tasks**: Every spec acceptance criterion (Story 1–5 + Edge Cases) has at least one corresponding task. Spec FR-002 layered identity → T030 + T036 + T037. Spec FR-010 idempotence → T012 + T018. Spec FR-011 displaced-window count → T018 (Restorer skip-missing). Spec edge case "Accessibility permission revoked at runtime" → T102 (PermissionsBootstrap). Spec edge case "user drags during restore" → T081 (cancellation).
- **Tasks ↔ C4**: Every task's target file is documented in a C4 component file. No file in tasks.md sits outside a documented C4 component.
- **Plan ↔ Contracts**: `contracts/snapshot.schema.json` matches the `Codable` types in `data-model.md` (cross-checked: top-level `Snapshot` shape, `WindowEntry` shape, `WindowIdentity` tagged-union variants all 1:1).
- **Spec ↔ ADR-0001**: Spec implies Space-aware restore (Story 1 acceptance #1 "on its recorded display and Space"; FR-009 "on its recorded Space"). ADR-0001 documents the three private CGS symbols this requires + fallbacks. Linked.

**C4 deltas dropped**: none. All architect-required C4 updates from spec-phase are present and complete.

**Source mode**: directory

**Re-validated constitution alignment** (all 7 principles):
- §I Native macOS — PASS
- §II Layered identity — PASS
- §III Idempotence — PASS
- §IV Local-only data — PASS
- §V Graceful permission degradation — PASS
- §VI Direct distribution + justified private API — PASS
- §VII Performance — PASS (all four budgets covered by SCs)

---

## Code Reviewer Verdict — analyze phase

**Verdict**: OK

**Drift check vs tasks-phase**: no drift. Task list unchanged since the tasks-phase OK verdict was filed; idiom + extension-point mapping holds.

**Test-task ↔ Swift idiom (re-validation per `agents/stacks/swift.md`)**:
- XCTest naming convention `test_<what>_<when>_<then>` — all RED-phase task descriptions follow it
- Each test task targets a single behaviour
- Mocking confined to external dependencies (AX, CGS, NSWorkspace, file system) — no system-under-test mocks
- Performance budget assertions are present where the spec mandates them (T022 capture; T125 memory)
- async/await preferred over completion handlers — T082 `AXClient` task explicitly uses async API
- Value types (`struct`, `enum`) over reference types — `Snapshot`, `WindowEntry`, `WindowIdentity` are all structs/enums; only `WindowIdentityResolver` is a class (justified — provider registry needs identity)

**Constitution alignment held**: yes (all 7 principles). No new code paths since tasks-phase.

**Open advisories from tasks-phase** (still informational, not gaps):
1. v1 scope narrowing on AppProviders (Brave + VS Code only) — documented in T041/T042 task descriptions.
2. Performance tests need `#if arch(arm64) && os(macOS)` guards for non-Apple-Silicon CI runners.
3. JSON schema validator in tests should be an in-tree helper, not a 3rd-party Swift package.

---

## Security Verdict — security-reviewer

**Verdict**: PASS

**Scanned at**: 2026-05-27 (analyze phase — pre-implementation)
**Stack**: swift / macOS

**Scope of this pre-implementation scan**: spec.md, plan.md, tasks.md, contracts/, C4, ADR. (No source code exists yet — secrets / dep / Info.plist scans deferred to post-implementation security review at PR time.)

### Pre-implementation security review

- **No secrets in spec/plan/tasks**: clean.
- **Threat surface inventoried**:
  - Pasteboard / URL scheme: none planned for v1 (no `application(_:open:)` handler in plan.md).
  - AppleScript injection: present per spec FR-002 (deep identity via ScriptingBridge) — mitigated by per-provider command-builder pattern documented in [`Core-Identity.md`](../../arch/c4/components/Core-Identity.md). Implementation must use parameterised AppleScript record construction, not string concatenation. **Track at PR time.**
  - AX permission gating: spec FR-013 enforces; plan implements via `App/PermissionsBootstrap`. Sound.
  - Automation permission: spec FR-014 per-bundle lazy; sound.
  - Persistence path: spec FR-003 + plan storage layout = under `~/Library/Application Support/DisplayMaid-Next/` only. Constitution §IV compliant. Default file mode 0o700 per T111 task.
  - Network surface: spec FR-019 + SC-007 + plan dependency list. Only outbound is Sparkle appcast. Constitution §IV compliant.
  - Sparkle config: spec FR-017 mandates HTTPS appcast + EdDSA verification. T005 placeholders SUFeedURL and SUPublicEDKey to TODO sentinels; **real values are a human handoff item** — flagged in the implementation-phase output.

### Dependency advisories (planned dependency set)
- `Sparkle` 2.x — confirm at PR time against GitHub Advisory DB; pin to known-good release (2.5.x or later as of analysis date).
- `swift-log` — Apple-maintained, no current advisories. Pin to a 1.x release.
- No other 3rd-party deps planned for v1.

### Info.plist / Entitlements (planned shape)
- `LSUIElement = YES` — correct (menu bar app, no Dock icon)
- `NSAppleEventsUsageDescription` — required (lazy Automation per-bundle)
- `NSSystemAdministrationUsageDescription` — likely NOT needed (no admin operations)
- `com.apple.security.app-sandbox` — must NOT be set (AX workflow forbids sandbox; project constitution §I implication)
- Hardened Runtime — required (project constitution §VI). Confirm in `Entitlements.plist`.

### Scanners run (pre-implementation)
- secrets-grep (artefacts only): PASS
- swift-package dep advisory: SKIPPED (no Package.swift yet — will run at PR time)
- Info.plist / Entitlements diff: SKIPPED (no files yet — will run at PR time)
- permission-pattern audit: PASS (no changes to `.claude/settings*.json` in this phase)

---

## Documentation Verdict — documentation

**Verdict**: NO-OP (artefacts only; no source code yet → no README / CHANGELOG / ADR delta beyond what architect created)

Documentation pass will fire at PR time per the rewritten `documentation.md` agent's coordination rule (runs AFTER `qa` validates the cycle and AFTER `security-reviewer` passes, BEFORE PR opens).

---

## Gate Clearance

| Verdict | Status |
|---|---|
| Architect Review — analyze phase | **ALIGNED** ✓ |
| Code Reviewer Verdict — analyze phase | **OK** ✓ |
| Security Verdict | **PASS** ✓ |
| Documentation Verdict | NO-OP (deferred to PR time) |

`pre-implement-analyze.sh` clearance: **GRANTED**. Swift source-file writes may proceed.
