# C4 Level 2 — Containers

**Status**: Stub (created by architect agent, spec-phase, feature 001-core-window-memory)

## Purpose

DisplayMaid-Next is a single binary — there is exactly one container at C4 Level 2. This file documents the container's responsibilities, its persistence boundary, and the external interfaces it exposes (none over the network; all via the user's home directory and the macOS UI).

## Container: DisplayMaid-Next.app

| Property | Value |
|---|---|
| Kind | macOS Cocoa application |
| Distribution | Developer-ID-signed, notarised `.app` with Hardened Runtime + Sparkle 2.x auto-update |
| Bundle identifier | `co.cerebraljuice.pixput` (canonical — confirm at first build) |
| LSUIElement | `true` (menu bar only, no Dock icon, no main window unless Settings is open) |
| Languages | Swift 5.10+ |
| Frameworks | AppKit, SwiftUI (Settings only), ApplicationServices (AX), CoreGraphics (incl. private CGS — isolated per project constitution §VI), IOKit, ScriptingBridge, swift-log, Sparkle 2.x |
| Minimum OS | macOS 14 Sonoma |

## Persistence

| Path | Format | Purpose |
|---|---|---|
| `~/Library/Application Support/DisplayMaid-Next/snapshots/<displayConfigurationID>.json` | JSON (`Codable`, prettified) | Snapshot history per display configuration. Rotated to N=10 entries (configurable). |
| `~/Library/Application Support/DisplayMaid-Next/preferences.json` | JSON (`Codable`, prettified) | User preferences (kept out of `UserDefaults` for inspectability / portability). |
| `~/Library/Application Support/DisplayMaid-Next/logs/` | Rotating text logs (swift-log + custom destination) | 7-day retention, 50 MB total cap. No PII (tab URLs, document paths) without redaction. |

All persistence is on-device. There is no network sync. (Project constitution §IV.)

## Internal Components (forward reference to Level 3)

See `components/` for one Markdown file per component:

- `App.md` — `@main`, lifecycle, permissions bootstrap
- `MenuBar.md` — `NSStatusItem` + menu + status model
- `Settings.md` — SwiftUI Settings scene
- `Core-Snapshot.md` — `SnapshotEngine`, `SnapshotStore`, `Restorer`, `WindowEntry`
- `Core-Identity.md` — `WindowIdentityResolver` and providers
- `Core-Displays.md` — `DisplayConfigWatcher`, `DisplayFingerprint`
- `Core-Spaces.md` — `SpaceResolver`, `PrivateCGS` (private CG symbol isolation)
- `Core-Triggers.md` — `IdleTriggerWatcher`, `WakeTriggerWatcher`, `Debouncer`
- `Core-Accessibility.md` — `AXClient`, `AXWindow` (AX dispatch-queue discipline)
- `Infra.md` — `Logging`, `Paths`, `Updates` (Sparkle setup)

## Performance Envelope (project constitution §VII)

| Metric | Budget |
|---|---|
| Snapshot capture | ≤ 500 ms wall clock for 100 windows on Apple Silicon |
| Restore | ≤ 2 s wall clock for 50 windows |
| Idle CPU (no events) | ≤ 0.1% averaged over 5 minutes |
| Resident memory | ≤ 30 MB steady state |

## Open Questions

- Bundle identifier: confirm `co.cerebraljuice.pixput` matches release-engineering plan, or update.
- Sparkle EdDSA public key: must be set in `Info.plist` (`SUPublicEDKey`) before first signed build.
- Sparkle appcast URL: must be set in `Info.plist` (`SUFeedURL`) — staging vs production handling TBD.

## References

- Plan: [`../../../product/001-core-window-memory/plan.md`](../../../product/001-core-window-memory/plan.md)
- Constitution: [`../../../product/constitution.md`](../../../product/constitution.md) §I, §IV, §VI, §VII
