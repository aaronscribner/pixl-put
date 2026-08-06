# Component: Core/Spaces

**Status**: Stub | **Layer**: Core | **Private CG symbol isolation point**

## Purpose

Resolve which macOS Space (Mission Control workspace) each window is on, and identify the Space a window must be restored to. This is the **single isolation point** for private CoreGraphics symbols per project constitution §VI. Every private symbol used by the app lives in `PrivateCGS.swift`; no other file references private CGS.

## Responsibilities

- `SpaceResolver.spaceForWindow(axWindow)` — return the Space ID for a given window
- `SpaceResolver.activeSpace()` — return the currently active Space ID
- `PrivateCGS.swift` — thin Swift wrappers around the private symbols, with documented fallback paths

## Private CG Symbols (project constitution §VI scope)

| Symbol | Purpose | Fallback if removed in future macOS |
|---|---|---|
| `CGSCopyManagedDisplaySpaces` | Enumerate Spaces per display | Restore-without-Space-awareness; surface a "Spaces not preserved" badge |
| `CGSGetActiveSpace` | Identify the user's current Space | Treat the active Space as "default Space 0" and accept degradation |
| `CGSCopyWindowsWithOptionsAndTags` | Resolve windows-on-Space | Use AX-only enumeration and accept some windows being on wrong Space |

All three symbols are documented in `ADR-0001-private-cgs-for-spaces.md` (see `roadmap/arch/decisions/`).

## Boundaries

- `PrivateCGS.swift` is the **only** file in the app that references private CGS symbols
- Public API of this component is `SpaceResolver` — callers (snapshot, restore) never see the private symbols
- Failures in private CGS calls degrade gracefully per the fallback table above; never crash

## Dependencies

- CoreGraphics (private symbols, declared as `@_silgen_name` or via bridging header)
- `Infra/Logging` (private-symbol availability events)

## Files (per plan.md)

- `Core/Spaces/SpaceResolver.swift` — public API
- `Core/Spaces/PrivateCGS.swift` — all private symbol declarations + fallbacks

## Constitution Alignment

- §I Native macOS — uses CoreGraphics symbols (public + justified private)
- §VI Direct distribution, private API allowed when justified — symbols isolated to one file with fallbacks documented in ADR

## Open Questions

- Each major macOS release (15, 16, …): confirm symbols still ship; update fallback table if any symbol is removed.
- `CGSCopyWindowsWithOptionsAndTags` — confirm need; may be over-spec for v1.
