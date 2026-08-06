# Changelog

All notable changes to PixPut (DisplayMaid-Next) are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
