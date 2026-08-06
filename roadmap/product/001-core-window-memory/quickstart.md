# Quickstart: Core Window Memory — Manual Integration Test Checklist

**Feature**: 001-core-window-memory | **Date**: 2026-05-23 |
**Spec**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md)

This document IS the integration test suite for spec 001. The product's
behavior depends on real Accessibility events, real CoreGraphics
display reconfiguration callbacks, real Space switching, and real
per-bundle Automation TCC dialogs — none of which are reliably reproducible
under XCUITest. Every release ships only after this checklist passes
end-to-end on a clean install.

## Test machine setup

These tests presume the following baseline:

- macOS 14 Sonoma or later (the v1 baseline; v1.x bumps to 15+ when
  customers cross over).
- Apple Silicon Mac (M1 or later). Run the full suite on Intel for major
  releases only.
- A clean test user account, *not* the daily-driver account. Required so
  TCC dialogs fire fresh.
- At least one external display available (USB-C or HDMI). Some tests
  also require a second external display.
- The following apps installed in `/Applications`:
  - Brave Browser
  - Microsoft Edge
  - Google Chrome (any one Chromium browser other than Brave/Edge is
    fine; Chrome is the most common)
  - Safari (always present)
  - Visual Studio Code
  - Xcode
  - iTerm2
  - Apple Terminal (always present)
  - At least one JetBrains IDE (any — IntelliJ CE is free)
- A fresh build of `DisplayMaid-Next.app` placed in `/Applications`.
- Application Support data wiped before starting:
  `rm -rf "~/Library/Application Support/DisplayMaid-Next"`

Before each major-version test, do `tccutil reset Accessibility
co.cerebraljuice.displaymaid-next` and `tccutil reset AppleEvents
co.cerebraljuice.displaymaid-next` so onboarding fires from scratch.

## Conventions

Each scenario below has:

- **Maps to**: which spec.md story or edge case it exercises.
- **Setup**: state to prepare before pressing Go.
- **Steps**: numbered, do not skip.
- **Pass criteria**: explicit assertions. Any miss = scenario fails =
  release is blocked.
- **On fail**: where to look first.

A scenario marked **(release-gate)** must pass on every release. A
scenario marked **(per-major)** runs only on major versions and Intel.

---

## Scenario 0 — Menu items open the expected windows **(release-gate, smoke)**

**Maps to**: regression guard against the "Settings does nothing" class of LSUIElement responder-chain bugs.

**Setup**: Fresh build, app launched, menu bar icon visible.

**Steps**:
1. Click the menu bar icon → click **Settings…** → "PixPut Settings" window must appear with 3 tabs.
2. Close it. Re-open from the menu → same window comes back (no leak, no second window).
3. From the menu, click **Pause auto-capture** → status header updates to "Paused" within ~1s.
4. Click again (now "Resume auto-capture") → status returns to "Active".
5. Quit via menu → process exits cleanly.

**Pass criteria**: Every menu item opens the window or toggles the state it claims to.

---

## Scenario 1 — First-launch onboarding **(release-gate)**

**Maps to**: spec.md US1, FR-013, FR-016.

**Setup**:
- TCC reset as above.
- No previous Application Support data.

**Steps**:
1. Launch `DisplayMaid-Next.app`.
2. Observe: an onboarding window appears explaining Accessibility
   permission. No dock icon.
3. Click "Open System Settings" — verify it deep-links to Privacy &
   Security → Accessibility.
4. Enable the toggle for DisplayMaid-Next.
5. Return to the app. Observe: the onboarding window dismisses
   automatically (via `AXIsProcessTrusted` polling). A menu bar icon
   appears.
6. Quit the app via the menu. Relaunch.

**Pass criteria**:
- No dock icon at any point.
- Onboarding window does not re-appear on relaunch (permission was
  persisted).
- Menu bar icon is present and clickable.

**On fail**: check `LSUIElement` in Info.plist; check
`PermissionsBootstrap.swift` AX-poll loop.

---

## Scenario 2 — Manual capture and restore, single display **(release-gate)**

