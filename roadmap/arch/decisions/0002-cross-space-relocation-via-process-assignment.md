# ADR-0002 — Cross-Space window relocation via `CGSProcessAssignToSpace`

**Status**: Accepted | **Date**: 2026-08-02 | **Supersedes**: research.md R-7 | **Relates to**: [ADR-0001](0001-private-cgs-for-spaces.md)

## Context

`56f4b1f` removed "Restore Spaces", citing that Space relocation "via private CGS is unreliable". Measured on macOS 26.2 (build 25C56) with [scripts/probe-spaces.swift](../../../scripts/probe-spaces.swift). Every write is verified by re-read, since all these calls return `void`.

## Findings

**1. The obvious calls are gated on window ownership.** `CGSMoveWindowsToManagedSpace`, `CGSAddWindowsToSpaces`, and `SLSSpaceAddWindowsAndRemoveFromSpaces` affect only windows belonging to the caller's own CGS connection:

| Window | Result |
|---|---|
| Owned by the probe process | **landed in 2–4 ms** |
| Owned by another app | **refused** — 0/6 across all user Spaces |

This is the wall yabai hits, and why it injects a scripting addition into `Dock.app` — to run the call from the connection that owns every window. **SIP has no bearing on this**; disabling it changed nothing.

**2. `CGSProcessAssignToSpace(cid, pid, spaceID)` relocates foreign windows.** No injection, no root, no SIP requirement. Verified moving TextEdit's windows 3→7 and 7→3 from an ordinary user process. This is the load-bearing discovery: the widespread belief that Dock injection is the only route is wrong.

Its semantics are narrower than a per-window move:

- **Process-scoped** — every window of that pid moves together. Two windows of one app cannot be placed on different Spaces.
- **Sticky for the process lifetime** — windows opened afterwards also land on the assigned Space. Behaviourally this is Dock → Options → "Assign To → This Desktop".
- **Clears when the app quits.** It is pid state, not persisted preferences. `space 0` does not clear it, and no unassign symbol exists (`CGSProcessAssignToAllSpaces`, i.e. "All Desktops", is the only sibling).

**3. Space switching works cleanly.** `CGSManagedDisplaySetCurrentSpace` verified at 52–72 ms.

## Decision

**Restore Spaces is viable and returns to scope**, built on `CGSProcessAssignToSpace`, grouped by pid.

This reverses the reasoning in `56f4b1f`. That commit was right that per-window relocation is unusable; it was wrong that no route exists.

The sticky, process-wide side effect is acceptable for this project's distribution model — personal use plus open source — where the tradeoff is the owner's to make. (The commercial framing that made this tradeoff unacceptable was abandoned in [ADR-0003](0003-single-hardware-target-and-oss.md).)

## Consequences

- Restore groups snapshot windows by pid. When one app's windows target a single Space, restore is exact.
- When an app's windows span multiple Spaces, the technique **cannot** satisfy all of them. Restore picks the majority target (earliest-created window breaks ties) and logs a partial restore.
- **Measured against the real snapshot on 2026-08-04: `totalSatisfied=29`, `totalDisplaced=38`.** On an accumulated multi-Space snapshot the per-app backend misplaces more windows than it places. Seven of twelve apps could not be fully restored — VSCode's windows spanned five Spaces, Brave's four. This is the technique working as designed against an input it cannot express, not a defect, but it means the per-app path must not be a one-click unconfirmed action. `com.apple.notificationcenterui` alone contributed 12 displaced windows and should never have been captured.
- Restoring pins each touched app to its target Space until that app quits. Newly opened windows follow. This must be stated in the UI, not buried.
- research.md R-7 step 3 should use `CGSManagedDisplaySetCurrentSpace` rather than synthesised Ctrl+Arrow keystrokes, which depend on a shortcut the user can remap or disable.

## Not yet verified

- Whether a manual drag of a window to another Space survives, or gets pulled back by the standing assignment.
- SIP-enabled control run. The ownership split is not a SIP-governed mechanism so results should be identical, but the control has not been executed. Re-run `probe-spaces.swift --ownership <foreignWindowID>` after re-enabling SIP.

## Revisit Trigger

- Apple ships a public cross-Space window API, or removes `CGSProcessAssignToSpace`.
- The project adopts a distribution model where a sticky process-wide assignment is not acceptable.
