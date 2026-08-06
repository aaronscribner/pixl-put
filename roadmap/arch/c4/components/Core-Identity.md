# Component: Core/Identity

**Status**: Stub | **Layer**: Core | **Primary extension point**

## Purpose

Resolve a stable `WindowIdentity` for every captured window using the layered strategy mandated by project constitution §II. This is the **primary extension point** of the codebase: new per-app deep identity is a new `WindowIdentityProvider` file under `AppProviders/`, never a relaxation of the layered order.

## Layered Resolution Order

| Layer | Provider | Identity variant |
|---|---|---|
| 1 | `DocumentPathProvider` | `documentPath(URL)` — `kAXDocumentAttribute` from the AX window |
| 2 | `AppProviders/*` (per bundle ID) | `browserTabSet([URL])`, `editorWorkspace(URL)`, `terminalCWD(URL)` |
| 3 | `TitleRegexProvider` | `titleRegex(pattern, capturedValue)` — per-bundle regex |
| 4 | `OrdinalProvider` | `ordinal(index)` — N-th window of bundle X by creation time |

## Responsibilities

- `WindowIdentityResolver.resolve(axWindow)` — try providers in order, return first non-empty result
- `WindowIdentity` — tagged union (`Codable`) of identity variants
- Per-bundle `WindowIdentityProvider` files for browsers (Brave, Edge, Chrome, Arc, Safari), editors (VS Code, Xcode, JetBrains), terminals (iTerm2, Terminal, Ghostty, Warp)

## Boundaries

- Reads AX state via `AXClient` (no direct AX calls)
- Reads bundle Automation permission state via `App/PermissionsBootstrap` (does NOT prompt; never re-prompts within session per FR-015)
- ScriptingBridge / NSAppleScript calls confined to `AppProviders/*` — wrapped per provider; failures localised
- Provider failures are isolated — one bundle's failure must not block another bundle's identity resolution

## Dependencies

- `Core/Accessibility/AXClient` (AX attribute reads)
- `App/PermissionsBootstrap` (Automation grant state)
- `Infra/Logging` (provider failures, fallbacks)

## Files (per plan.md)

- `Core/Identity/WindowIdentity.swift` — tagged-union model
- `Core/Identity/WindowIdentityResolver.swift` — tries providers in order
- `Core/Identity/DocumentPathProvider.swift`
- `Core/Identity/TitleRegexProvider.swift`
- `Core/Identity/OrdinalProvider.swift`
- `Core/Identity/AppProviders/BrowserTabSetProvider.swift`
- `Core/Identity/AppProviders/VSCodeWorkspaceProvider.swift`
- `Core/Identity/AppProviders/XcodeProvider.swift`
- `Core/Identity/AppProviders/TerminalCWDProvider.swift`

## Constitution Alignment

- §II Layered identity — layered order is the load-bearing principle; resolver must enforce it
- §V Graceful degradation — Automation denial falls to next layer (FR-015)

## Open Questions

- ScriptingBridge sdef paths: bundle into the app vs reference upstream — pending build-system design.
- Caching: identity resolution per (axWindow, frame-state) for capture loop perf — defer until perf budget pressure surfaces.
