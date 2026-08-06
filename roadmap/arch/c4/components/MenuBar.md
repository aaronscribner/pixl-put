# Component: MenuBar

**Status**: Stub | **Layer**: MenuBar/Settings

## Purpose

Own the `NSStatusItem`, its menu, the "Last Capture / Last Restore" status surface, and the first-run onboarding window. Reactive only — work is delegated to `Core/*`.

## Responsibilities

- Create + maintain the menu bar item (icon, menu, paused indicator)
- Observe `MenuBarStatusModel` and update display
- Surface "X windows displaced", "best-effort match", paused-auto-capture badges
- Host the first-run onboarding SwiftUI window
- Provide the manual "Capture / Restore / Pause Auto-Capture / Open Settings" menu actions

## Boundaries

- Reads from `MenuBarStatusModel` (an `@Observable`); never writes business state
- Routes user menu actions to `Core/Snapshot` (capture/restore) and `Settings` (open settings scene)
- Does NOT touch AX, CGS, persistence, or display configuration directly

## Dependencies

- `Core/Snapshot/SnapshotEngine` (calls `capture()` / `restore()`)
- `Core/Snapshot/Restorer` (status updates)
- `Settings` (opens Settings scene)
- `App/AppLifecycle` (terminate menu)

## Files (per plan.md)

- `MenuBar/MenuBarController.swift` — `NSStatusItem` + menu
- `MenuBar/MenuBarStatusModel.swift` — `@Observable` "last capture / last restore"
- `MenuBar/OnboardingWindow.swift` — SwiftUI first-run flow

## Constitution Alignment

- §V Graceful permission degradation: onboarding view explains AX + Automation prompts in-context

## Open Questions

- Menu bar icon design tokens (paused vs idle vs error states) — pending UX research.
- Onboarding step ordering: AX-first vs deferred Automation prompts — pending UX research.
