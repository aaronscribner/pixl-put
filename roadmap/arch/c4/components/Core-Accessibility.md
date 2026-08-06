# Component: Core/Accessibility

**Status**: Stub | **Layer**: Core | **AX dispatch-queue discipline point**

## Purpose

Encapsulate every call to the macOS Accessibility API (`AXUIElement*`, `kAX*Attribute`). All AX work is serialised on a single dedicated dispatch queue to prevent AX deadlocks (project constitution §VII operational requirement).

## Responsibilities

- `AXClient` — public façade exposing `enumerateWindows()`, `read(_:)`, `write(_:value:)`, scoped to the AX queue
- `AXWindow` — typed wrapper around an `AXUIElement` representing a window (bundle ID, title, frame, AX attribute getters)
- Centralise AX permission state checks; refuse calls (returning a typed error) when AX is denied
- Provide cancellation hooks so `Restorer` can abort a single-window move when the user starts dragging (FR-012)

## AX Queue Discipline

- All AX calls execute on a single serial `DispatchQueue` (qos: `.utility`)
- Public API is `async` — callers await results without managing the queue themselves
- Cancellation propagates via Swift `Task` cancellation

## Boundaries

- AX calls happen **only** here; no other file imports `ApplicationServices` for AX use
- Permission prompts NOT triggered here — those are owned by `App/PermissionsBootstrap`
- Does NOT touch CGS, snapshot files, or identity resolution

## Dependencies

- `ApplicationServices` (AX API)
- `App/PermissionsBootstrap` (permission state)
- `Infra/Logging` (AX failures, denied calls)

## Files (per plan.md)

- `Core/Accessibility/AXClient.swift`
- `Core/Accessibility/AXWindow.swift`

## Constitution Alignment

- §I Native macOS — public AX API
- §V Graceful permission degradation — AX-denied returns a typed error; UI surfaces banner
- §VII Performance — single AX queue prevents deadlocks; `.utility` QoS keeps background work below foreground UI

## Open Questions

- AX attribute caching: each window's frame is read multiple times during capture; cache per-cycle? — defer until perf budget pressure surfaces.
- `AXObserver` for live position updates (vs polling) — out of scope for v1; revisit if FR-012 (user-drag-during-restore) needs sub-50ms response.
