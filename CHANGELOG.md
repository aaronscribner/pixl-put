# Changelog

All notable changes to PixPut (DisplayMaid-Next) are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Releases and rollback

Every release on `main` is an annotated git tag (`v1.0`, `v1.0.1`, …) with a
matching section below. The tag is the rollback point:

```sh
git tag -n                      # list releases with their annotations
git checkout v1.0               # inspect a release
scripts/build-app.sh release    # rebuild that release's bundle
```

`CFBundleShortVersionString` in `Resources/Info.plist` is bumped to match the
tag in the same commit the tag points at, so a running build can always be
traced back to a commit.

## [Unreleased]

### Added
- PixPut enumerates windows on every Space itself, without yabai. `NativeWindowQuery` joins `CGWindowListCopyWindowInfo` (which already returns windows on inactive Spaces) with `CGSCopySpacesForWindows`, and maps Space IDs to indices through the managed Space list. The restore plan can now be built with yabai absent, stopped, or broken, and it is correct on the spanning-display configuration (ADR-0003). yabai is the fallback, and remains the actuator: moving another process's window between Spaces requires running inside Dock, which only yabai's scripting addition does. Measured 2026-09-12 — the window server refuses every cross-connection mutation: `SLSMoveWindowsToManagedSpace` silently no-ops, `SLSSpaceAddWindowsAndRemoveFromSpaces` errors, `SLSSetWindowTags` reports success and changes nothing.
- Two fixes in the vendored yabai fork so it works at all with "Displays have separate Spaces" off, which is the configuration PixPut requires. `SLSCopyManagedDisplaySpaces` keys entries by display UUID only when that setting is on; with it off the window server returns one entry identified as `Main`, so yabai's UUID match found nothing and `display_space_list` returned null for every display. That propagated silently — no views, no tracked windows, and every window command failing with "could not locate the window to act on", while queries still looked healthy because they fall back to a non-Accessibility serializer. The spanning entry is now attributed to the main display, and the startup guard that aborted in this mode is a warning. Verified on macOS 26.2: 52 of 68 windows Accessibility-tracked, and per-window `--space` moves working.
- Restore after a restart: when PixlPut launches within 15 minutes of a reboot it arms the Space-switch restore gate, waits for the login storm of relaunching apps to settle, runs the full cross-Space restore, and repeats it as late apps appear. Setting: Behavior → "Restore after a restart" (default on).
- Cross-Space restore plans every Space in one pass from yabai's window query instead of the active Space AX can see. Space moves and frames on other Spaces go through yabai; the active Space keeps the verified AX frame pass.
- Finder windows get a folder-path identity over AppleScript (they were ordinal-only, so unmatchable after any restart). Browsers report their active tab by title for windows on other Spaces.
- yabai is vendored as a git submodule (`vendor/yabai`, our fork of asmvik/yabai at github.com/aaronscribner/yabai, identifier `co.cerebraljuice.yabai`). `scripts/build-yabai.sh` builds it, signs it with the app's Developer ID so the Accessibility grant survives rebuilds, and installs it as `/Applications/Utilities/yabai.app` (a bundle, not a bare binary: TCC will not record an Accessibility decision for a Mach-O it cannot attribute to a bundle, so a bare yabai can never appear in System Settings); `build-app.sh` runs it (`SKIP_YABAI=1` to skip). PixPut looks for yabai there first.
- `scripts/setup-yabai.sh`: sudoers rule for `--load-sa`, floating layout, launch agent pointed at the installed binary.

### Changed
- "Restore windows to their Spaces" refuses, with instructions, when yabai is installed but not answering (after trying to start it) instead of silently downgrading to per-app moves. A run that moves nothing now always says why in the menu.
- Per-window matching keys on bundle + deep identity; creation ordinals only break ties. Ordinals are renumbered on every app restart, so after a reboot nothing matched.

### Fixed
- Space assignment verification probed only an app's first CG window; for several apps that is an off-screen helper with no Space, so every restore reported "did not take effect" for them. Verification now judges all windows and ignores those reporting zero or many Spaces. Apps already on their Space are no longer given a sticky assignment.

## [1.0.3] — 2026-08-14

### Fixed
- **The diagnostic log deleted its own evidence.** It truncated on every app
  launch, and installing a fix requires a launch — so the record of the run that
  demonstrated a bug was routinely destroyed at the moment it was needed.
  Diagnosing why a Teams window would not move needed window titles from the
  previous run and they were already gone. The log now rotates: the current run
  is `diagnostic.log`, the two before it are `diagnostic.1.log` and
  `diagnostic.2.log`.

