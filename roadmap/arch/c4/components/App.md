# Component: App

**Status**: Stub | **Layer**: App (entry point)

## Purpose

`@main` entry point, `NSApplicationDelegate`, app lifecycle routing, and permissions bootstrap. The thinnest layer — wires everything else together and exits on cold paths.

## Responsibilities

- Launch the AppKit run loop with `LSUIElement = true`
- Hand off to `PermissionsBootstrap` on first run; route to onboarding if AX is missing
- Subscribe to terminate / sleep / wake routing once permissions are confirmed
- Hand off to `MenuBar` for UI, `Core/Triggers` for event subscriptions, `Infra/Updates` for Sparkle

## Boundaries

- Imports `AppKit`, `SwiftUI` (for Settings scene anchoring), `ApplicationServices` (AX permission check only)
- Does NOT call AX, CGS, or perform snapshot/restore work directly — those are `Core/*` responsibilities
- Does NOT do file I/O directly — delegates to `Infra/Paths` + the relevant Core stores

## Dependencies

- `MenuBar` (downstream)
- `Settings` (downstream, via SwiftUI Scene)
- `Core/Triggers` (downstream)
- `Infra/Logging`, `Infra/Paths`, `Infra/Updates` (downstream)

## Files (per plan.md)

- `App/DisplayMaidApp.swift` — `@main`, `NSApplicationDelegate`
- `App/AppLifecycle.swift` — launch / terminate / wake routing
- `App/PermissionsBootstrap.swift` — AX + Automation permission state machine

## Constitution Alignment

- §I Native macOS: pure Swift + AppKit + SwiftUI; no cross-platform shim
- §V Graceful permission degradation: `PermissionsBootstrap` enforces the explicit AX-required / Automation-lazy flow

## Open Questions

- First-run vs upgrade detection: how to identify a returning user with an existing snapshots dir.
- Settings scene activation: dock-icon-bounce vs menu-bar-click-only.
