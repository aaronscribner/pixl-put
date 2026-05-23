# Research: Core Window Memory

**Feature**: 001-core-window-memory | **Date**: 2026-05-23 |
**Spec**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md)

This document records the design decisions behind plan.md, with alternatives
considered and the reason each was rejected. Every decision below traces
back to a constitution principle or a spec requirement.

## R-1 — Window manipulation API: Accessibility (AX), not CG/SkyLight

### Decision

Use the Accessibility API (`AXUIElementCreateApplication`,
`AXUIElementCopyAttributeValue`, `AXUIElementSetAttributeValue`) as the
exclusive mechanism for *moving* and *resizing* windows. CoreGraphics window
list APIs are used only for *enumerating* windows and reading display
metadata. Private SkyLight (`SLS*`) symbols are not used for window
manipulation.

### Alternatives considered

| API surface | Why rejected for window moves |
|-------------|-------------------------------|
| `CGSMoveWindow` / `SLSMoveWindow` (private) | Bypasses the app's window management, leaving the app's own state out of sync. Many apps respond by snapping back. Stage Manager and full-screen interactions fight back hardest. Also: pure private API, no notarization-safe documented behavior. |
| `CGWindow*` (public CG) | Read-only for window geometry. There is no public CG call that moves a window. |
| Apple Events `set bounds of window` per-app | Requires Automation permission for every supported bundle, including apps the AX path handles for free. Higher permission friction for no correctness gain. |
| `NSWindow` (Cocoa) | Only works on windows owned by our process. Not applicable cross-app. |

### Why AX wins

- It is the only Apple-sanctioned cross-app window-manipulation API.
- A single permission (Accessibility) covers every app the user has —
  no per-bundle prompts for the move itself.
- It cooperates with the target app's window manager, so apps that snap
  their windows (e.g. Xcode tabs in workspaces) stay coherent.
- AX events trigger the right notifications, so apps that observe their
  own window state (browsers tracking the active window) update normally.

### Known costs (planned around)

- **AX is synchronous and serializes badly under load.** Mitigation:
  every AX call goes through `Core/Accessibility/AXClient.swift`, which
  owns a dedicated serial `DispatchQueue` at QoS `.utility`. No AX call
  is ever made off that queue.
- **AX can deadlock if the target app is itself blocked in an AX call.**
  Mitigation: every AX call has a 250 ms timeout via
  `AXUIElementSetMessagingTimeout`; on timeout the window is skipped and
  logged, not retried in the same restore pass.
- **AX cannot move a window between Spaces.** Handled separately — see
  R-7 below.

### Traceability

Constitution §I (native macOS), §III (idempotent — AX guarantees we read
authoritative current frame before deciding to move), §V (single
permission for capture/restore).

## R-2 — Window enumeration: CG window list, filtered

### Decision

Enumerate candidate windows via `CGWindowListCopyWindowInfo(.optionAll,
kCGNullWindowID)` filtered to `kCGWindowLayer == 0` (normal-layer windows)
and `kCGWindowIsOnscreen == true`. For each surviving entry, pull the owning
PID, then walk AX from the application element down to the matching window
by `kAXWindowNumber`.

### Alternatives considered

- **AX-only enumeration** (walk `NSWorkspace.shared.runningApplications`
  and for each app read `kAXWindowsAttribute`). Slower (many round-trips)
  and includes off-screen / minimized windows we'd then have to filter.
- **Private `CGSCopyWindowsWithOptionsAndTags`**. Faster, but a private
  symbol; not justified for enumeration when public CG suffices. Saved
  for the cases where it's the only option (Space resolution, R-6).

### Why this hybrid wins

CG window list gives us a fast pre-filter (excludes status items, menubar
extras, the dock, transient panels) before we pay the AX cost. AX gives us
the moveable handle (`AXUIElement`) we need for read and write. We get the
best of both with one CG round-trip and one AX round-trip per window.

## R-3 — Browser deep identity via ScriptingBridge

### Decision

For Brave, Edge, Chrome, Arc, and Safari, the per-window identity is the
sorted set of tab URLs (origin + path, query stripped) currently open in
that window. Read via ScriptingBridge using each browser's published `.sdef`.

### Why tab URLs, not titles or active tab