### Known limitation (unchanged)
Apps with no deep-identity provider and no title regex resolve to
`.ordinal(N)` — a bare creation index. Those windows restore only while their
CGWindowID survives **or** the number of windows the app has open is identical
at capture and restore. `com.microsoft.teams2` is the clearest case: Teams
recreates its windows, so the windowID join always fails, and a capture taken
with two Teams windows will refuse to restore against one
(`SKIP-ORDINAL-MISMATCH` — correct, since an ordinal cannot survive a count
change). Affected bundles observed here: Teams, Finder, Outlook, Music, Spark,
Messages, qBittorrent, TextEdit, Remote Desktop. Title regexes would fix them.

## [1.0.2] — 2026-08-13

Restore-side counterpart to 1.0.1's capture fixes, plus diagnostics that answer
"which Space did that act on" without cross-referencing files.

### Fixed
- **Restore could apply another Space's frames to your windows.** No restore path
  verified the active Space index, and `restoreNow` read it *twice* — once to
  choose the config and again for `onlySpaceIndex` — so a Space switch landing
  between the two reads loaded one Space's config and filtered it for another.
  All restore paths now take a single verified index
  (`SpaceResolver.settledActiveSpaceIndex`), retrying until the display and the
  on-screen windows agree, the same discipline capture got in 1.0.1.
- **Errored moves incremented no counter**, so a failed move vanished from the
  restore totals and they no longer summed to the entries considered.
- Restore's `apply done` line now records `space=`, `entries=`, `accounted=` and
  flags `UNACCOUNTED` when the counters do not sum, so an entry can no longer go
  missing quietly.
- "No config for this Space" on manual restore and on wake restore logged to
  `os_log` only; both now write to the diagnostic log naming the Space.

### Note on Space numbering
Spaces are 0-based everywhere internal — filenames (`space0`…`space5`), the
diagnostic log, and all code. macOS labels the same Spaces "Desktop 1–6" in its
own UI, so index N is Desktop N+1.

## [1.0.1] — 2026-08-13

Correctness release. Space handling is rebuilt around one file per Space after
the 1.0.0 layout was found to mis-file and overwrite Space data.

### Changed
- **Snapshots are stored one file per (display configuration, Space)** —
  `<configID>.space<N>.plist`, with rotation and history per Space. A capture
  writes only the Space it was taken on and cannot disturb another's config, so
  there is no wholesale replace and no additive cross-capture merge.
- Every restore path (wake, startup, Space switch, Restore now, Restore Picker)
  reads the config for the Space it is acting on. "Restore windows to their
  Spaces" unions all Space configs, since per-app relocation planning is the one
  operation that genuinely needs every Space at once.
- The active Space index is read from the managed display's own `"Current Space"`
  entry rather than `CGSGetActiveSpace` — the same array that defines what an
  index means, so value and ordering cannot disagree.

### Fixed
- **Cross-Space restore collapsed whole apps onto one Space.** The planner's
  tie-break compared `ordinalInApp` values from two incommensurable numberings
  (AX creation ordinals `0,1,2…` against CG window numbers `~30000+`), so ties
  always resolved to whichever Space was active at capture time. Observed as
  every VS Code window being moved to Space 0.
- **Relocation could misplace more windows than it placed.** Per-app assignment
  is now skipped unless it strictly places more windows than it displaces, and
  skipped apps are reported (`Plan.unrestorable`) rather than silently collapsed.
- **Captures could be filed under the wrong Space, overwriting a good config.**
  AX lags a Space switch, briefly reporting the origin Space's windows while the
  display reports the destination. Capture now re-enumerates up to 4 times at
  250 ms until the two agree, and refuses to save if they never do.
- **Sticky "all Desktops" windows corrupted the Space vote.** They report every
  Space, and taking the first ID made them all vote for Space 0; in small
  captures they formed a majority and pulled three separate Desktops onto
  Space 0. Only windows belonging to exactly one Space may vote.
- **A Space with no config failed silently** on Space-switch restore — the skip
  went to `os_log` only. It now writes to the diagnostic log.
- **Failed user actions were invisible.** `statusModel.lastError` only reached
  the user if they opened the menu and clicked the error row, so a refused
  Capture Now looked identical to a successful one. Manual actions that fail now
  raise an alert saying nothing was saved.

