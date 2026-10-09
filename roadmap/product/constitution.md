# DisplayMaid-Next Constitution

These are the load-bearing principles for the project. Any feature spec, plan,
or pull request that conflicts with one of these MUST either be revised, or
must justify the deviation in the plan's Complexity Tracking section.

## Core Principles

### I. Native macOS, no compromises

The product is a macOS-only utility. The implementation is Swift + AppKit +
SwiftUI (for Settings/onboarding only). No Electron, no Catalyst, no
cross-platform abstractions, no JavaScript runtime. We bind directly to the
Accessibility API, CoreGraphics, IOKit, and `NSWorkspace`.

### II. Window identity is layered, never title-only

A window's "identity" for the purpose of save/restore is resolved by a layered
strategy, strongest signal first:

1. Document path (`kAXDocumentAttribute` on the AX window).
2. App-specific deep identity — browser tab URL set (Brave, Edge, Chrome,
   Arc, Safari), editor workspace path (VS Code, Xcode, JetBrains), terminal
   working directory (iTerm2, Terminal, Ghostty, Warp).
3. Stable title-derived fingerprint (regex per-bundle-ID, e.g. extract
   workspace name from VS Code titles).
4. Ordinal fallback ("N-th window of bundle X by creation time").

A new layer is added by adding a new `WindowIdentityProvider` — never by
loosening the layer above it. Title-only identity is forbidden as a primary
strategy because titles drift constantly.

### III. Idempotent operations

`capture()` called twice in a row produces identical state. `restore(snapshot)`
called twice in a row produces identical window positions. Restoration never
moves a window that is already at its target frame within 1px tolerance.

### IV. Local-only data, forever

Snapshots, including any browser tab URLs and document paths read for window
identity, are stored exclusively under `~/Library/Application Support/` on the
user's machine. No telemetry. No analytics. No cloud sync (a future export
feature, if any, is user-initiated and writes a file the user controls).
Crash reports are local files the user can choose to attach to a bug report.

**Allowed off-device endpoint** (exhaustive list — any new endpoint requires
amending this principle):

1. **Sparkle appcast** at `https://updates.pixput.app/appcast.xml` — fetched
   on a schedule to check for new releases. Sends only `User-Agent`. No
   identifying data.

Any other off-device call is a violation — including ostensibly innocuous
ones (font CDNs, analytics, error reporting, "phone home for available
features"). If a feature genuinely requires a new endpoint, add it here
with the same rigour: exact URL, exact payload, exact justification.

### V. Graceful permission degradation

The app does the best it can with whatever permissions the user has granted:

- **No Accessibility**: app shows onboarding, no capture/restore.
- **Accessibility only**: capture/restore works for all apps using AX + ordinal
  identity. Multiple-window disambiguation is best-effort.
- **Accessibility + Automation per-app**: per-app deep identity providers
  activate for the apps the user has granted. Each app failure is isolated.

Permission prompts are explained in-context, never silently triggered.

### VI. Direct distribution, private API allowed when justified

The app is distributed as a notarized, Developer-ID-signed `.app` with Sparkle
auto-update. We are not Mac App Store bound, so private CoreGraphics
(`CGSCopyManagedDisplaySpaces`, `CGSCopyWindowsWithOptionsAndTags`) is used
where it materially improves user experience — specifically for resolving
which Space a window is on. Every private symbol is wrapped in a single file
(`PrivateCGS.swift`) with a fallback path if the symbol is removed in a
future macOS release.

### VII. Performance is a feature, not an afterthought

- Snapshot capture: ≤ 500 ms wall clock for 100 windows on Apple Silicon.
- Restore: ≤ 2 s wall clock for 50 windows.
- Idle CPU when no display/wake events: ≤ 0.1% average over 5 minutes.
- Resident memory: ≤ 30 MB at steady state.

A change that regresses any of these by >20% requires a Complexity Tracking
entry. Background work runs at QoS `.utility` or lower; foreground UI runs at
`.userInteractive`.

## Governance

This constitution overrides any conflicting guidance in feature specs or
plans. To change a principle, open a PR that updates this file with a
**Changelog** entry and bump the version below.

A principle CAN be deviated from in a single feature when the feature plan's
Complexity Tracking table documents:

1. Which principle is being deviated from.
2. Why the simpler/principled path was rejected.
3. A specific revisit trigger (e.g. "revisit if X happens").

**Version**: 1.2.0 | **Ratified**: 2026-05-23 | **Last Amended**: 2026-10-08

## Changelog

- **1.2.0** (2026-10-08): §IV — removed the license API endpoint. The
  project is open source and has no licensing; the Sparkle appcast is the
  only permitted external endpoint.
- **1.1.0** (2026-05-30): §IV — added exhaustive "Allowed off-device endpoints"
  list. Sparkle appcast and license API (`api.pixput.app`) are the only
  permitted external endpoints; new ones require an amendment.