- Titles rotate as the user switches tabs and as pages mutate the document
  title via JS. Useless as identity over a sleep cycle.
- Single active tab works most of the time but fails on the modal case for
  our user: identical YouTube tabs in two Brave windows are
  indistinguishable by active-tab.
- The *set* (not the sequence) of tab URLs is stable across sleep, browser
  restart, and tab reordering — exactly the durability we need.

### ScriptingBridge shape (Chromium-family example)

For Chromium browsers (Brave, Edge, Chrome) the relevant `.sdef` exposes:

```
application
  ├── windows: list of window
  │     ├── id (integer) — window id, NOT stable across restart
  │     ├── tabs: list of tab
  │     │     ├── url (text)
  │     │     ├── title (text)
  │     │     └── id (integer)
  │     ├── active tab (tab)
  │     └── mode (text) — "normal" | "incognito"
```

Provider workflow:

1. Get the AX window we're identifying. Read its `kAXWindowNumber` (CG
   window ID).
2. Look up the owning app via `NSRunningApplication`.
3. Open a ScriptingBridge connection to that bundle.
4. Enumerate `application.windows`. Match the SB window to the AX window
   by frame (origin + size) — this is the bridge between the two APIs.
5. For the matched SB window, read all `tabs[*].url`.
6. Normalize URLs: strip query, fragment, and trailing slash. Sort
   alphabetically. Hash with SHA-256, take 16 bytes.
7. Return `WindowIdentity.browserTabSet([URL])` carrying the normalized
   URL list. The hash is the matching key at restore; the URL list is
   stored for the snapshot diff viewer (v1.x).

### Safari specifics

Safari's `.sdef` differs slightly — `windows.current tab.URL` and
`windows.tabs.URL` — but the same workflow applies. Safari additionally
requires `com.apple.security.scripting-targets` entitlement values to be
declared even though we are not sandboxed; we include them anyway because
some macOS versions enforce them under TCC.

### Arc specifics

Arc's `.sdef` exposes `windows` and `tabs.url`, with Arc-specific concepts
(Spaces, Favorites) that we ignore — we only need tab URLs.

### Fallback when Automation is denied per-bundle

Per spec.md FR-014/015, we never proactively prompt for Automation. The
first time `BrowserTabSetProvider` runs for a bundle, TCC prompts. If the
user denies:

1. The SB call returns an error (typically `errAEEventNotPermitted`
   or `procNotFound`).
2. We catch, mark the bundle "Automation denied for session" in the
   in-memory provider registry, and never reprompt this session.
3. We fall through to `TitleRegexProvider` for that bundle.
4. If the title regex doesn't match a stable pattern we know about,
   `OrdinalProvider` is the final fallback (with a "best-effort" badge).

The user can re-grant Automation in System Settings → Privacy & Security →
Automation; we re-check at next app launch.

## R-4 — VS Code workspace extraction

### Decision

Two-layered, in order:

1. **Title regex.** VS Code (and VS Code Insiders) titles follow a
   stable format set in `window.title` (default
   `"${activeEditorShort}${separator}${rootName}"`). Even with custom
   templates, the workspace name almost always appears bracketed. The
   regex `(?:^|\s[-—] )([^\-—]+?)(?:\s[-—] (Visual Studio Code|Code|Cursor))?$`
   captures the rightmost workspace fragment reliably across the default
   and the top three custom templates we surveyed.
2. **`storage.json` cross-reference.** `~/Library/Application Support/
   Code/storage.json` contains
   `windowsState.openedWindows[*].folderUri` — the actual workspace URIs
   that VS Code knows about right now. If exactly one of those folderURIs
   has a basename matching the regex capture, we promote the identity to
   the full workspace path. Otherwise we keep the title-fragment match
   and tag the identity as `editorWorkspace(URL)` with a `confidence:
   .titleOnly` flag.

### Why not Automation?

VS Code's AppleScript dictionary is minimal — it exposes documents but not
workspaces in a structured way. ScriptingBridge would give us the active
editor's document path (which is sometimes the workspace, sometimes a file
inside it), not the workspace identity itself. The file-on-disk approach
is more reliable and requires no permission.

### VS Code Insiders

VS Code Insiders uses `~/Library/Application Support/Code - Insiders/
storage.json` with the same shape. The provider takes the bundle ID and
maps to the right Application Support directory.