### Removed
- The cross-Space CG capture pass. It covered every Space but could only label
  off-Space windows `.ordinal(windowID)` — CG exposes no document URL or tab set
  and `kCGWindowName` is gated behind Screen Recording (measured: 0 of 88 titles
  readable). Per-Space storage makes it unnecessary: every entry now comes from
  the AX pass while its Space was active, so identity is strong throughout.
- `SnapshotMerger` (identity enrichment by windowID, `crossSpaceOrdinal`) — dead
  once the CG pass was gone, and the source of the two-numberings hazard above.

### Migration
Existing `<configID>.plist` snapshots are not read by the new store and are
ignored. Capture each Space once, while on it, to rebuild the configs.

## [1.0.0] — 2026-08-05

First release. Open source; supports one hardware configuration by design
(Samsung Odyssey G9 dual-4K with Spaces spanning displays — ADR-0003).

### Added
- **All-Spaces capture** — one Capture click records every window on every
  Space (CG pass: frame + Space + stable CGWindowID for all Spaces; AX pass:
  full identity for the active Space). Snapshots replace wholesale; identity
  learned on visited Spaces carries forward by windowID.
- **windowID-first restore** — snapshot↔live matching by CG window number,
  identity only for apps restarted since capture. Restore on every Space
  switch and after wake, gated by one toggle.
- **Cross-Space relocation (ADR-0002)** — explicit "Restore windows to their
  Spaces" command via `CGSProcessAssignToSpace` (per-app, sticky) with a
  per-window yabai backend when available. Off the automatic path.
- **MovePolicy** — fast single-attempt AX moves for routine restores; the
  verify-and-retry clamp defense runs only after wake/display changes.

### Changed
- Space-switch restore fires on every visit, not only the first after wake;
  every skipped restore logs its reason to the diagnostic log.
- System UI (Notification Center, Dock, Control Center) excluded from capture.

### Performance
- Restore apply: 2–9 ms per Space (previously 6.7–12 s per moved window;
  full multi-Space pass previously 71 s). Per-move world re-enumeration
  eliminated; enumeration narrowed to snapshot bundles.

### Known limitations
- Sparkle update feed not yet live (`updates.pixput.app` unhosted,
  `SUPublicEDKey` placeholder) — "Check for updates" fails harmlessly.
- Multi-display setups with "Displays have separate Spaces" are unsupported
  and refuse Space operations loudly (ADR-0003).

## [Unreleased] — v0.1.0 (unsigned debug)

### Added
- **Core Window Memory** — complete v1 implementation. Testable Swift Core layer + full AppKit application shell + AX client + private CGS isolation + Sparkle stub. The unsigned debug `.app` bundle launches as a menu bar utility, requests Accessibility permission, and can capture/restore window arrangements end-to-end. 40/40 unit tests passing.
- **PixPutCore library** — `Snapshot` / `WindowEntry` codec, `SnapshotStore` with N=10 rotation and mode-0o700 directory creation, `Restorer` (1-px tolerance idempotence + fullscreen re-entry + skip-missing + user-interaction cancellation), `WindowIdentityResolver` with 4 layered providers (Document path / App-specific deep / Title regex / Ordinal), `BrowserTabSetProvider` (Brave), `VSCodeWorkspaceProvider`, `DisplayFingerprint` + port-order-independent `DisplayConfigurationID`, generic `Debouncer`.
- **AX layer** — `AXClient` actor with serial dispatch-queue discipline (constitution §VII), `AXWindow` typed wrapper, `AXRestorerBackend` bridging AX into the `RestorerBackend` protocol from PixPutCore.
- **Private CGS isolation** (per ADR-0001) — `PrivateCGS.swift` declares `CGSMainConnectionID` + `CGSGetActiveSpace` + `CGSCopyManagedDisplaySpaces` via `dlsym` with fallback paths. `SpaceResolver` exposes the public seam.
- **Trigger system** — `IdleTriggerWatcher` (subscribes to `screensaver.didstart`, `screenIsLocked`, `screensDidSleepNotification`), `WakeTriggerWatcher` (subscribes to `didWakeNotification`, `screenIsUnlocked`, `screensaver.didstop`, CG display reconfiguration). Both route through `Debouncer` per FR-007/FR-008.
- **AppKit shell** — `@main DisplayMaidApp` + `AppDelegate`, `AppLifecycle` orchestrating all layers, `PermissionsBootstrap` state machine, `MenuBarController` with status, `OnboardingWindow` (SwiftUI first-run), Settings scene with General + Snapshots + App Rules panes.
- **Infra** — `LoggerFacade` over `os.Logger` with `.private` redaction for URLs/paths, `Paths` resolving `~/Library/Application Support/DisplayMaid-Next/` with 0o700 bootstrap, `Updates` stub for Sparkle (real wiring deferred to credentialed release session).
- **Resources** — `Info.plist` (LSUIElement, Sparkle keys with TODO placeholders, NSAppleEventsUsageDescription), `Entitlements.plist` (no sandbox, Apple Events).
- **Build tooling** — `scripts/build-app.sh` (debug + release builds, assembles `.app` bundle), `scripts/release-app.sh` (codesign + notarise + staple, requires Developer ID + keychain profile).
- **CI workflow** — `.azure-pipelines/build-and-test.yml` runs `swift build`, `swift test`, `scripts/build-app.sh release`, and publishes an unsigned-PixPut.app artifact.
- **Architecture model** — C4 Level-1 through Level-3 skeleton at `roadmap/arch/c4/` covering 10 components matching the plan's source-tree layout.
- **ADR-0001** — Private CoreGraphics symbols for Space identification with documented fallback paths per project constitution §VI.
- **Project constitution** — load-bearing principles ratified at `roadmap/product/constitution.md`.
- **Agent factory** — `@cerebral-juice-co/claude-agents@^4.1` retargeted from CJCO Platform .NET defaults to Swift / macOS. Agent files, hooks, slash commands, rubrics, precept overlay all retuned. Constitution wired in `.claude/constitution.md`.

