# Feature Specification: Core Window Memory

**Feature Branch**: `001-core-window-memory`

**Created**: 2026-05-23

**Status**: Draft

**Input**: User description: "Better DisplayMaid — auto-save when screensaver
activates, auto-restore on wake, remember the position of each individual
window across multiple instances of the same app (Brave, Edge, VS Code).
macOS 14+, Swift, direct distribution."

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Windows return to their places on wake (Priority: P1)

After the Mac wakes from sleep, every window that was open before sleep is
returned to the display, Space, and frame it occupied at the moment the
machine went idle — without the user touching anything.

**Why this priority**: This is the entire reason the product exists. Every
other story is in service of this one.

**Independent Test**: Capture a snapshot manually (via menu bar), drag three
windows of different apps to new positions, then run "Restore" from the menu
bar. All three windows must return to their captured frames within the
performance budget (≤ 2 s for ≤ 50 windows). No sleep cycle required for the
test.

**Acceptance Scenarios**:

1. **Given** a snapshot exists for the current display configuration with N
   windows at known frames, **When** the user invokes Restore, **Then** every
   window listed in the snapshot is moved to its recorded frame (within 1 px
   tolerance) on its recorded display and Space.
2. **Given** the Mac sleeps with displays attached and wakes with the same
   display configuration, **When** the wake event fires, **Then** the most
   recent snapshot for that display configuration is restored automatically
   within 2 s of the system being interactive.
3. **Given** a window from the snapshot no longer exists at restore time,
   **When** restore runs, **Then** the missing window is skipped, the
   remaining windows are restored, and the event is logged locally.
4. **Given** a snapshot entry recorded `isFullscreen = true` for a window
   on a specific display, **When** restore runs and the target display is
   present in the active configuration, **Then** the corresponding window
   re-enters fullscreen on the recorded display (entering fullscreen if
   not already there) within the per-window budget; if the target display
   is absent, the window is moved to the primary display in windowed mode
   and tagged "displaced" per FR-011.

---

### User Story 2 — Arrangement is captured automatically when idle (Priority: P1)

When the screen saver activates or the display sleeps, the current window
arrangement is captured to disk, keyed to the current display configuration,
so that wake-restore has something to restore.

**Why this priority**: Story 1 has no value without Story 2 — restore needs a
recent snapshot. They ship together.

**Independent Test**: Trigger the screen saver via `pmset displaysleepnow` or
hot corner. Within 2 seconds, a new snapshot file must appear under
`~/Library/Application Support/DisplayMaid-Next/snapshots/` with the current
display configuration ID and a timestamp ≥ the trigger time.

**Acceptance Scenarios**:

1. **Given** the user is actively using the Mac, **When** the screen saver
   activates, **Then** a snapshot of the current arrangement is written to
   disk within 2 s and tagged with the current display configuration ID.
2. **Given** a snapshot is in progress and a second idle event fires,
   **When** the capture is still running, **Then** the second event is
   coalesced — at most one capture runs at a time per display configuration.
3. **Given** the user explicitly toggles "Pause Auto-Capture" from the menu
   bar, **When** the screen saver activates, **Then** no snapshot is written
   and the menu bar item shows a paused indicator.

---

### User Story 3 — Multiple windows of the same app return correctly (Priority: P1)

When the user has multiple windows of the same app open (e.g. four Brave
windows, three VS Code workspaces, two Edge profiles), each individual window
is restored to its own captured position — windows are never swapped or
collapsed onto one another.

**Why this priority**: The user explicitly called this out as the failure
mode of every existing tool. Without this, the product offers no improvement
over DisplayMaid for the user's workflow.

**Independent Test**: Open four Brave windows, each loading a distinct set of
tabs (different first URL). Move each to a distinct frame. Capture. Move all
four windows to overlapping positions. Restore. Each window must return to
the frame that matches its original tab set, not its launch order.

**Acceptance Scenarios**:

1. **Given** four Brave windows with distinct tab URL sets at distinct
   frames, **When** capture runs and then restore runs, **Then** each window
   returns to the frame whose snapshot entry matches its current tab set.
2. **Given** three VS Code windows each with a different workspace folder
   open, **When** capture runs and the user closes and reopens VS Code with
   the same three workspaces, **Then** each restored window is matched to
   its snapshot entry by workspace path and moved to the recorded frame.
