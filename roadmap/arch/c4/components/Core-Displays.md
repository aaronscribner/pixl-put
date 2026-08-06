# Component: Core/Displays

**Status**: Stub | **Layer**: Core

## Purpose

Compute a stable `displayConfigurationID` from the current set of attached displays. Watch for reconfiguration events (`CGDisplayRegisterReconfigurationCallback`) and emit changes that drive snapshot partitioning (FR-001) and wake-restore selection (FR-006).

## Responsibilities

- Fingerprint each `Display` by vendor ID + product ID + hash of `displayUUID`
- Combine display fingerprints into a deterministic `displayConfigurationID` independent of port ordering
- Subscribe to `CGDisplayRegisterReconfigurationCallback`
- Publish "configuration changed" events to subscribers (`Core/Triggers`, `Core/Snapshot`)

## Boundaries

- Reads CoreGraphics display info via public APIs (`CGDisplayCopyDisplayMode`, `CGDisplayVendorNumber`, etc.) — NO private CGS calls here
- Does NOT touch AX, snapshot files, or per-window state
- Emits changes via a typed publisher (Combine `PassthroughSubject` or async stream)

## Dependencies

- `CoreGraphics` (public display APIs)
- `IOKit` (for additional vendor/product info if needed)
- `Infra/Logging` (configuration-change events)

## Files (per plan.md)

- `Core/Displays/DisplayConfigWatcher.swift` — registers / unregisters CG reconfiguration callback
- `Core/Displays/DisplayFingerprint.swift` — vendor / product / UUID hashing
- `Core/Displays/DisplayConfiguration.swift` — `Codable` model

## Constitution Alignment

- §I Native macOS — uses CoreGraphics public APIs
- §VII Performance — fingerprint computation is O(displays), called only on configuration change

## Open Questions

- Sidecar / AirPlay / Continuity display fingerprint stability — spec assumption says v1 acceptable, observe in beta.
- Headless / no-display state (e.g. lid closed, no external monitor) — behaviour TBD; likely "no snapshot".