## R-5 — JetBrains, Xcode, terminals

### JetBrains (IDEA, PyCharm, WebStorm, GoLand, RustRover)

Title format: `<ProjectName> [<Branch>] - <Filename> - <IDE>`. Project
name is between the start of the title and the first ` - ` or ` [`. Title
regex provider primary; cross-reference against
`~/Library/Application Support/JetBrains/<IDE>/options/recentProjects.xml`
for the full path. The XML lists every project the IDE has ever opened
with `<entry key="$USER_HOME$/path">` — match the basename.

### Xcode

Xcode's `.sdef` is rich. ScriptingBridge gives us
`application.workspaceDocuments[*].file` directly. Match the SB workspace
to the AX window by frame, same trick as browsers. No fallback needed —
Xcode's AppleScript support has been stable since the 4.x days. If
Automation is denied, fall through to title regex on
`<project-name> — Edited` patterns.

### Terminals (iTerm2, Apple Terminal, Ghostty, Warp)

| Bundle | Strategy |
|--------|----------|
| iTerm2 | ScriptingBridge: `application.windows[*].currentSession.tty` gives the TTY device; `currentSession.variables["session.path"]` gives the CWD when iTerm2's shell integration is installed. Without integration, fall back to title regex. |
| Apple Terminal | ScriptingBridge: `windows[*].selected tab.title` typically ends with `"— <user>@<host>: <cwd>"`. Read from the SB object directly (more stable than parsing the AX title). |
| Ghostty | Title-based. Ghostty's window titles default to `cwd <session-id>` and are configurable via OSC sequences. Capture the OSC-set title if present; fall back to ordinal. Ghostty has no .sdef as of late 2025. |
| Warp | Title regex on `<cwd> — Warp` and similar. Warp has no public AppleScript surface. |

Terminal identity yields `WindowIdentity.terminalCWD(URL)`. CWD is a
sufficiently strong signal that two terminals with the same CWD collapse
to ordinal — accepted edge case.

## R-6 — Space identification via private CGS

### Decision

Use `CGSCopyManagedDisplaySpaces` and `CGSGetActiveSpace` (private,
weak-linked) to determine which Space each window is on at capture time
and to verify the target Space at restore time. Both symbols are isolated
in [`Core/Spaces/PrivateCGS.swift`](../../) per constitution §VI.

### Symbol signatures

```c
extern CFArrayRef CGSCopyManagedDisplaySpaces(int cid);
extern int CGSMainConnectionID(void);
extern uint64_t CGSGetActiveSpace(int cid);
```

Declared in Swift as:

```swift
@_silgen_name("CGSCopyManagedDisplaySpaces")
private func _CGSCopyManagedDisplaySpaces(_ cid: Int32) -> Unmanaged<CFArray>?

@_silgen_name("CGSMainConnectionID")
private func _CGSMainConnectionID() -> Int32

@_silgen_name("CGSGetActiveSpace")
private func _CGSGetActiveSpace(_ cid: Int32) -> UInt64
```

`CGSCopyManagedDisplaySpaces` returns an array of dictionaries, one per
display, each with:

- `Display Identifier`: `CFString`, e.g. `"37D8832A-2D66-02CA-B9F7-..."`
  — the CGDirectDisplayID's UUID.
- `Spaces`: `CFArray` of per-Space dictionaries:
  - `id64`: `CFNumber` — the 64-bit Space ID we match against
    `CGSGetActiveSpace`.
  - `type`: `CFNumber` — 0 = user, 1 = fullscreen, 2 = system.
  - `uuid`: `CFString` — Space's persistent UUID.

To map a CG window to its Space, we use `CGSCopySpacesForWindows(cid,
mask, windows)` (also private, also isolated in PrivateCGS.swift):

```swift
@_silgen_name("CGSCopySpacesForWindows")
private func _CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32,
                                       _ windows: CFArray) -> Unmanaged<CFArray>?
```