3. **Given** two windows of the same app whose deep identity cannot be
   resolved (e.g. both untitled, no document path), **When** restore runs,
   **Then** windows are matched by ordinal fallback (creation order) and a
   warning surfaces in the menu bar's "Last Restore" status.

---

### User Story 4 — Snapshots are partitioned by display configuration (Priority: P2)

The user who detaches their laptop from a docking station, works on the
go, then reconnects later finds the desk arrangement intact — and vice
versa.

**Why this priority**: Without this, every dock/undock corrupts the most
useful snapshot. High value, but the P1 stories deliver MVP value on a
single-display setup.

**Independent Test**: With external display attached, capture snapshot A.
Detach external display, rearrange, capture snapshot B. Reattach external
display. Restore must apply A, not B. Detach again. Restore must apply B.

**Acceptance Scenarios**:

1. **Given** a snapshot exists for display configuration X and another for
   configuration Y, **When** the system is in configuration X, **Then**
   only the X snapshot is offered/applied for auto-restore.
2. **Given** a new display configuration is detected with no prior
   snapshot, **When** the user enters that configuration, **Then** no
   automatic restore happens, and the menu bar offers "Capture initial
   snapshot for this configuration".
3. **Given** a display is swapped for a different one (same port, different
   monitor), **When** the system identifies the configuration, **Then** the
   new configuration ID differs from the old one and a separate snapshot is
   maintained.

---

### User Story 5 — Manual save, restore, and named snapshots (Priority: P3)

The user can capture or restore from the menu bar at any time, name a
captured snapshot ("morning setup", "video call"), and switch between named
snapshots manually.

**Why this priority**: A power-user feature. The auto behavior covers 90% of
value. Named snapshots add scenarios but are not essential.

**Independent Test**: Capture a snapshot, name it "A". Rearrange. Capture
"B". Switch to "A" from menu bar. Switch to "B". Both restorations must
match their original arrangements.

**Acceptance Scenarios**:

1. **Given** a captured arrangement, **When** the user names it from the
   menu bar, **Then** it is persisted and shown in the snapshot list under
   that name.
2. **Given** a named snapshot exists for a display configuration that
   differs from the current one, **When** the user invokes restore for that
   snapshot, **Then** the user is warned and asked to confirm.

---

### Edge Cases

- **Window minimized at capture**: record `isMinimized = true`. Restore
  un-minimizes only if `restoreMinimized` preference is on (default off).
- **Window full-screen at capture**: record `isFullscreen = true` and its
  Space. Restore re-enters full-screen on the recorded display.
- **App not running at restore**: skipped. Logged. Optional preference
  "Relaunch missing apps" (default off, off-by-default for v1).
- **Window opened on a display that no longer exists**: re-place on the
  primary display of the active configuration with a "displaced" flag, near
  the original normalized coordinates.
- **Same bundle ID, multiple windows, all sharing one ambiguous identity
  signal**: ordinal match. Surface a "best-effort" badge in menu bar.
- **User drags a window during restore**: cancel restore for that single
  window; complete others. Never fight the user.
- **Display sleep without screen saver**: treated equivalently to screen
  saver activation for capture purposes (both are "going idle" signals).
- **Repeated wake within 5 s**: debounce. Only one restore per wake.
- **Accessibility permission revoked at runtime**: pause capture/restore,
  surface a banner, offer one-click jump to System Settings.
- **Browser running in a profile we cannot script** (e.g. user denied
  Automation for that bundle): fall back to title fingerprint, then ordinal.
- **Display configuration changes during capture**: abort current capture,
  start a new one keyed to the new configuration.

## Requirements *(mandatory)*

### Functional Requirements

**Identity and snapshots**

- **FR-001**: System MUST compute a stable `displayConfigurationID` from the
  set of currently connected displays using a fingerprint that includes
  vendor ID, product ID, and a hash of the display's CoreGraphics
  `displayUUID`, independent of port ordering.
- **FR-002**: System MUST resolve a `WindowIdentity` for every captured
  window by trying the following providers in order, stopping at the first
  that returns a non-empty identity: document-path, app-specific
  deep-identity (per bundle ID), title-regex fingerprint, ordinal.
- **FR-003**: System MUST persist snapshots as one JSON file per display
  configuration under `~/Library/Application Support/DisplayMaid-Next/
  snapshots/<displayConfigurationID>.json`, with at most N=10 historical
  versions per config retained (configurable).
