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
- Windows of apps PixlPut has no deeper identity for (Teams, Outlook, Messages, Firefox, Slack, …) are matched after the app or the Mac restarts. Two rules, per app, in every restore path: an exact window title that occurs once among the saved windows and once among the open ones, then the app's sole remaining window. Before this, "Restore windows to their Spaces" and restore after a restart skipped every such window — 19 of them in the 2026-10-01 post-reboot run — and the per-Desktop restore paired them by list position when the counts happened to agree. Window titles are now saved with each capture; layouts captured earlier gain them on their next capture, which rewrites the current layout in place when only titles changed (no history slot used).
- Window identity for VS Code forks (Cursor, VSCodium, Windsurf, VS Code Insiders) and JetBrains IDEs (IntelliJ, PyCharm, WebStorm, Rider, GoLand, CLion, PhpStorm, RubyMine, DataGrip, RustRover, Android Studio), from the workspace or project in the window title.
- "Restore windows to their Spaces" pairs windows by window ID first, so order-only windows captured in the current boot always match.

### Changed
- Order-only windows are never paired on list position alone. That position is renumbered when an app restarts and reordered when windows are focused, so two windows of one app could swap places. When several windows of an app can't be told apart, they are left where they are and counted as `skippedUnidentified`.
- The restore message says why windows were left alone: "couldn't tell these windows apart" (with app names and counts) or "not in your saved layout", instead of "N window(s) had no captured match". The diagnostic log records each unmatched app by reason and how every match was made (`matched by windowID|identity|title|sole-window`).
- Settings → "How windows are recognized after a restart" lists which apps are matched by tab, workspace, document, or title.

### Removed
- Licensing. PixlPut is free and open source, so the license check, 14-day trial, feature gates, License window and Settings pane, and the license API call are gone; every feature is always available and the update check is the only network call. The license server (`server/`), the launch checklist (`SHIPIT.md`), and the website's pricing and buy pages are deleted too.

### Fixed
- A saved window ID from an earlier boot could pair with a different window. The window server numbers windows from scratch after a restart and apps relaunching in the same order draw the same numbers again (VS Code windows 283–291 on 2026-10-01). Window IDs are now trusted only for windows captured since the current boot (`kern.boottime`).

## [1.1.0] — 2026-10-05

The MVP release: restore across every Space and after a restart, per-Desktop
storage, and the duplicate-PID crash fix.

### Added
- PixPut enumerates windows on every Space itself, without yabai. `NativeWindowQuery` joins `CGWindowListCopyWindowInfo` (which already returns windows on inactive Spaces) with `CGSCopySpacesForWindows`, and maps Space IDs to indices through the managed Space list. The restore plan can now be built with yabai absent, stopped, or broken, and it is correct on the spanning-display configuration (ADR-0003). yabai is the fallback, and remains the actuator: moving another process's window between Spaces requires running inside Dock, which only yabai's scripting addition does. Measured 2026-09-12 — the window server refuses every cross-connection mutation: `SLSMoveWindowsToManagedSpace` silently no-ops, `SLSSpaceAddWindowsAndRemoveFromSpaces` errors, `SLSSetWindowTags` reports success and changes nothing.
- Two fixes in the vendored yabai fork so it works at all with "Displays have separate Spaces" off, which is the configuration PixPut requires. `SLSCopyManagedDisplaySpaces` keys entries by display UUID only when that setting is on; with it off the window server returns one entry identified as `Main`, so yabai's UUID match found nothing and `display_space_list` returned null for every display. That propagated silently — no views, no tracked windows, and every window command failing with "could not locate the window to act on", while queries still looked healthy because they fall back to a non-Accessibility serializer. The spanning entry is now attributed to the main display, and the startup guard that aborted in this mode is a warning. Verified on macOS 26.2: 52 of 68 windows Accessibility-tracked, and per-window `--space` moves working.
- Restore after a restart: when PixlPut launches within 15 minutes of a reboot it arms the Space-switch restore gate, waits for the login storm of relaunching apps to settle, runs the full cross-Space restore, and repeats it as late apps appear. Setting: Behavior → "Restore after a restart" (default on).
- Cross-Space restore plans every Space in one pass from yabai's window query instead of the active Space AX can see. Space moves and frames on other Spaces go through yabai; the active Space keeps the verified AX frame pass.
- Browsers report their active tab by title for windows on other Spaces.
- Finder windows are neither captured nor restored. Finder reopens its own windows on their Spaces after a restart, so a PixPut restore could only get in its way, and with no AX document Finder windows matched only by creation order. Capture skips them, restore leaves live Finder windows out, and snapshots taken earlier have their Finder entries dropped when read, so they need no re-capture. The Finder AppleScript is gone, so no Automation permission for Finder is requested.
- yabai is vendored as a git submodule (`vendor/yabai`, our fork of asmvik/yabai at github.com/aaronscribner/yabai, identifier `co.cerebraljuice.yabai`). `scripts/build-yabai.sh` builds it, signs it with the app's Developer ID so the Accessibility grant survives rebuilds, and installs it as `/Applications/Utilities/yabai.app` (a bundle, not a bare binary: TCC will not record an Accessibility decision for a Mach-O it cannot attribute to a bundle, so a bare yabai can never appear in System Settings); `build-app.sh` runs it (`SKIP_YABAI=1` to skip). PixPut looks for yabai there first.
- `scripts/setup-yabai.sh`: sudoers rule for `--load-sa`, floating layout, launch agent pointed at the installed binary.
- `scripts/install-app.sh` installs `/Applications/PixlPut.app` and registers a launch agent (`co.cerebraljuice.pixlput.login`) that opens it at every login; `build-app.sh` runs it at the end (`SKIP_INSTALL=1` to skip, which `release-app.sh` does). Restore after a restart was unreachable without it: nothing launched PixlPut at boot, and the build bundle it ran from is deleted on every rebuild.

