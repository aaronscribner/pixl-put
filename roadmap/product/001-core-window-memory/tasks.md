# Tasks: Core Window Memory

**Feature**: 001-core-window-memory | **Generated**: 2026-05-27 (technical-planner) | **Spec**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md) | **Data Model**: [data-model.md](./data-model.md) | **Contract**: [contracts/snapshot.schema.json](./contracts/snapshot.schema.json)

> Tasks are sequenced by phase. `[P]` = parallelisable with other `[P]` tasks in the same phase. `[Story-N]` = user-story tag. Each task lists target file(s) and acceptance criteria. Tests precede implementation (RED → GREEN → REFACTOR).

---

## Phase 1: Design & Contracts (largely complete)

| ID | Type | Description | File(s) | Acceptance |
|----|------|-------------|---------|------------|
| T001 | Done | C4 Level 1–3 skeleton created by architect (spec-phase) | `roadmap/arch/c4/{context.md,container.md,components/*.md}` | Files present; verified by `ls roadmap/arch/c4/` |
| T002 | Done | ADR-0001 created by architect | `roadmap/arch/decisions/0001-private-cgs-for-spaces.md` | File present |
| T003 | Done | JSON schema for snapshot file | `contracts/snapshot.schema.json` | Validates a sample snapshot via `ajv` or `jsonschema` CLI |
| T004 | New  | Swift Package manifest + Xcode project shell | `Package.swift`, `PixPut.xcodeproj/` | `swift build` succeeds with zero source files compiled (empty targets); `xcodebuild -list` shows `PixPut` scheme |
| T005 | New  | App `Info.plist` + `Entitlements.plist` | `Resources/Info.plist`, `Resources/Entitlements.plist` | Contains `LSUIElement=YES`, `SUFeedURL=https://example.invalid/appcast.xml` (TODO), `SUPublicEDKey=TODO`, `NSAppleEventsUsageDescription` |

---

## Phase 2 — Story 1: Windows return to their places on wake (P1)

| ID | Type | Description | File(s) | Acceptance |
|----|------|-------------|---------|------------|
| T010 [P] [Story-1] | Test (RED) | Snapshot Codable round-trip (encode → decode → equal) | `Tests/SnapshotCodecTests/SnapshotCodecRoundTripTests.swift` | Test exists, currently FAILS (no impl) |
| T011 [P] [Story-1] | Test (RED) | WindowEntry Codable matches `contracts/snapshot.schema.json` | `Tests/SnapshotCodecTests/WindowEntrySchemaTests.swift` | Test FAILS; uses a `JSONSchemaValidator` helper |
| T012 [P] [Story-1] | Test (RED) | `Restorer` skips windows already at frame within 1 px | `Tests/RestorerTests/IdempotenceTests.swift` | Test FAILS — covers spec FR-010 + Story-1 acceptance #1 (1px tolerance) |
| T013 [P] [Story-1] | Test (RED) | `Restorer` skips missing window and continues with rest | `Tests/RestorerTests/MissingWindowTests.swift` | Test FAILS — covers Story-1 acceptance #3 |
| T014 [P] [Story-1] | Test (RED) | `Restorer.restoreFullscreen` re-enters fullscreen on correct display | `Tests/RestorerTests/FullscreenTests.swift` | Test FAILS — covers Story-1 acceptance #4 (added 2026-05-27) |
| T015 [Story-1] | Impl (GREEN) | `WindowEntry` Codable conforming to schema | `App/Core/Snapshot/WindowEntry.swift` | T010, T011 PASS |
| T016 [Story-1] | Impl (GREEN) | `Snapshot` Codable | `App/Core/Snapshot/Snapshot.swift` | T010 PASS |
| T017 [Story-1] | Impl (GREEN) | `SnapshotStore` read/write/rotate | `App/Core/Snapshot/SnapshotStore.swift` | New tests `Tests/SnapshotCodecTests/SnapshotStoreTests.swift` PASS (rotation at N=10) |
| T018 [Story-1] | Impl (GREEN) | `Restorer.apply(snapshot:)` with 1 px tolerance + skip-missing + fullscreen | `App/Core/Snapshot/Restorer.swift` | T012, T013, T014 PASS |

---

## Phase 3 — Story 2: Arrangement captured automatically when idle (P1)