- **FR-004**: System MUST capture, for each window: bundle ID, identity
  variant + value, frame (origin + size in global coordinates), display
  fingerprint, Space index on that display, `isMinimized`, `isFullscreen`,
  capture timestamp.

**Triggers**

- **FR-005**: System MUST listen for the `com.apple.screensaver.didstart`
  and `com.apple.screenIsLocked` distributed notifications and for
  `NSWorkspace.screensDidSleepNotification`, treating any of these as an
  idle event that triggers capture.
- **FR-006**: System MUST listen for `NSWorkspace.didWakeNotification` and
  `CGDisplayRegisterReconfigurationCallback` events, treating either as a
  resume event that triggers auto-restore for the active configuration.
- **FR-007**: System MUST debounce capture events such that no more than
  one capture runs per 5-second window per display configuration.
- **FR-008**: System MUST debounce wake/restore events such that no more
  than one restore runs per 5-second window.

**Restore behavior**

- **FR-009**: System MUST move each restorable window to its recorded frame
  using AX `kAXPositionAttribute` and `kAXSizeAttribute`, on its recorded
  Space, atomically per-window (no partial frame moves).
- **FR-010**: System MUST NOT move a window already at its recorded frame
  within 1 px tolerance.
- **FR-011**: System MUST skip and log any window whose target display
  fingerprint is no longer present in the active configuration, surfacing a
  user-visible "X windows displaced" count in the menu bar.
- **FR-012**: System MUST abort restoration of a single window if the user
  is interacting with it (e.g. dragging) and continue with the rest.

**Permissions and degradation**

- **FR-013**: System MUST detect Accessibility permission state at launch
  and on every restore/capture attempt, presenting an onboarding view when
  missing.
- **FR-014**: System MUST request Automation permission per-bundle-ID
  on-demand the first time a deep-identity provider for that bundle is
  invoked, never proactively.
- **FR-015**: If Automation is denied for a bundle ID, the system MUST
  fall back to the next identity layer for that bundle and never reprompt
  more than once per session.

**Operational**

- **FR-016**: System MUST run as a `LSUIElement` menu bar app (no Dock
  icon, no main window unless Settings is open).
- **FR-017**: System MUST update via Sparkle from a developer-controlled
  appcast over HTTPS with EdDSA signature verification.
- **FR-018**: System MUST be Hardened-Runtime enabled, Developer-ID
  signed, and notarized; un-notarized builds MUST refuse to run.
- **FR-019**: System MUST NOT transmit any captured window data,
  configuration data, or identifiers off-device. Crash reports remain
  local files until the user attaches them to a support request.

### Key Entities

- **DisplayConfiguration**: a set of attached displays at a moment in time,
  identified by a deterministic ID derived from each display's fingerprint.
  Has many `Display`. Owns one current `Snapshot` and a history.
- **Display**: a single physical display, identified by vendor/product/UUID
  hash. Has origin + size in the global coordinate space.
- **Snapshot**: an ordered set of `WindowEntry` records taken at a single
  capture event, scoped to a `DisplayConfiguration`. Has a timestamp and
  optional user-supplied name.
- **WindowEntry**: a single window's recorded state — `bundleID`,
  `WindowIdentity`, target `Display` fingerprint, target Space, frame,
  modifier flags (`isMinimized`, `isFullscreen`).
- **WindowIdentity**: a tagged union — `documentPath(URL)`,
  `browserTabSet([URL])`, `editorWorkspace(URL)`, `terminalCWD(URL)`,
  `titleRegex(pattern, capturedValue)`, or `ordinal(index)`.
- **CaptureTrigger / RestoreTrigger**: an event type — `screensaverStart`,
  `displaySleep`, `screenLock`, `manual`, `wake`, `displayConfigChange`.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: For a session of 50 open windows across 10 apps, auto-restore
  completes within 2 seconds of `NSWorkspace.didWakeNotification` firing on
  Apple Silicon. (p95 over 20 wake events.)
- **SC-002**: For users with 4+ Brave windows open, restore correctly
  matches every window to its captured frame in ≥ 99% of restores when no
  tabs have been added/removed, and ≥ 95% when up to one tab per window has
  changed.