**Maps to**: spec.md US1 (independent test), US5, FR-009, FR-010.

**Setup**:
- Onboarding complete. One display (laptop or external; the test is
  display-count-agnostic).
- Open three apps with one window each: Finder, Calculator, TextEdit
  (new document). These were chosen because none of them require
  Automation permission.

**Steps**:
1. Arrange the three windows at known, visually distinct positions
   (e.g. Finder top-left, Calculator center, TextEdit bottom-right).
2. Open the menu bar → "Capture Snapshot Now".
3. Observe: a snapshot file is written to
   `~/Library/Application Support/DisplayMaid-Next/snapshots/<id>.json`
   within 2 s. Inspect with `cat` — verify three `WindowEntry` records
   with `bundleID` for each app, `kind: "ordinal"` for Calculator and
   Finder (no document path), and `kind: "documentPath"` for TextEdit
   (with the new untitled document path — may be absent → ordinal).
4. Move all three windows to overlapping positions in the top-left.
5. Open the menu bar → "Restore Last Snapshot".
6. Time the restore from click to all-windows-stopped.

**Pass criteria**:
- All three windows return to their original frames, within 1 px
  tolerance (eyeball is fine; tape-measure a corner if doubt).
- Restore completes in under 1 second wall clock.
- No window flickers or moves twice.
- No errors in `logs/`.

**On fail**: check `Restorer.swift` move-loop; check AX timeouts firing.

---

## Scenario 3 — Auto-capture on screen saver, auto-restore on wake **(release-gate)**

**Maps to**: spec.md US1 AS2, US2 AS1, FR-005, FR-006, SC-001, SC-003.

**Setup**: Same as Scenario 2 setup, fresh windows arranged.

**Steps**:
1. Open Terminal and run `pmset displaysleepnow`.
2. Wait 5 seconds, then move the mouse to wake the display.
3. Inspect the snapshots file — verify a NEW snapshot entry was added
   with `trigger: "displaySleep"` and `capturedAt` matching step 1's
   time (±2s).
4. Move all three windows to new positions.
5. Run `pmset displaysleepnow` again. Wait 5 s. Wake.
6. Within 2 s of wake, the three windows should auto-restore to the
   positions captured in step 1.

**Pass criteria**:
- Capture happens on display sleep without manual action (SC-003).
- Auto-restore fires on wake without manual action.
- Restore completes within 2 s of the wake event (SC-001 — 50-window
  budget; we are well under).
- Three windows match their captured frames within 1 px.

**On fail**: check `IdleTriggerWatcher.swift` distributed notification
subscriptions; check `WakeTriggerWatcher.swift`; check the `Debouncer`
isn't suppressing the trigger.

---

## Scenario 4 — Four Brave windows, distinct tab sets **(release-gate)**

**Maps to**: spec.md US3 AS1, FR-002. The headline differentiator.

**Setup**:
- Brave installed. Quit any running Brave instance.
- Launch Brave. The first time DisplayMaid-Next runs a browser identity
  provider against Brave, an Automation TCC dialog will fire — pre-grant
  it now by opening menu → Settings → "App Rules" pane → click "Test
  Brave Access" (which triggers the prompt deliberately).

**Steps**:
1. Open four Brave windows. In each, open three distinct tabs by URL:
   - Window A: docs.python.org, github.com/anthropics, news.ycombinator.com
   - Window B: en.wikipedia.org/wiki/Spec, openstreetmap.org, weather.com
   - Window C: youtube.com, music.apple.com, soundcloud.com
   - Window D: gmail.com, calendar.google.com, drive.google.com
2. Drag each window to a visually distinct frame (top-left, top-right,
   bottom-left, bottom-right respectively).
3. Capture snapshot.
4. Drag all four windows into the center, overlapping.
5. Restore last snapshot.

**Pass criteria**:
- Window A returns to top-left, B to top-right, C to bottom-left, D to
  bottom-right — matched by tab set, NOT by launch order.
- Inspect the snapshot JSON: each Brave entry has `identity.kind:
  "browserTabSet"` with three URLs and a 16-char hex hash.