| ID | Type | Description | File(s) | Acceptance |
|----|------|-------------|---------|------------|
| T020 [P] [Story-2] | Test (RED) | `Debouncer` coalesces N events within 5 s into 1 | `Tests/DebouncerTests/CoalesceTests.swift` | FAILS |
| T021 [P] [Story-2] | Test (RED) | `Debouncer` honours pause flag (drops events when paused) | `Tests/DebouncerTests/PauseTests.swift` | FAILS — covers Story-2 acceptance #3 |
| T022 [P] [Story-2] | Test (RED) | Capture inner-loop wall-clock budget ≤ 500 ms for 100 fixture windows | `Tests/PerformanceTests/CapturePerfTests.swift` | FAILS — covers spec SC-003 inner budget (added 2026-05-27) |
| T023 [Story-2] | Impl (GREEN) | `Debouncer` generic event coalescer | `App/Core/Triggers/Debouncer.swift` | T020, T021 PASS |
| T024 [Story-2] | Impl (GREEN) | `SnapshotEngine.capture()` orchestrator | `App/Core/Snapshot/SnapshotEngine.swift` | T022 PASS; uses `AXClient` (mocked in test) |
| T025 [Story-2] | Impl | `IdleTriggerWatcher` (NSWorkspace + distributed notification subscriptions) | `App/Core/Triggers/IdleTriggerWatcher.swift` | Manually verified via `quickstart.md` §2 |
| T026 [Story-2] | Impl | Pause-state flag wired through `MenuBarStatusModel` | `App/MenuBar/MenuBarStatusModel.swift` | Manually verified via `quickstart.md` §2c |

---

## Phase 4 — Story 3: Multiple-window identity (P1) — primary extension point

| ID | Type | Description | File(s) | Acceptance |
|----|------|-------------|---------|------------|
| T030 [P] [Story-3] | Test (RED) | `WindowIdentityResolver` tries providers in declared order | `Tests/IdentityTests/ResolverOrderingTests.swift` | FAILS — covers constitution §II |
| T031 [P] [Story-3] | Test (RED) | `DocumentPathProvider` extracts `kAXDocumentAttribute` | `Tests/IdentityTests/DocumentPathProviderTests.swift` | FAILS |
| T032 [P] [Story-3] | Test (RED) | `TitleRegexProvider` per-bundle regex match | `Tests/IdentityTests/TitleRegexProviderTests.swift` | FAILS — uses `Tests/Fixtures/VSCodeTitles.txt` |
| T033 [P] [Story-3] | Test (RED) | `OrdinalProvider` stable ordering by AX window creation index | `Tests/IdentityTests/OrdinalProviderTests.swift` | FAILS — covers Story-3 acceptance #3 |
| T034 [P] [Story-3] | Test (RED) | `BrowserTabSetProvider` happy-path tab-URL extraction | `Tests/IdentityTests/BrowserTabSetProviderTests.swift` | FAILS — uses fixture `Tests/Fixtures/BraveTabSets.json` |
| T035 [P] [Story-3] | Test (RED) | `VSCodeWorkspaceProvider` parses workspace path | `Tests/IdentityTests/VSCodeWorkspaceProviderTests.swift` | FAILS |
| T036 [Story-3] | Impl | `WindowIdentity` tagged union (`Codable`) | `App/Core/Identity/WindowIdentity.swift` | All Phase-4 tests compile |
| T037 [Story-3] | Impl | `WindowIdentityResolver` | `App/Core/Identity/WindowIdentityResolver.swift` | T030 PASS |
| T038 [Story-3] | Impl | `DocumentPathProvider` | `App/Core/Identity/DocumentPathProvider.swift` | T031 PASS |
| T039 [Story-3] | Impl | `TitleRegexProvider` | `App/Core/Identity/TitleRegexProvider.swift` | T032 PASS |
| T040 [Story-3] | Impl | `OrdinalProvider` | `App/Core/Identity/OrdinalProvider.swift` | T033 PASS |
| T041 [Story-3] | Impl | `BrowserTabSetProvider` (Brave only for v1; Edge/Chrome/Arc/Safari → v1.1 backlog) | `App/Core/Identity/AppProviders/BrowserTabSetProvider.swift` | T034 PASS |
| T042 [Story-3] | Impl | `VSCodeWorkspaceProvider` (Xcode/JetBrains/terminals → v1.1 backlog) | `App/Core/Identity/AppProviders/VSCodeWorkspaceProvider.swift` | T035 PASS |

---

## Phase 5 — Story 4: Per-display-configuration partitioning (P2)

