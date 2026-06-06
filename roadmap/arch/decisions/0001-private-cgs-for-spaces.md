# ADR-0001 — Private CoreGraphics symbols for Space identification

**Status**: Accepted | **Date**: 2026-05-26 | **Author**: architect agent (spec-phase, feature 001-core-window-memory)

## Context

The product's core promise is restoring each window to **the display, frame, and Space** it occupied. Display and frame can be read via fully public Apple APIs (`CGDisplayCopyDisplayMode`, AX `kAXPositionAttribute`, `kAXSizeAttribute`).

Space (Mission Control workspace) cannot. There is no public API to enumerate Spaces, identify a window's Space, or move a window to a specific Space. The relevant symbols live in `SkyLight.framework` / `CoreGraphics.framework` and are private (CGS-prefixed). They have been stable across macOS releases for many years and are used by many notable apps (Hammerspoon, yabai, Magnet, Rectangle Pro, DisplayMaid, etc.) without notarisation issues.

The project constitution §VI explicitly allows private CoreGraphics symbols *when they materially improve user experience*, provided each symbol is isolated to a single file with a documented fallback path.

## Decision

PixPut uses three private CG symbols:

| Symbol | Purpose |
|---|---|
| `CGSCopyManagedDisplaySpaces` | Enumerate Spaces per display (needed to record snapshot per-Space and decide restoration target) |
| `CGSGetActiveSpace` | Identify the user's current Space at capture / restore time |
| `CGSCopySpacesForWindows` | Resolve windows-on-Space (cross-reference with AX-only enumeration for windows hidden behind Mission Control) |

All three are declared and called **only** from `Core/Spaces/PrivateCGS.swift`. The public surface of the `Core/Spaces` component is `SpaceResolver`, which does not expose the private symbols to callers.

## Fallback Path (if any symbol is removed in a future macOS)

| Symbol | Fallback |
|---|---|
| `CGSCopyManagedDisplaySpaces` | Restore without Space awareness; surface a "Spaces not preserved" badge in the menu bar |
| `CGSGetActiveSpace` | Treat the active Space as "default Space 0" and accept degradation (windows still go to the right display + frame, just possibly the wrong Space) |
| `CGSCopySpacesForWindows` | Use AX-only window enumeration; accept that some windows on inactive Spaces may be missed |

The fallback paths are documented in `Core/Spaces/PrivateCGS.swift` next to each symbol declaration.

## Consequences

**Positive**:
- Space-aware restore is possible (project constitution §I + §VI compatible)
- Failure modes degrade gracefully (project constitution §V compatible)
- One file owns all private-symbol risk — easy to audit, easy to swap out per-symbol if a future macOS removes one

**Negative**:
- Mac App Store distribution is foreclosed (sandbox forbids the use of private symbols) — consistent with vision.md "What we explicitly do not build"
- Every major macOS release requires a manual confirmation that the three symbols still ship
- Notarisation may flag in the future (Apple's posture on private CG symbols has been tolerant for decades; not guaranteed forever)

## Revisit Trigger

- Apple ships a public Space-management API in a future macOS — switch to public API, deprecate `PrivateCGS.swift`
- Apple removes one of the three symbols — apply the fallback per the table above and ship a release
- Notarisation begins rejecting the binary because of the private symbols — open a follow-up ADR with mitigation options
