# Component: Settings

**Status**: Stub | **Layer**: MenuBar/Settings

## Purpose

SwiftUI Settings scene exposing user-facing preferences: snapshot retention count, restore behaviour toggles (`restoreMinimized`, `relaunchMissingApps`), per-bundle Automation status overrides.

## Responsibilities

- Render the Settings scene (General, Snapshots, App Rules panes)
- Read/write `preferences.json` via the persistence boundary (NOT `UserDefaults`)
- Display per-bundle Automation permission state from `App/PermissionsBootstrap`
- Allow user to clear a bundle's deep-identity provider (re-prompt next session)

## Boundaries

- Reads/writes `~/Library/Application Support/DisplayMaid-Next/preferences.json` via `Infra/Paths`
- Does NOT call AX, CGS, or perform capture/restore directly
- Imports `SwiftUI`; thin AppKit shim only for hosting

## Dependencies

- `Infra/Paths` (preferences file path)
- `App/PermissionsBootstrap` (read Automation status)
- `Core/Identity` (read provider list for AppRules pane)

## Files (per plan.md)

- `Settings/SettingsScene.swift` — SwiftUI scene
- `Settings/GeneralPane.swift`
- `Settings/SnapshotsPane.swift`
- `Settings/AppRulesPane.swift` — per-bundle Automation status + overrides

## Constitution Alignment

- §IV Local-only data: preferences persist to Application Support, not `UserDefaults` (inspectable / portable)
- §V Graceful permission degradation: AppRules pane lets the user see and reset Automation grants per-bundle

## Open Questions

- Snapshot retention slider range and default — pending UX research.
- App Rules pane discovery model — list known browsers/editors vs. learned-as-used? — pending UX research.