| ID | Type | Description | File(s) | Acceptance |
|----|------|-------------|---------|------------|
| T050 [P] [Story-4] | Test (RED) | `DisplayFingerprint` is deterministic for same vendor/product/UUID | `Tests/DisplayFingerprintTests/DeterminismTests.swift` | FAILS |
| T051 [P] [Story-4] | Test (RED) | `displayConfigurationID` is port-order-independent | `Tests/DisplayFingerprintTests/PortOrderTests.swift` | FAILS — covers FR-001 |
| T052 [P] [Story-4] | Test (RED) | Snapshot file selection by `displayConfigurationID` | `Tests/SnapshotCodecTests/ConfigPartitionTests.swift` | FAILS — covers Story-4 acceptance #1 |
| T053 [Story-4] | Impl | `DisplayFingerprint` (vendor / product / UUID hash) | `App/Core/Displays/DisplayFingerprint.swift` | T050, T051 PASS |
| T054 [Story-4] | Impl | `DisplayConfigWatcher` (CG reconfiguration callback) | `App/Core/Displays/DisplayConfigWatcher.swift` | Manually verified via `quickstart.md` §4 |
| T055 [Story-4] | Impl | `DisplayConfiguration` model | `App/Core/Displays/DisplayConfiguration.swift` | T052 PASS |

---

## Phase 6 — Story 5: Manual save / restore + named snapshots (P3)

| ID | Type | Description | File(s) | Acceptance |
|----|------|-------------|---------|------------|
| T060 [Story-5] | Test (RED) | Named-snapshot persistence + listing | `Tests/SnapshotCodecTests/NamedSnapshotTests.swift` | FAILS |
| T061 [Story-5] | Impl | Wire menu-bar "Capture / Restore / Name…" actions | `App/MenuBar/MenuBarController.swift` (additions) | T060 PASS + manually verified via `quickstart.md` §5 |
| T062 [Story-5] | Impl | Cross-config restore confirmation prompt | `App/MenuBar/MenuBarController.swift` (additions) | Manually verified via `quickstart.md` §5b |

---

## Phase 7 — Wake → Restore wiring (cross-cutting, P1)

| ID | Type | Description | File(s) | Acceptance |
|----|------|-------------|---------|------------|
| T070 [P] | Test (RED) | `WakeTriggerWatcher` subscribes to NSWorkspace + CG reconfiguration | `Tests/TriggerTests/WakeTriggerWatcherTests.swift` | FAILS |
| T071 | Impl | `WakeTriggerWatcher` | `App/Core/Triggers/WakeTriggerWatcher.swift` | T070 PASS; manually verified via `quickstart.md` §1 |
| T072 | Impl | Wire `Restorer.apply()` entry from wake event | `App/App/AppLifecycle.swift` | Manually verified via `quickstart.md` §1 |

---

## Phase 8 — AX queue discipline (cross-cutting)

| ID | Type | Description | File(s) | Acceptance |
|----|------|-------------|---------|------------|
| T080 [P] | Test (RED) | `AXClient.enumerateWindows()` returns expected count against fixture | `Tests/AXClientTests/EnumerateTests.swift` | FAILS — uses an injectable AX backend (mock) |
| T081 [P] | Test (RED) | `AXClient` cancellation propagates via `Task.cancel()` | `Tests/AXClientTests/CancellationTests.swift` | FAILS — covers FR-012 |
| T082 | Impl | `AXClient` (serial dispatch queue, async API, injectable AX backend) | `App/Core/Accessibility/AXClient.swift` | T080, T081 PASS |
| T083 | Impl | `AXWindow` typed wrapper | `App/Core/Accessibility/AXWindow.swift` | Used by T082; covered transitively |

---

## Phase 9 — Private CGS isolation (per ADR-0001)

| ID | Type | Description | File(s) | Acceptance |
|----|------|-------------|---------|------------|
| T090 | Impl | `PrivateCGS.swift` — declare 3 symbols with fallback handlers | `App/Core/Spaces/PrivateCGS.swift` | Compiles; fallback paths return sentinel values when symbol unavailable |
| T091 | Impl | `SpaceResolver` public API (no private symbol exposure) | `App/Core/Spaces/SpaceResolver.swift` | Used by `SnapshotEngine`; T011 PASS for spaceIndex field |
| T092 | Manual | `quickstart.md` §9: verify Spaces preserved across capture / restore | `quickstart.md` (update) | Pass criteria documented in quickstart |

---

## Phase 10 — UI (mostly manual-tested per project decision)

