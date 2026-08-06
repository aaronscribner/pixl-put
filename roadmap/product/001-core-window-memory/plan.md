# Implementation Plan: Core Window Memory

**Branch**: `001-core-window-memory` | **Date**: 2026-05-23 | **Spec**:
[spec.md](./spec.md)

**Input**: Feature specification from [`./spec.md`](./spec.md)

## Summary

A macOS menu bar app that captures the current window arrangement when the
machine goes idle and restores it when the machine wakes. Windows are
identified by a layered identity strategy strong enough to disambiguate
multiple instances of the same app (browsers, editors, terminals).
Snapshots are partitioned by display configuration so dock/undock cycles
preserve their respective arrangements.

Technical approach: a single Swift `LSUIElement` app using the Accessibility
API for window manipulation, distributed notifications + `NSWorkspace`
notifications for trigger events, private `CGSCopyManagedDisplaySpaces` for
Space identification, and ScriptingBridge/AppleScript for per-app deep
identity providers. All state persisted as JSON via `Codable` under
Application Support.

## Technical Context

**Language/Version**: Swift 5.10+ (Xcode 15.4+)

**Primary Dependencies**:
- AppKit (menu bar, app lifecycle)
- SwiftUI (Settings window + onboarding only)
- ApplicationServices (Accessibility API)
- CoreGraphics + private CGS symbols (`CGSCopyManagedDisplaySpaces`,
  `CGSGetActiveSpace`)
- IOKit (display reconfiguration callbacks via
  `CGDisplayRegisterReconfigurationCallback`)
- ScriptingBridge (per-bundle scripting interfaces for browsers, editors,
  terminals) with NSAppleScript fallback
- Sparkle 2.x (auto-update)
- swift-log + a custom rotating file destination (no console spam)
- No third-party UI frameworks.

**Storage**: JSON files (Codable, prettified) under
`~/Library/Application Support/DisplayMaid-Next/`:
- `snapshots/<displayConfigurationID>.json` — snapshot history per config.
- `preferences.json` — user preferences (not in `UserDefaults` so they are
  user-inspectable / portable).
- `logs/` — rotating log files, 7 day retention, capped at 50 MB total.

**Testing**: XCTest for pure-Swift modules (identity resolution, snapshot
codec, debouncer, display-config fingerprinting). UI/integration testing is
manual against a checklist documented in `quickstart.md`. No XCUITest — the
Accessibility-driven nature of the product makes UI automation unreliable.

**Target Platform**: macOS 14 Sonoma and later, Apple Silicon and Intel.

**Project Type**: desktop-app (menu bar `LSUIElement`).

**Performance Goals**:
- Capture: ≤ 500 ms wall clock for 100 windows.
- Restore: ≤ 2 s wall clock for 50 windows.
- Idle CPU: ≤ 0.1% averaged over 5 min with no events.
- Resident memory: ≤ 30 MB steady state.

**Constraints**:
- No off-device network traffic except Sparkle appcast fetch.
- Must function under standard non-MDM macOS configurations.
- Background work at QoS `.utility`; AX calls serialized on a single
  dedicated dispatch queue to avoid AX deadlocks.

**Scale/Scope**:
- Hundreds of windows max realistic per session.
- Up to ~10 historical snapshots per display configuration.
- ~6 display configurations per user typical (laptop alone, +1 monitor,
  +2 monitor, sidecar, etc.).

## Constitution Check

Cross-referencing [`../constitution.md`](../constitution.md):

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Native macOS, no compromises | ✅ Pass | Swift + AppKit + SwiftUI only. |
| II. Layered window identity | ✅ Pass | `WindowIdentityProvider` protocol with ordered providers; title-only forbidden. |
| III. Idempotent operations | ✅ Pass | Capture is read-only and deterministic; restore checks current frame before moving. |
| IV. Local-only data | ✅ Pass | All persistence under Application Support; only network call is Sparkle appcast (allowed by constitution, listed in SC-007 caveat). |
| V. Graceful permission degradation | ✅ Pass | Per-bundle Automation prompts are lazy; AX is the only hard requirement, surfaced in onboarding. |
| VI. Direct distribution + justified private API | ✅ Pass | Private CGS isolated to `PrivateCGS.swift` with a documented fallback path. |
| VII. Performance is a feature | ✅ Pass | Performance budgets reflected in SCs and Technical Context. |

No deviations. Complexity Tracking table is intentionally empty.

## Project Structure

### Documentation (this feature)

```text
roadmap/product/001-core-window-memory/
├── plan.md              # This file
├── spec.md              # Feature spec
├── research.md          # Design research (window identity, macOS APIs)
├── data-model.md        # Entity definitions
└── quickstart.md        # Manual-test checklist
```

### Source Code (repository root)

