# Component: Core/Snapshot

**Status**: Stub | **Layer**: Core

## Purpose

Orchestrate the capture / restore workflow. Encode and decode snapshot files. Persist with rotation. Skip windows already at their recorded frame within 1 px tolerance (idempotence).

## Responsibilities

- `SnapshotEngine.capture()` — walk currently visible windows via `AXClient`, resolve identity via `WindowIdentityResolver`, build a `Snapshot` value
- `SnapshotStore` — `Codable` JSON read/write under `~/Library/Application Support/DisplayMaid-Next/snapshots/<displayConfigurationID>.json`; rotate to N most recent
- `Restorer.restore(snapshot)` — for each entry, find the current matching window, move via AX if not already at frame within 1 px
- Emit progress / completion events to `MenuBar/MenuBarStatusModel`

## Boundaries

- Reads AX state via `AXClient` (no direct AX calls outside)
- Reads private CG Space data via `Core/Spaces/SpaceResolver` (no direct CGS calls outside `PrivateCGS.swift`)
- Reads display configuration ID from `Core/Displays/DisplayConfigWatcher`
- Writes ONLY to `~/Library/Application Support/DisplayMaid-Next/snapshots/`

## Dependencies

- `Core/Accessibility/AXClient` (window enumeration + position/size mutation)
- `Core/Identity/WindowIdentityResolver` (identity resolution)
- `Core/Displays/DisplayConfigWatcher` (active config ID)
- `Core/Spaces/SpaceResolver` (current Space per window)
- `Infra/Paths` (snapshots directory)
- `Infra/Logging` (events, skipped windows)

## Files (per plan.md)

- `Core/Snapshot/SnapshotEngine.swift`
- `Core/Snapshot/SnapshotStore.swift`
- `Core/Snapshot/Restorer.swift`
- `Core/Snapshot/WindowEntry.swift`

## Constitution Alignment

- §III Idempotence — `Restorer` checks frame ± 1 px before moving (matches spec FR-010)
- §IV Local-only — all I/O under Application Support
- §VII Performance — capture ≤ 500 ms / 100 windows; restore ≤ 2 s / 50 windows; allocations minimised in capture loop

## Open Questions

- Snapshot rotation policy on retention-limit hit: drop oldest unconditionally vs preserve user-named snapshots.
- Concurrent capture from manual + idle trigger: serialise via dispatch queue or rely on `Debouncer` upstream?