| ID | Type | Description | File(s) | Acceptance |
|----|------|-------------|---------|------------|
| T100 | Impl | `@main` + `NSApplicationDelegate` | `App/App/DisplayMaidApp.swift` | App launches as menu-bar-only (no Dock icon); manually verified |
| T101 | Impl | `AppLifecycle` (launch / terminate / wake routing) | `App/App/AppLifecycle.swift` | Manually verified |
| T102 | Impl | `PermissionsBootstrap` (AX gate, Automation per-bundle) | `App/App/PermissionsBootstrap.swift` | Manually verified via `quickstart.md` §5–§6 |
| T103 | Impl | `MenuBarController` + `MenuBarStatusModel` | `App/MenuBar/MenuBarController.swift`, `App/MenuBar/MenuBarStatusModel.swift` | Manually verified |
| T104 | Impl | `OnboardingWindow` (SwiftUI first-run) | `App/MenuBar/OnboardingWindow.swift` | Manually verified via `quickstart.md` §6 |
| T105 | Impl | `Settings/SettingsScene.swift` + `GeneralPane` + `SnapshotsPane` + `AppRulesPane` | `App/Settings/*.swift` | Manually verified via `quickstart.md` §7 |

---

## Phase 11 — Infra

| ID | Type | Description | File(s) | Acceptance |
|----|------|-------------|---------|------------|
| T110 [P] | Test (RED) | `Logging` redacts URLs / paths at default level | `Tests/InfraTests/LoggingRedactionTests.swift` | FAILS |
| T111 [P] | Test (RED) | `Paths` bootstrap creates directories with mode 0o700 | `Tests/InfraTests/PathsBootstrapTests.swift` | FAILS |
| T112 | Impl | `Logging` (swift-log + rotating file destination) | `App/Infra/Logging.swift` | T110 PASS |
| T113 | Impl | `Paths` (Application Support resolution) | `App/Infra/Paths.swift` | T111 PASS |
| T114 | Impl | `Updates` (Sparkle wiring, stub EdDSA + feed URL) | `App/Infra/Updates.swift` | Compiles; Sparkle initialisation reads stub values from `Info.plist` |

---

## Phase 12 — Polish & Testing

| ID | Type | Description | Acceptance |
|----|------|-------------|------------|
| T120 | Verify | `swift test` — all tests pass | Exit 0 |
| T121 | Verify | `swiftlint` — zero new warnings | Exit 0 |
| T122 | Verify | `swift build` + `xcodebuild build` — zero warnings | Exit 0 |
| T123 | Manual | Execute full `quickstart.md` manual checklist | All sections PASS |
| T124 | Doc    | Update `CHANGELOG.md` — `## [Unreleased] / ### Added: Core Window Memory feature` | Entry present, links to spec |
| T125 | Manual | Run `vmmap --resident` after 1 hour of typical use; assert ≤ 30 MB | SC-008 PASS |

---

## Dependency notes

- Phase 2 (Story 1 restore logic) does not depend on Phase 3, 4, 5, 7, 8 — can be done first against fixtures.
- Phase 3 (Story 2 idle capture) depends on Phase 2 for `SnapshotEngine` + `SnapshotStore`.
- Phase 4 (Story 3 identity) depends on Phase 2 for `Snapshot` model only.
- Phase 5 (Story 4 partitioning) depends on Phase 2 for `SnapshotStore` (config-keyed filenames).
- Phase 7 / 8 / 9 / 10 are needed for the app to be runnable end-to-end but tests in Phase 2–5 do NOT require them.

Parallel-execution opportunities are marked `[P]`. Within a phase, all `[P]` tasks can run concurrently because they touch different files. Implementation tasks (no `[P]`) within a phase are strictly sequential because they share the file they're implementing.

---

## Code Reviewer Verdict — tasks phase

**Verdict**: OK
**Tasks reviewed**: 60 (T001–T125)
**IDIOM-GAP tasks**: none
**CONSTITUTION-GAP tasks**: none
**Precept-gap prompts filed**: none