Mask `0x7` returns all Spaces a window appears on (a window can be
present on multiple Spaces if it's been assigned "All Desktops").

### Graceful degradation if the symbol is removed

`PrivateCGS.swift` loads each symbol via `dlsym(RTLD_DEFAULT, ...)` rather
than direct linkage. If any symbol returns `nil`:

1. `SpaceResolver` returns `Space.unknown` for that query.
2. `Snapshot` records `space: nil` for affected windows.
3. `Restorer` does not attempt to switch Spaces for windows where
   `space == nil`; it places the window on the active Space of the
   recorded display.
4. The menu bar surfaces a one-time banner: "Space restore unavailable
   on this macOS version. Window positions still restore correctly."

This satisfies constitution §VI's "fallback path if the symbol is removed
in a future macOS release."

## R-7 — Moving a window onto a specific Space

This is the trickiest restore operation and warrants its own section.

### The constraint

AX cannot move a window between Spaces. CG cannot either. The only public
mechanism is via `NSWindow.collectionBehavior`, which only works on our
own windows. Apple does not provide a cross-app "move this window to
Space N" call.

### Decision

Use the **switch-then-move** technique:

1. Read the target Space ID for the window from the snapshot.
2. If `CGSGetActiveSpace(cid) == targetSpaceID`, skip to step 5 (already
   on the right Space).
3. Switch to the target Space programmatically by synthesizing the
   user's "switch to Space N" keyboard shortcut via `CGEventCreateKeyboardEvent`.
   Ctrl+Arrow is the default and is what we send; if the user has
   remapped, we surface a Settings option to override the key chord.
4. Wait for `CGSGetActiveSpace` to reflect the new Space (poll at 10 ms
   intervals, give up at 500 ms — give-up logs and proceeds anyway).
5. Move the window with AX `kAXPositionAttribute` and `kAXSizeAttribute`.
6. Once all moves on the current Space are done, switch back to the
   originally-active Space (the Space the user was on before we started
   restoring).

### Why not `CGSMoveWindowsToManagedSpace`?

That private symbol exists and does what we want directly. We rejected it
because (a) it has a stronger "you're probably going to be removed in the
next OS" smell than `CGSCopyManagedDisplaySpaces` does — Apple has been
pruning write-side SLS/CGS symbols faster than read-side ones since
macOS 13; and (b) the synthesized-key approach is what every other window
manager on macOS uses, so it stays working as long as keyboard Space
switching does.

### Alternatives considered

- **Use the Mission Control hotkey + scripted clicks.** Brittle, requires
  Mission Control to be enabled, visually disruptive. Rejected.
- **Skip Space restoration entirely.** Acceptable as a fallback (see R-6
  graceful degradation), but the user's stated workflow includes
  Spaces-per-task. Mid-tier fallback only.

### Restore ordering

The restorer groups window moves by `(display, space)`. It processes one
Space at a time, switching once per Space rather than per window, then
moves to the next Space. Total Space switches in a restore pass = number
of distinct Spaces in the snapshot, not number of windows.

## R-8 — Display fingerprinting

### Decision

A display's fingerprint is `SHA-256(vendor_id || product_id || model_id ||
serial_number_low_24_bits)[0..16]`, hex-encoded, with values read via
`CGDisplayVendorNumber`, `CGDisplayModelNumber`, and
`CGDisplaySerialNumber`. The display's CG `displayUUID` (via
`CGDisplayCreateUUIDFromDisplayID`) is captured separately as a secondary
identifier for diagnostic logging but is *not* part of the fingerprint —
the CG UUID changes across some macOS upgrades for the same physical
display, which would silently invalidate snapshots.

A `displayConfigurationID` is `SHA-256(sorted_display_fingerprints
joined by '|')[0..16]`. Sorting by fingerprint (not by port index or CG
display ID) makes the configuration ID port-order-independent: plugging
two monitors into either of two ports yields the same configuration ID.

### Alternatives considered

- **`displayUUID` only.** Simpler. Rejected because the UUID is not stable
  across all OS upgrades.
- **Include `CGDisplayPixelsWide/High` in the fingerprint.** Rejected
  because resolution can change via Settings → Displays without the
  user wanting a new configuration.
- **EDID parsing via IOKit.** A `IODisplayConnect` walk yields more
  detail (manufacturer name string, week+year of manufacture). Rejected
  as overkill — vendor + product + serial is already 64 bits of entropy.

### The built-in display

The built-in display reports vendor `0x610` (Apple) and a model number
that varies by Mac model. Serial is typically `0`. The fingerprint is
therefore stable per Mac model but identical across two M3 MacBook Airs.
This is fine — snapshots are per-machine (under that user's Application
Support), so cross-machine collisions don't matter.

## R-9 — Debouncing wake-storm events

### Problem

When a Mac wakes from sleep with displays attached, the following events
typically fire within a 1–2 second window in nondeterministic order:

- `CGDisplayRegisterReconfigurationCallback` fires once per display, often
  with `.beginConfigurationFlag` and `.endFlag` pairs interleaved.
- `NSWorkspace.didWakeNotification` fires once.
- `NSWorkspace.screensDidWakeNotification` fires once.
- A second `CGDisplayRegister...` storm may fire 200–400 ms later as
  external displays finish negotiating EDID.

If we trigger a restore on each, we restore 3–8 times. Each restore
involves AX moves that the user perceives as window jitter.

### Decision

A `Debouncer<Trigger>` (in [`Core/Triggers/Debouncer.swift`](../../))
implementing a **trailing debounce with a max-wait cap**:

- On each incoming trigger, reset a timer for `quietWindow = 1500 ms`.
- If the timer fires (1.5 s of quiet), emit one event and reset.
- If `maxWait = 5000 ms` elapses since the *first* trigger in the burst
  without quiet being reached, force-emit and reset.

Captured here per spec.md FR-007 (5-second capture debounce) and FR-008
(5-second restore debounce), with the trailing/quiet behavior added for
correctness — FR-007/008 only require "at most one per 5s," which the
debouncer satisfies.

### Specific decisions

- **Trailing, not leading.** A leading-edge restore would fire on the
  first event of a wake storm, before all displays have re-negotiated,
  which produces a "displaced" restore that has to be re-run anyway.
  Wait for quiet.
- **Per-trigger-kind queues.** Capture and restore have separate
  debouncers. A wake event must not silence a screen-saver capture event
  that fires later.
- **No coalescing across configurations.** If the display configuration
  changes mid-debounce, the pending event is cancelled and the new event
  starts a fresh debounce window keyed to the new configuration ID.

### Why not edge-detect on `kCGDisplayBeginConfigurationFlag` /
`kCGDisplayEndFlag` pairs?

We tried this on paper and it would work for the CG-only storm, but it
doesn't cover the interleaving with NSWorkspace wake notifications, which
do not participate in the begin/end protocol. The unified debouncer is
simpler and provably correct: at most one restore per 5 s, period.

## R-10 — Capture-time AX queue discipline

A separate but related concurrency decision: every AX read or write
happens on a single dedicated serial `DispatchQueue` at QoS `.utility`,
owned by `Core/Accessibility/AXClient.swift`. The capture orchestrator
fans out window enumeration via CG (parallel-safe), but the AX
attribute-reads for each window are serialized.

### Why serial?

AX deadlocks more easily under parallel access from the same process.
Several Apple Forums threads (FB7942111 and similar) describe deadlocks
when two AX calls into the same target app overlap. The serial queue is
boring and correct.

### Why .utility?

`.utility` is the right QoS for "user is not waiting." Capture runs after
the user has gone idle; restore runs before the user has noticed the
machine is back. Neither is `.userInteractive`. The menu-bar status
updates (which the user *might* be watching) run on the main queue at
the default QoS.

## R-11 — JSON-via-Codable persistence shape

The plan calls for JSON via Codable under Application Support. Two
sub-decisions:

### Pretty-printed vs. compact

Pretty-printed (`outputFormatting = [.prettyPrinted, .sortedKeys]`). Spec
files are user-inspectable and likely to be diffed by users who want to
understand what's stored. The size cost is negligible (~30% over compact
on snapshot files of a few hundred KB).

### Single file per configuration vs. per snapshot

Single file per `displayConfigurationID`, containing the full history
(default: 10 entries). Justifications:

- Atomic snapshot rotation is easier (write-temp-rename one file vs.
  manage a directory).
- Fewer file handles, fewer Spotlight scans.
- Snapshot diff viewer (v1.x) gets all history in one read.

The history is a bounded ring buffer; on the 11th snapshot the oldest
is dropped before write.

## Open questions

None — every spec.md item has a corresponding decision above. If a
question surfaces during implementation that requires a new principle or
contradicts one above, this file is updated in the same PR.