```text
DisplayMaid-Next/
├── App/
│   ├── DisplayMaidApp.swift              # @main, NSApplicationDelegate
│   ├── AppLifecycle.swift                # launch / terminate / wake routing
│   └── PermissionsBootstrap.swift        # AX + Automation permission state machine
├── MenuBar/
│   ├── MenuBarController.swift           # NSStatusItem + menu
│   ├── MenuBarStatusModel.swift          # Observable "last capture / last restore"
│   └── OnboardingWindow.swift            # SwiftUI first-run flow
├── Settings/
│   ├── SettingsScene.swift               # SwiftUI settings (Scene)
│   ├── GeneralPane.swift
│   ├── SnapshotsPane.swift
│   └── AppRulesPane.swift                # Per-bundle Automation status + overrides
├── Core/
│   ├── Snapshot/
│   │   ├── SnapshotEngine.swift          # capture() orchestrator
│   │   ├── SnapshotStore.swift           # Codable JSON persistence + rotation
│   │   ├── Restorer.swift                # restore() orchestrator
│   │   └── WindowEntry.swift             # Codable model
│   ├── Identity/
│   │   ├── WindowIdentity.swift          # Tagged-union model
│   │   ├── WindowIdentityResolver.swift  # Tries providers in order
│   │   ├── DocumentPathProvider.swift
│   │   ├── TitleRegexProvider.swift
│   │   ├── OrdinalProvider.swift
│   │   └── AppProviders/
│   │       ├── BrowserTabSetProvider.swift   # Brave/Edge/Chrome/Arc/Safari
│   │       ├── VSCodeWorkspaceProvider.swift
│   │       ├── XcodeProvider.swift
│   │       └── TerminalCWDProvider.swift     # iTerm2/Terminal/Ghostty/Warp
│   ├── Displays/
│   │   ├── DisplayConfigWatcher.swift    # CGDisplayRegisterReconfigurationCallback
│   │   ├── DisplayFingerprint.swift      # vendor/product/UUID hashing
│   │   └── DisplayConfiguration.swift    # Codable model
│   ├── Spaces/
│   │   ├── SpaceResolver.swift           # Uses PrivateCGS
│   │   └── PrivateCGS.swift              # All private symbols isolated here
│   ├── Triggers/
│   │   ├── IdleTriggerWatcher.swift      # distributed notifications + screen sleep
│   │   ├── WakeTriggerWatcher.swift      # NSWorkspace + display callback
│   │   └── Debouncer.swift               # Generic event coalescer
│   └── Accessibility/
│       ├── AXClient.swift                # Serialized AX queue + helpers
│       └── AXWindow.swift                # Typed wrapper over AXUIElement
├── Infra/
│   ├── Logging.swift                     # swift-log + rotating file dest
│   ├── Paths.swift                       # Application Support paths
│   └── Updates.swift                     # Sparkle setup
├── Resources/
│   ├── Info.plist
│   ├── Entitlements.plist
│   ├── DisplayMaidNext.sdef              # ScriptingBridge sdef references
│   └── Assets.xcassets
└── Tests/
    ├── IdentityTests/
    ├── SnapshotCodecTests/
    ├── DebouncerTests/
    ├── DisplayFingerprintTests/
    └── Fixtures/
        ├── BraveTabSets.json
        └── VSCodeTitles.txt
```

**Structure Decision**: Single Swift Package / Xcode project, internally
layered as `App → MenuBar/Settings → Core → Infra`. `Core` is the only
testable layer (pure Swift, no AppKit dependencies except where it imports
`ApplicationServices`). `App`, `MenuBar`, and `Settings` are intentionally
thin and not unit-tested — they're exercised through the
`quickstart.md` manual checklist.

The `Core/Identity/AppProviders/` folder is the extension point: a new
deep-identity provider for a bundle ID is a new file in this folder
implementing `WindowIdentityProvider`, registered in `WindowIdentityResolver`.
This is the most common ongoing change after v1 ships.

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

No violations. Table intentionally empty.

---

## Architect Review — plan phase

**Verdict**: ALIGNED
**Reviewed against**: spec.md (with 2026-05-27 amendments), C4 model under `roadmap/arch/c4/`, ADR-0001
**Plan ↔ C4 alignment**:
  - Plan's Project Structure ↔ C4 components: 1:1 mapping verified. Every C4 component in `roadmap/arch/c4/components/` corresponds to a folder or file in plan.md's source tree.
  - Plan's Primary Dependencies ↔ C4 container.md framework list: identical (AppKit, SwiftUI, ApplicationServices, CoreGraphics + private CGS, IOKit, ScriptingBridge, Sparkle 2.x, swift-log).
  - Plan's Storage layout ↔ C4 container.md persistence table: identical paths under `~/Library/Application Support/DisplayMaid-Next/`.
**Constitution Check** (re-validated post spec amendments):
  - §I–§VI: unchanged from spec-phase ALIGNED verdict
  - §VII Performance: now FULLY ALIGNED — SC-001 (restore), SC-003 inner-budget (capture), SC-005 (idle CPU), SC-008 (memory). All four constitution §VII budgets have measurable SCs.
**Required C4 updates**: none. Skeleton + ADR-0001 created in spec-phase covered all updates the plan implies. No new components, no new ADRs needed for the plan as written.
**Source mode**: directory
**Notes**:
  - Plan's "Project Type: desktop-app" + LSUIElement matches C4 container.md.
  - Plan's testing strategy (XCTest for Core only; manual via quickstart.md for AX-driven layers) matches the architect's component classification — testable Core (Snapshot, Identity, Displays, Triggers, Spaces, Accessibility under mocks) vs manually-verified layers (App, MenuBar, Settings, AX/CGS live behaviour).
  - Plan's QoS choice (`.utility` for background AX) matches constitution §VII operational requirement.