### Changed
- "Restore windows to their Spaces" refuses, with instructions, when yabai is installed but not answering (after trying to start it) instead of silently downgrading to per-app moves. A run that moves nothing now always says why in the menu.
- Per-window matching keys on bundle + deep identity; creation ordinals only break ties. Ordinals are renumbered on every app restart, so after a reboot nothing matched.

### Fixed
- PixlPut crashed whenever macOS listed one process twice among running apps. Measured 2026-10-02: a WebKit web-content helper appeared twice under one PID, and the PID → bundle map (`Dictionary(uniqueKeysWithValues:)`) trapped — once right after unlock, losing the armed wake restore, and again seconds after relaunch. Every window enumeration builds that map since the window-owner filter, so the crash repeated for as long as the duplicate was listed. Duplicates now keep the first entry; the display-UUID map in capture is hardened the same way.
- Layouts were stored by Space position, so adding, removing or reordering a Desktop sent every later Space's layout to the wrong Desktop. Measured: a Desktop was deleted and another created at position 5, the wake restore applied Space 5's saved layout to the new Desktop and Space 6's to the old Space 5 (`skippedMissingWindow=5`), and "Restore windows to their Spaces" would have moved those windows onto the wrong Desktops. Snapshots are now stored per Desktop UUID (`<configID>.space-<UUID>.plist`, stable across reboots) and loaded entries report the Desktop's current position. Position-keyed files from earlier builds are ignored while Desktop UUIDs are available, so every Desktop needs one re-capture.
- Browser windows on inactive Spaces never matched their captures. Their identity is the active tab's URL, joined by window title to the browser's AppleScript window list, but AX and yabai titles end in the browser's name (" - Brave", " - Microsoft Edge") while AppleScript window names are the page title alone. Measured: all 26 Brave and 3 Edge windows on other Spaces went unmatched and would not have been moved back. The join now also tries the title up to the browser's name (including a trailing profile name), and the cross-Space log reports `browserDocs=`.
- Settings described "Auto-restore on Space switch & wake" as restoring "every time you switch to a Space". It restores once per wake: the Space on screen right away, every other Space on its first visit afterwards, and later visits leave windows alone. The description now says so; the behavior is unchanged and intended.
- "Restore windows to their Spaces" moved nothing and said nothing was needed. The native every-Space query asked CoreGraphics for all windows' Spaces in one call, which returns the union of their Spaces pinned to the first window, so every other window had no Space and was dropped: 1 row for 170 windows, measured live, and 0 windows to plan with. Spaces are now looked up per window (67 resolved, all 8 VS Code windows agreeing with yabai). A native list covering under half of yabai's tracked windows is now treated as broken: the restore plans from yabai's query instead and logs `native window query unusable`.
- The cross-Space restore could not identify windows on Spaces AX cannot see. Its window list comes from CoreGraphics, which withholds titles without Screen Recording (0 of 13 VS Code windows measured), and every identity on those Spaces is built from a title: VS Code's workspace name and the browser documents joined by title. They resolved ordinal-only and were skipped as unmatched. Titles now come from yabai's query, which reads them over AX; the log reports `titledByYabai=`.
- Every window enumeration took ~7s. It asked all 74 running processes with a UI policy for their windows, including background helpers that own none; five WebKit web-content helpers never answered and each cost the full 1s AX timeout. Only processes the window server lists as owning a normal window (on any Space) are asked now.
- Capture now could save a different Space than the one it was pressed on. Capture re-reads the window list until AX agrees with the display; with slow enumerations the user had moved on by then, so the capture settled wherever they stopped. Measured: presses on five Spaces all completed as captures of the Space the user lingered on, reported as "unchanged", with no message. A capture is now pinned to the Space on screen at the click and refused, with a message, if the display has left it before the window list is read.
- Deep identity scripts failed silently. Every AppleScript outcome — skipped as denied, window and document counts, the AppleScript error kind and message, and the time taken — is now written to the diagnostic log (counts only, no titles or URLs).
- "Identify individual browser/editor windows" (deep identity) was not persisted and turned itself off on every launch, so any restart — including every install — silently captured and restored without it. It is now saved like the other settings (default still off).
- Popups, off-screen placeholders and panels were saved as windows. AX lists them, and capture only dropped windows under 100 px, so a 320×136 Edge popup was captured; each one also took a creation ordinal from a real window of its app, and a count that differed at restore made the whole app's ordinal matches skip. Capture and restore now keep only role `AXWindow` with a standard, floating or dialog subrole — yabai's rule. The cross-Space restore likewise drops CoreGraphics windows yabai does not track (measured: 13 such beside 63 real windows), logged as `untracked=`.
- Deep identity joined AppleScript results to AX windows by position, but Finder's and the browsers' scripts list windows on every Space while AX lists only the active one, so a Finder window could be saved with another Space's folder. Apps with a documents-by-title script are now joined by title (a title showing two different documents gets none) — the same join the cross-Space restore uses, so both resolve a window to the same identity.
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