**Per-task mapping (audit):**
- **T001–T005 (Phase 1 design/scaffolding)** — Standard Swift Package Manager + Xcode project setup; no new abstractions. `Info.plist` keys per `agents/stacks/swift.md` conventions + project constitution §VI requirements.
- **T010–T018 (Phase 2 / Story 1)** — All target the `Core/Snapshot` C4 component documented at [`roadmap/arch/c4/components/Core-Snapshot.md`](../../arch/c4/components/Core-Snapshot.md). `Codable` for snapshot persistence is the documented idiom (data-model.md). Restorer's 1-px-tolerance check is project constitution §III, implemented in the documented Restorer file.
- **T020–T026 (Phase 3 / Story 2)** — `Debouncer` is a generic event coalescer documented in C4 [`Core-Triggers.md`](../../arch/c4/components/Core-Triggers.md). `SnapshotEngine` and `IdleTriggerWatcher` are existing C4 components. `MenuBarStatusModel` is the documented observable per [`MenuBar.md`](../../arch/c4/components/MenuBar.md).
- **T030–T042 (Phase 4 / Story 3)** — All identity providers go under `Core/Identity/AppProviders/`, the **primary documented extension point** per project constitution §II + [`Core-Identity.md`](../../arch/c4/components/Core-Identity.md). `WindowIdentity` tagged union (Swift `enum` with associated values) is the documented model — standard Swift idiom; Codable conformance matches `contracts/snapshot.schema.json`'s `oneOf` shape.
- **T050–T055 (Phase 5 / Story 4)** — `DisplayFingerprint` + `DisplayConfigWatcher` per [`Core-Displays.md`](../../arch/c4/components/Core-Displays.md). Uses public CoreGraphics APIs only.
- **T060–T062 (Phase 6 / Story 5)** — Additions to existing `MenuBarController.swift`; no new top-level abstraction.
- **T070–T072 (Phase 7 wake/restore wiring)** — `WakeTriggerWatcher` per [`Core-Triggers.md`](../../arch/c4/components/Core-Triggers.md). `AppLifecycle` per [`App.md`](../../arch/c4/components/App.md).
- **T080–T083 (Phase 8 AX queue)** — `AXClient` + `AXWindow` per [`Core-Accessibility.md`](../../arch/c4/components/Core-Accessibility.md). Serial dispatch queue + async API is the documented Swift idiom for AX discipline (`agents/stacks/swift.md` async/await preference; project constitution §VII operational requirement).
- **T090–T092 (Phase 9 PrivateCGS)** — Three private symbols isolated to `PrivateCGS.swift` per ADR-0001 and project constitution §VI. `SpaceResolver` is the documented public-API seam.
- **T100–T105 (Phase 10 UI)** — Standard AppKit + SwiftUI components per [`App.md`](../../arch/c4/components/App.md), [`MenuBar.md`](../../arch/c4/components/MenuBar.md), [`Settings.md`](../../arch/c4/components/Settings.md). `@Observable` macro for status model per `agents/stacks/swift.md` (iOS 17+ idiom; works on macOS 14+).
- **T110–T114 (Phase 11 Infra)** — `swift-log` (third-party, in plan.md's dependency list) + Foundation file I/O; Sparkle 2.x init.
- **T120–T125 (Phase 12 polish)** — Standard `swift test` / `swiftlint` / `swift build` / `xcodebuild` verification commands per `agents/stacks/swift.md`.

**Advisories** (not gaps — informational):

1. **v1 scope narrowing on AppProviders is documented**. T041 ships **Brave** as the only browser provider for v1; T042 ships **VS Code** as the only editor provider. Other bundles (Edge / Chrome / Arc / Safari / Xcode / JetBrains / iTerm2 / Terminal / Ghostty / Warp) are v1.1 backlog. This is an explicit scope choice per the primary extension point design, not a constitution-gap — adding a new provider is the documented extension path (project constitution §II). Spec FR-002 enumerates the resolution **order** without binding v1 to all of them; the lazy per-bundle Automation flow (FR-014) means unsupported bundles fall to title-regex / ordinal naturally.

2. **Performance budget on capture (T022) and memory (T125)** require Apple-Silicon-specific measurement. CI runners that aren't Apple Silicon will need a target-skip annotation (`#if arch(arm64) && os(macOS)`). Non-blocking — implementer handles at GREEN time.

3. **T011 (schema validation in tests)** introduces an external dependency on a JSON Schema validator. Recommend `JSONSchemaValidator.swift` as a thin in-test helper using `JSONSerialization` + the spec, rather than pulling in a third-party Swift JSON-Schema package (project constitution §I prefers minimal deps). Non-blocking — implementer's call.

**Architect advisory (per hook coordination)**: Tasks ↔ C4 mapping is 1:1. No new C4 components implied. No new ADRs implied. Skeleton + ADR-0001 (created spec-phase) is sufficient.

**No retries needed**: the task list flows from spec acceptance criteria → C4 components → file paths → tests. Every spec acceptance criterion is mapped to at least one task. Every architect-required C4 update is complete. The list is ready for `pre-implement-analyze` gate clearance via analyze-phase verdicts.