- **SC-003**: Auto-capture writes a snapshot within 2 seconds of the
  triggering idle event in ≥ 99% of trials. The inner-loop wall-clock
  budget (from `SnapshotEngine.capture()` entry to JSON-on-disk) MUST be
  ≤ 500 ms for 100 windows on Apple Silicon (p95 over 50 captures),
  matching project constitution §VII.
- **SC-004**: When the user dock/undocks 20 times alternating between
  laptop-only and laptop+1-monitor configurations, each restore selects the
  correct snapshot (100% — this is a deterministic check, not a heuristic).
- **SC-005**: Idle CPU averaged over a 5-minute window with no events ≤
  0.1% on a 2024 MacBook Air.
- **SC-006**: A new user can grant Accessibility, restart, capture, and
  perform a successful manual restore in ≤ 90 seconds without consulting
  documentation.
- **SC-007**: Zero off-device network requests under default settings, as
  verified by a 24-hour Little Snitch / Charles capture.
- **SC-008**: Resident memory ≤ 30 MB steady state after 1 hour of typical
  usage (5 auto-captures, 2 auto-restores, no Settings interaction) on a
  2024 MacBook Air, matching project constitution §VII. Verified via
  `vmmap --resident` on a debug build with logging at default level.

## Assumptions

- The user is on macOS 14 (Sonoma) or later. Earlier macOS is out of scope
  for v1.
- The user is willing to grant Accessibility permission. Without it, the
  product cannot function and this is the only forced permission.
- Automation permissions are requested per-bundle-ID, lazily — the user is
  willing to grant for the browsers and editors they care about.
- The user accepts direct distribution (notarized .app, Sparkle updates),
  not the Mac App Store.
- The user owns their machine (no MDM restrictions on Accessibility /
  Automation prompts). MDM environments are out of scope for v1.
- Single-user only. Fast-User-Switching behavior is out of scope.
- Sidecar/AirPlay/Continuity displays are treated as regular displays via
  their CoreGraphics presence. Quirks here are acceptable for v1.

---

## Architect Review — spec phase

**Verdict**: ALIGNED
**Components touched**: [App, MenuBar, Settings, Core-Snapshot, Core-Identity, Core-Displays, Core-Spaces, Core-Triggers, Core-Accessibility, Infra]
**Apple frameworks**: [AppKit (public), SwiftUI (public), ApplicationServices/AX (public), CoreGraphics (public for displays / configuration; **private CGS symbols** `CGSCopyManagedDisplaySpaces`, `CGSGetActiveSpace`, `CGSCopyWindowsWithOptionsAndTags` isolated to `Core/Spaces/PrivateCGS.swift` per ADR-0001), IOKit (public), ScriptingBridge / NSAppleScript (public), Sparkle 2.x (third-party — allowed by constitution §VI)]
**ADRs referenced**: [ADR-0001 — Private CoreGraphics symbols for Space identification]
**Constitution alignment**:
  - §I Native macOS — PASS
  - §II Layered window identity — PASS (FR-002 enumerates resolver order: document-path → app-specific deep-identity → title-regex → ordinal)
  - §III Idempotence — PASS (FR-010: 1 px tolerance)
  - §IV Local-only data — PASS (FR-003 / FR-019 / SC-007; only allowed network call is Sparkle appcast per FR-017)
  - §V Graceful permission degradation — PASS (FR-013–FR-015)
  - §VI Direct distribution + justified private API — PASS (FR-018 + ADR-0001)
  - §VII Performance — PASS (SC-001 restore budget, SC-003 capture inner-budget added, SC-005 idle CPU, SC-008 memory added)

**Deviations**: none. The three deviations from the prior spec-phase review (capture inner-budget on SC-003, missing memory SC, missing fullscreen acceptance scenario) are resolved via spec amendments dated 2026-05-27.

**Required C4 updates** (skeleton created in prior run; no new gaps):

- [x] `roadmap/arch/c4/context.md`
- [x] `roadmap/arch/c4/container.md`
- [x] `roadmap/arch/c4/components/{App,MenuBar,Settings,Core-Snapshot,Core-Identity,Core-Displays,Core-Spaces,Core-Triggers,Core-Accessibility,Infra}.md`
- [x] `roadmap/arch/decisions/0001-private-cgs-for-spaces.md`

**Source mode**: directory (c4_root = `roadmap/arch/c4`; adr_root = `roadmap/arch/decisions`)