### Added (v1.1 expansion — real deep identity wired)
- **AppleScript executor** (`AppleScriptExecutor` + `AppleScriptResult` parsers) — handles `errAEEventNotPermitted` (-1743), `errAEEventNotHandled`, `errAETimeout`, and target-app-not-running as typed error cases so callers can implement the lazy per-bundle Automation fallback required by spec FR-014 / FR-015.
- **`DeepIdentityFetcher` actor** — registers per-bundle AppleScript probes for Brave, Edge, Chrome, Arc, Safari, Xcode, iTerm2. Batches deep-identity fetch to **one AppleScript per running scripted app** (not per window), keeping the snapshot loop within the 500ms perf budget. Caches Automation denials per session.
- **Browser support expanded** — `BrowserTabSetProvider` now lists Brave + Edge + Chrome + Arc + Safari as supported (Chromium family shares one AppleScript; Safari has its own).
- **`XcodeProvider`** — workspace path via `path of document of windows`.
- **`TerminalCWDProvider`** — iTerm2 CWD via `path of current session of windows`. (Terminal.app / Ghostty / Warp deferred — they require `lsof` / `proc_pidinfo` workarounds.)
- **`SnapshotEngine.capture` and `AXRestorerBackend`** both now invoke `DeepIdentityFetcher` so layer-2 identity (browser tab set, editor workspace, terminal CWD) populates `WindowSignal.appProviderIdentity`. Restore matches what capture wrote.
- **Performance baseline tests** — 100-window snapshot encode+write under 50ms; `Restorer` pure-orchestration on 100 windows under 100ms; Codable round-trip under 30ms. Sets the floor for the constitution §VII budgets.
- **`.swiftlint.yml`** committed; CI workflow runs `swiftlint --strict`.

### Known limitations / handoff to release session
- `Info.plist` keys `SUFeedURL` and `SUPublicEDKey` are placeholder TODOs. Sparkle is wired through `Updates.swift` as a no-op stub; real Sparkle integration (`SPUStandardUpdaterController`) lands when Developer ID + EdDSA keypair + appcast URL are available.
- App is **not yet signed** — Developer ID Application certificate not present in this environment. `scripts/release-app.sh` is ready to sign+notarise+staple once credentials are in keychain.
- Terminal.app, Ghostty, Warp — no AppleScript dict for CWD; require `lsof`/`proc_pidinfo` workarounds (future patch).
- VS Code workspace path — `VSCodeWorkspaceProvider` extracts via title regex (works for typical cases); VS Code's AppleScript dict is too limited for a direct path probe.
- `CGDisplayCreateUUIDFromDisplayID` is not exposed via the public CoreGraphics SDK import; display fingerprint uses vendor+product+model+serial only (still sufficiently unique).