- The menu bar's "Last Restore" status shows no warnings.

**On fail**: this is the most diagnostic scenario. Failures here mean:
- ScriptingBridge call failed silently (check logs for the bundle).
- Tab URL normalization isn't matching (compare sorted URLs in
  snapshot vs. live).
- Frame-based SB-to-AX matching is mismatching (check
  `BrowserTabSetProvider.swift` matchByFrame).

---

## Scenario 5 — Three VS Code workspaces **(release-gate)**

**Maps to**: spec.md US3 AS2, FR-002. Tests the storage.json approach.

**Setup**:
- VS Code installed. Three test folders that don't already appear in
  VS Code's recent-workspaces list (or any three folders).

**Steps**:
1. Open each folder in VS Code as a separate workspace (File → New
   Window → Open Folder). You should have three VS Code windows.
2. Drag each window to a distinct frame.
3. Capture snapshot.
4. Quit VS Code entirely (Cmd+Q).
5. Relaunch VS Code. Reopen the same three workspaces via File →
   Recent.
6. Drag all three to the center, overlapping.
7. Restore last snapshot.

**Pass criteria**:
- Each VS Code window returns to the frame whose snapshot entry matches
  its workspace path.
- Inspect the snapshot: each VS Code entry has `identity.kind:
  "editorWorkspace"` with `confidence: "verified"` (the storage.json
  cross-reference succeeded). If `confidence: "titleOnly"`, that's a
  warning — investigate before passing.

