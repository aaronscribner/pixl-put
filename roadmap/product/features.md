# DisplayMaid-Next — Feature Set

Every feature the product will or might ship, grouped by release horizon.
The status column indicates whether it is committed (✅), planned (🟡),
candidate (🟦), or explicitly rejected (❌).

Each feature row links to the spec that owns it, where one exists. v1 rows
mostly trace to [`spec.md` for spec 001](../../specs/001-core-window-memory/spec.md);
post-v1 rows do not yet have specs and will need them when promoted.

## v1 — Core Window Memory (spec 001)

The MVP. Everything required to honestly claim "DisplayMaid-Next remembers
your windows." Ships as a single feature; user stories ship together rather
than incrementally because Story 1 (restore) has no value without Story 2
(capture), and Story 3 (per-instance identity) is the headline differentiator.

| Feature | Status | Source | Notes |
|---------|--------|--------|-------|
| Auto-restore on wake | ✅ | spec 001, US1 | NSWorkspace wake + CGDisplay reconfigure |
| Auto-capture on idle | ✅ | spec 001, US2 | Screensaver / display sleep / screen lock |
| Per-window-instance identity (browsers, editors, terminals) | ✅ | spec 001, US3 | The headline differentiator |
| Display-configuration partitioning | ✅ | spec 001, US4 | Snapshots keyed by vendor/product/UUID hash |
| Manual capture / restore from menu bar | ✅ | spec 001, US5 | Subset — naming is the optional half |
| Named snapshots ("morning setup", "video call") | ✅ | spec 001, US5 | P3 within v1; ship if it fits, push to v1.1 if not |
| LSUIElement menu bar app, no Dock icon | ✅ | spec 001, FR-016 | |
| Onboarding for Accessibility permission | ✅ | spec 001, FR-013 | |
| Per-bundle Automation prompt, lazy | ✅ | spec 001, FR-014/015 | Never proactive, never re-prompted in-session |
| Sparkle auto-update with EdDSA verification | ✅ | spec 001, FR-017 | |
| Notarized, Hardened-Runtime, Developer-ID signed | ✅ | spec 001, FR-018 | Un-notarized builds refuse to run |
| Local-only persistence (JSON under Application Support) | ✅ | spec 001, FR-003 | 10 snapshots/config retained, configurable |
| Snapshot history rotation | ✅ | spec 001, FR-003 | |
| Pause auto-capture toggle | ✅ | spec 001, US2 AS3 | |
| "X windows displaced" indicator | ✅ | spec 001, FR-011 | When a recorded display is gone |
| Best-effort badge on ordinal-matched windows | ✅ | spec 001, US3 AS3 | |
| Cancel restore on user interaction with a window | ✅ | spec 001, FR-012 | Never fight the user |

### v1 deep-identity providers

The bundle IDs we ship a deep-identity provider for in v1. Each is a row in
the table because each is an independent Automation-permission contract with
the user.

| Provider | Bundles | Identity yielded |
|----------|---------|------------------|
| BrowserTabSetProvider | Brave, Edge, Chrome, Arc, Safari | Set of tab URLs |
| VSCodeWorkspaceProvider | VS Code, VS Code Insiders | Workspace folder URL |
| XcodeProvider | Xcode | Open project/workspace path |
| TerminalCWDProvider | iTerm2, Apple Terminal, Ghostty, Warp | Frontmost session CWD |
| JetBrainsProvider | IntelliJ family (IDEA, PyCharm, WebStorm, GoLand, RustRover) | Open project path |

A new bundle ID is a new file in `Core/Identity/AppProviders/`; it is not a
new spec. The constitution treats this as the standard extension point.

## v1.x — Post-launch hardening and power-user features

Things called out as edge cases or P3 in spec 001 that are likely to graduate
to dedicated specs once v1 telemetry-free user reports come in.

| Feature | Status | Rationale |
|---------|--------|-----------|
| Relaunch missing apps on restore | 🟡 | spec 001 edge case, currently opt-in / off. Likely promoted to first-class with a confirmation prompt. |
| Restore minimized state | 🟡 | spec 001 edge case. Preference exists but defaults off; revisit after user feedback. |
| Per-app rules / overrides | 🟡 | `AppRulesPane` is stubbed in plan.md. Power-users will want to exclude specific apps, force ordinal-only for one bundle, or pin a window to a frame regardless of snapshot. |
| Snapshot diff viewer | 🟦 | "Show me what changed since last capture." Useful for trust-building before auto-restore runs. |
| Manual snapshot import/export | 🟦 | Constitution §IV explicitly permits a user-initiated export. Format: the same JSON we already write. |
| Per-snapshot scheduling ("every weekday at 18:00, capture as 'EOD'") | 🟦 | Light cron, on-device only. Possible if `IdleTriggerWatcher` grows a manual-trigger sibling. |
| Hotkey to restore last snapshot | 🟦 | Global hotkey via MASShortcut or hand-rolled. Single-purpose. |
| Multi-snapshot stacking ("restore window positions but not Spaces") | 🟦 | Splits restore into composable layers. Likely needed once power-user rules exist. |

## v2+ — Possible new directions

Bigger swings that would need their own constitution amendments or new
architectural commitments. Listed so they exist in writing; none are
committed.

| Feature | Status | What it would require |
|---------|--------|----------------------|
| Sync snapshots across the user's own Macs (without a service) | 🟦 | iCloud Drive folder convention or user-pointed shared folder. Strict on-device principle (§IV) would need a clarification, not an amendment. |
| MDM-managed deployments | 🟦 | Permission flow needs a non-prompt path; out of scope for v1 per spec.md Assumptions. |
| Fast User Switching / multi-user awareness | 🟦 | Currently out of scope per spec.md Assumptions. Needs scoped snapshot dirs per `uid`. |
| Sidecar / AirPlay / Continuity display first-class handling | 🟦 | spec 001 accepts "quirks acceptable for v1". Real users may demand better. |
| Stage Manager interop | 🟦 | Stage Manager owns window positions when active; restoring while it is on may need a dedicated path. |
| Window-arrangement editor (drag windows around in a UI without using the windows themselves) | 🟦 | A different product. Would require a constitution clarification that we still aren't a tiling manager. |
| Linux / Windows port | ❌ | Constitution §I rules out cross-platform. Not on the roadmap. |
| Cloud-synced snapshots (with a service) | ❌ | Constitution §IV. Hard line. |
| Telemetry of any kind | ❌ | Constitution §IV. Hard line. |
| Mac App Store distribution | ❌ | Sandboxing forbids the AX/CGS work the product is built on. |

## Provenance

This document is regenerated whenever:

- A spec is added to `specs/` (a new row appears here referencing it).
- A constitution principle changes that would change the ❌ rows above.
- A v1.x or v2+ feature is promoted to a planned spec (its status changes
  from 🟦 → 🟡 and a spec link is added when one exists).

It is read alongside [`vision.md`](./vision.md) and
[`roadmap.md`](./roadmap.md) when scoping new work.
