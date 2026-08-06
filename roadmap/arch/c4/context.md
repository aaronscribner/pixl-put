# C4 Level 1 — System Context

**Status**: Stub (created by architect agent, spec-phase, feature 001-core-window-memory)

## Purpose

DisplayMaid-Next (the PixPut binary) is a single-binary macOS menu bar utility that captures and restores window arrangements across machine sleep/wake and display reconfiguration cycles. This document records the system's external boundary: who interacts with it and which external systems it depends on.

## Actors

| Actor | Interaction |
|---|---|
| End user | Grants permissions; views menu bar status; invokes manual capture / restore; configures preferences |
| macOS (system) | Delivers idle / wake / display-reconfiguration events via `NSWorkspace`, distributed notifications, `CGDisplayRegisterReconfigurationCallback`; owns the windows DisplayMaid-Next observes via the Accessibility API |
| Per-app bundles (Brave / Edge / Chrome / Arc / Safari / VS Code / Xcode / iTerm2 / Terminal / Ghostty / Warp) | Provide deep-identity signals (tab URL sets, workspace paths, terminal CWDs) via ScriptingBridge / AppleScript when the user has granted Automation permission per-bundle |

## External Systems

| System | Direction | Protocol | Notes |
|---|---|---|---|
| Sparkle appcast server (developer-controlled) | Outbound HTTPS GET (read-only) | HTTPS + Sparkle 2.x EdDSA signature verification | The **only** allowed off-device network call per project constitution §IV |
| Apple notarisation service | Build-time only | n/a (developer toolchain) | Not invoked from the running app — only by CI / release process |

## Out of Scope

- iCloud, any cloud sync service
- Telemetry, analytics, crash-reporter backends
- Mac App Store (sandboxed distribution incompatible with the AX-driven workflow)
- MDM-managed environments (v1 assumption)

## Boundaries

DisplayMaid-Next does NOT modify:

- Application content (browser tabs, editor documents)
- Application state beyond window position / size / fullscreen / minimized state
- User preferences belonging to other apps
- System preferences

## Open Questions

- Sidecar / AirPlay / Continuity displays — behaviour acceptable for v1 per spec assumption; revisit if user reports surface specific quirks.
- Fast-User-Switching — out of scope for v1 per spec assumption; revisit if requested.

## References

- Project constitution: [`../../../product/constitution.md`](../../../product/constitution.md)
- Vision: [`../../../product/vision.md`](../../../product/vision.md)
- First feature spec: [`../../../product/001-core-window-memory/spec.md`](../../../product/001-core-window-memory/spec.md)