**On fail**:
- `confidence: "titleOnly"` means storage.json couldn't be read or the
  basename didn't match. Check `~/Library/Application Support/Code/
  storage.json` exists and contains `windowsState.openedWindows`.
- Per-bundle storage path mapping in `VSCodeWorkspaceProvider.swift`.

---

## Scenario 6 — Two terminals, distinct CWDs **(release-gate)**

**Maps to**: spec.md US3 generally, terminal provider specifically.

**Setup**:
- iTerm2 installed with Shell Integration installed in the test
  account's shell. (Steps to install: iTerm2 → Install Shell
  Integration menu.)
- Two distinct directories: `/tmp/test-a` and `/tmp/test-b`.

**Steps**:
1. Open two iTerm2 windows. In window 1, `cd /tmp/test-a`. In window 2,
   `cd /tmp/test-b`.
2. Drag to distinct frames.
3. Capture.
4. Swap the windows (drag window 1 to window 2's frame and vice versa).
5. Restore.

**Pass criteria**:
- The window currently in `/tmp/test-a` returns to window 1's original
  frame; the window currently in `/tmp/test-b` returns to window 2's
  original frame.
- Snapshot entries: `identity.kind: "terminalCWD"` with the CWD URL.

**On fail**:
- Shell integration not installed → SB returns empty `session.path` →
  provider falls through to title regex. Either install integration or
  accept ordinal fallback per the documented behavior.

---

## Scenario 7 — Display configuration partitioning **(release-gate)**

**Maps to**: spec.md US4 AS1/AS2/AS3, FR-001, FR-003, SC-004.

**Setup**: External display available. Start with it attached.

**Steps**:
1. Arrange windows on both displays.
2. Capture snapshot. Note its filename
   (`snapshots/<configurationID-A>.json`).
3. Detach external display. Observe windows reflow onto laptop display.
4. Arrange them on the laptop differently than before.
5. Capture snapshot. Verify a SECOND file exists
   (`snapshots/<configurationID-B>.json`).
6. Reattach external display. Wait ~2 s for CGDisplay reconfigure to
   settle.
7. Observe: auto-restore fires and applies snapshot A (verify by
   comparing window positions to step 2).
8. Detach again. Wait. Observe auto-restore applies snapshot B.
9. Repeat the attach/detach cycle 10 times.

**Pass criteria**:
- Two distinct snapshot files exist, one per configuration.
- Each attach/detach cycle restores the correct snapshot — 100%
  success rate over 10 cycles (SC-004 is deterministic, not
  statistical).
- No "displaced" warning appears for windows that have a matching
  display in the active configuration.

**On fail**:
- Configuration ID isn't deterministic — check
  `DisplayFingerprint` hash inputs.
- Wake debouncer is firing before display reconfigure completes —
  inspect logs for `reconfigure` and `restore` event order.

---

## Scenario 8 — Wake-storm debounce **(release-gate)**

**Maps to**: spec.md FR-008, edge case "Repeated wake within 5 s".

**Setup**: Single display, three windows arranged and captured.

**Steps**:
1. Move windows to new positions.
2. Run `pmset displaysleepnow`. Wait 1 s. Wake. (Restore should fire.)
3. Within 5 s of the wake, run `pmset displaysleepnow` again. Wake
   immediately.
4. Within another 5 s, repeat once more.

**Pass criteria**:
- Exactly one restore happens per wake event.
- Within the 5 s debounce window, repeated wake events do NOT trigger
  repeated restores (this is the bug we're guarding against — visually:
  windows should not jitter).
- Logs show "wake event suppressed by debouncer" entries for the
  in-window events.

**On fail**: `Debouncer.swift` trailing-edge logic; verify `quietWindow`
and `maxWait` constants match research.md §R-9.

---

## Scenario 9 — Automation denied for a bundle **(release-gate)**

**Maps to**: spec.md edge case "Browser running in a profile we cannot
script", FR-015.

**Setup**:
- TCC reset for AppleEvents:
  `tccutil reset AppleEvents co.cerebraljuice.displaymaid-next`
- Brave running with two windows, distinct tab sets.

**Steps**:
1. Capture. TCC dialog fires asking for Automation permission for Brave.
2. Click "Don't Allow".
3. Inspect snapshot. Verify both Brave entries fell through to
   `titleRegex` (with the captured browser title) or `ordinal`. NOT
   `browserTabSet`.
4. Restore. Both Brave windows should restore based on the chosen
   fallback identity. A "best-effort" badge should be visible on the
   menu bar status item.
5. Capture again. Verify TCC dialog does NOT re-fire (FR-015: at most
   once per session).
6. Quit the app and relaunch. Capture again. Verify TCC dialog DOES
   re-fire (the "once per session" reset).

**Pass criteria**:
- Provider falls through silently without freezing or showing errors.
- No reprompt within a session.
- Fresh prompt after relaunch.

**On fail**: `BrowserTabSetProvider.swift` error handling; in-memory
"denied bundles" set; relaunch reset.

---

## Scenario 10 — Accessibility revoked at runtime **(release-gate)**

**Maps to**: spec.md edge case "Accessibility permission revoked at
runtime", FR-013.

**Setup**: App running, Accessibility granted, idle.

**Steps**:
1. Open System Settings → Privacy & Security → Accessibility.
2. Toggle DisplayMaid-Next OFF.
3. Return to the app. Open the menu bar dropdown.

**Pass criteria**:
- A banner is visible at the top of the menu saying "Accessibility
  required — click to grant."
- Clicking the banner deep-links to the right Settings panel.
- "Capture Snapshot Now" and "Restore Last Snapshot" are disabled.
- The app does not crash, does not spam dialogs, does not write logs
  more than once per minute about the missing permission.

**On fail**: AX-state polling cadence; menu reactivity to AX state
changes.

---

## Scenario 11 — User dragging a window during restore **(release-gate)**

**Maps to**: spec.md edge case "User drags a window during restore",
FR-012.

**Setup**: Single display, twenty windows arranged and captured (open
20 Finder windows; quick way: cmd+N twenty times in Finder). Move them
all to overlapping center.

**Steps**:
1. Initiate restore.
2. Immediately click and hold one of the restoring windows' title bar.
3. Hold it for 3 seconds.

**Pass criteria**:
- The held window is NOT moved by the restorer (the user's drag wins).
- The other 19 windows complete their restore normally.
- The menu bar status shows "19 of 20 windows restored, 1 in use".
- No fight-with-the-user behavior — the held window stays where the
  user moves it after release.

**On fail**: `Restorer.swift` AX-drag-detection (check for `kAXMainAttribute`
or `kAXFocusedAttribute` changing during the move).

---

## Scenario 12 — Multiple Spaces with windows **(release-gate)**

**Maps to**: spec.md edge cases, FR-009 (Space restoration), research.md
§R-6/§R-7.

**Setup**:
- Single display.
- Create three Spaces (Mission Control → +).
- Place one window on each Space: Finder on Space 1, Safari on Space 2,
  Calculator on Space 3.

**Steps**:
1. Capture.
2. Move all three windows to Space 1 (Mission Control drag).
3. Restore.

**Pass criteria**:
- Each window ends up on its captured Space (Finder on 1, Safari on 2,
  Calculator on 3).
- Final visible Space is whichever was active before restore started.
- Total restore time ≤ 3 s (we switch Spaces three times via key chord;
  500ms each is the budget).

**On fail**:
- Inspect logs for the synthesized key event firing — verify the chord
  matches the user's actual Mission Control shortcuts.
- If `spaceID: null` in the snapshot, R-6 fallback is active — verify
  the user has `CGSCopyManagedDisplaySpaces` working (a Console.app
  log line at boot).

---

## Scenario 13 — Window minimized at capture **(release-gate)**

**Maps to**: spec.md edge case "Window minimized at capture".

**Setup**: Default preference `restoreMinimized = false`.

**Steps**:
1. Open three windows. Minimize one (yellow button).
2. Capture. Inspect snapshot — minimized window has `isMinimized: true`.
3. Un-minimize the window. Move all three.
4. Restore.

**Pass criteria** (with default `restoreMinimized = false`):
- The previously-minimized window is left where the user un-minimized
  it (NOT re-minimized).
- The other two windows restore to their captured frames.

**Now** change `restoreMinimized` to `true` in Settings and repeat:
- The previously-minimized window is re-minimized on restore.

**On fail**: `Restorer.swift` minimization branch; preference
plumbing.

---

## Scenario 14 — Window full-screen at capture **(release-gate)**

**Maps to**: spec.md edge case "Window full-screen at capture" + Story-1 acceptance scenario #4 (added 2026-05-27).

**Setup**: One window full-screened in its own Space.

**Steps**:
1. Capture. Inspect — entry has `isFullscreen: true`, a `spaceID`
   referencing the fullscreen Space.
2. Exit fullscreen for that window.
3. Restore.
4. (Extension for Story-1 acceptance #4) Detach the recorded display, then
   restore again. Confirm the window is moved to the primary display in
   windowed mode and tagged "displaced" per FR-011.

**Pass criteria**:
- The window re-enters fullscreen mode on the recorded display (within
  the per-window restore budget).
- The fullscreen Space is recreated if no longer present.
- When the recorded display is absent, the window does NOT enter
  fullscreen on a different display — it lands in windowed mode on the
  primary display with the "displaced" badge.

**On fail**: AX fullscreen is fiddly — `kAXFullScreenAttribute` may need
to be set via `AXUIElementSetAttributeValueWithNotification` to work
reliably.

---

## Scenario 15 — App not running at restore **(release-gate)**

**Maps to**: spec.md edge case "App not running at restore".

**Setup**: Capture with TextEdit running and a document open.

**Steps**:
1. Capture.
2. Quit TextEdit entirely.
3. Restore.

**Pass criteria**:
- TextEdit is NOT relaunched (default behavior — `relaunchMissingApps =
  false`).
- The TextEdit entry is logged as skipped.
- Other windows restore normally.
- Menu bar "Last Restore" shows "N of M restored, 1 missing apps".

**On fail**: `Restorer.swift` running-app check before AX traversal.

---

## Scenario 16 — Display removed between capture and restore **(release-gate)**

**Maps to**: spec.md edge case "Window opened on a display that no
longer exists", FR-011.

**Setup**: External monitor attached. Window placed on the external.

**Steps**:
1. Capture with window on external.
2. Detach external monitor.
3. Restore.

**Pass criteria**:
- The window is placed on the primary (laptop) display, near the
  normalized coordinates of its original frame (i.e. if it was in the
  top-right of the external, it lands in the top-right of the laptop).
- Snapshot entry is tagged `displaced` in the menu bar status.
- The displaced count is visible: "1 window displaced".
- No window is placed off-screen.

**On fail**: `Restorer.swift` display-missing branch; coordinate
normalization formula.

---

## Scenario 17 — Pause auto-capture **(release-gate)**

**Maps to**: spec.md US2 AS3.

**Steps**:
1. Open menu bar → toggle "Pause Auto-Capture".
2. Menu shows a paused indicator (e.g. zzz icon).
3. Run `pmset displaysleepnow`. Wake.
4. Inspect snapshot history — no new entry was added.
5. Toggle off pause. Sleep. Wake.
6. Verify a new snapshot entry now exists.

**Pass criteria**: pause is honored; visual indicator is correct.

---

## Scenario 18 — Named snapshots **(release-gate if shipped)**

**Maps to**: spec.md US5 AS1/AS2.

If named snapshots were dropped from v1 per the roadmap, skip this
scenario for v1.0; it returns in v1.1.

**Steps**:
1. Capture, then via menu name it "morning".
2. Rearrange windows. Capture, name it "video call".
3. From menu, restore "morning". Windows match arrangement 1.
4. Restore "video call". Windows match arrangement 2.
5. Detach external monitor (different configuration).
6. Try to restore "morning". A confirmation dialog appears noting the
   configuration mismatch.

**Pass criteria**: names persist; cross-config restore is gated.

---

## Scenario 19 — Idempotent restore **(release-gate)**

**Maps to**: constitution §III, spec.md FR-010.

**Steps**:
1. Capture. Don't move anything.
2. Restore.

**Pass criteria**:
- No windows move (every window is already within 1 px of its target).
- Restore reports "0 of N moved, N already in place".
- The restore completes in under 200 ms (it's all reads).

**On fail**: `Restorer.swift` skip-if-equal check; tolerance constant.

---

## Scenario 20 — Performance: 50 windows **(per-major)**

**Maps to**: spec.md SC-001, SC-002, SC-003.

**Setup**: A test harness that opens 50 windows of mixed apps (10
Finder, 10 TextEdit, 10 Calculator, 10 Safari with single tabs, 10
Preview).

**Steps**:
1. Capture. Measure wall time from menu click to file write.
2. Move all windows. Restore. Measure wall time from wake-signal to
   final window settled.
3. Repeat 20 times. Compute p95.

**Pass criteria**:
- Capture p95 ≤ 500 ms.
- Restore p95 ≤ 2000 ms (SC-001).
- No AX timeouts in logs.

**On fail**: profile via Instruments → Time Profiler; usually the AX
serial queue is the bottleneck and the budget is achievable.

---

## Scenario 21 — Network silence **(per-major)**

**Maps to**: spec.md SC-007, constitution §IV.

**Steps**:
1. Install Little Snitch in trial mode.
2. Launch DisplayMaid-Next. Leave running for 24 hours of normal use.
3. Inspect Little Snitch's log filtered to the DisplayMaid-Next bundle.

**Pass criteria**:
- The ONLY outbound connections are to the Sparkle appcast URL.
- No telemetry endpoints. No DNS to analytics services. No background
  network on capture or restore events.

**On fail**: grep the binary for any non-Sparkle URL string. Likely
culprits: a third-party log shipper, a crash reporter (we ship none —
crashes go to local files only).

---

## Sign-off

A release is approved when all **release-gate** scenarios above pass on
the test machine of record. **Per-major** scenarios additionally pass
on the Intel reference machine for major version bumps. The release
engineer initials each scenario in a checklist tracked alongside the
build artifact.

If any scenario fails, the failure is logged in the release ticket and
either:
- fixed and the affected scenarios re-run, or
- documented as a known limitation in release notes with explicit
  justification (constitution-level deviations require a Complexity
  Tracking entry in plan.md).
