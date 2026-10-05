# PixPut (DisplayMaid-Next)

A macOS menu bar utility that remembers where every window was — including *which* window — and puts each one back where it belongs when the Mac wakes up.

> One-liner from [`roadmap/product/vision.md`](roadmap/product/vision.md). PixPut is for power users on macOS 14+ who lose minutes a day to re-laying-out windows after sleep / dock / undock cycles.

## Status

**v0.1.0 — unsigned debug build, end-to-end working**. Complete implementation including the v1.1 deep-identity expansion: PixPutCore library + AppKit shell + AX client + private CGS isolation + trigger watchers + onboarding + Settings UI + AppleScript executor + per-bundle deep identity (Brave, Edge, Chrome, Arc, Safari, Xcode, iTerm2). 60+ unit tests including performance baselines; `./scripts/build-app.sh` produces a launchable `.app` bundle.

What's NOT yet done: code-signing, notarisation, Sparkle EdDSA key generation, and CWD probing for Terminal.app / Ghostty / Warp (those need `lsof`/`proc_pidinfo` workarounds). See [CHANGELOG.md](CHANGELOG.md) for the full delta.

## Project structure

```
PixPut/
├── App/                          # Swift source for the macOS app
│   └── Core/                     # PixPutCore — testable, pure-Swift layer (implemented)
│       ├── Snapshot/             # SnapshotStore, Restorer, Snapshot, WindowEntry
│       ├── Identity/             # WindowIdentityResolver + providers (extension point)
│       │   └── AppProviders/     # Per-bundle deep-identity providers (Brave, VS Code…)
│       ├── Displays/             # DisplayFingerprint, DisplayConfigurationID
│       └── Triggers/             # Debouncer (generic event coalescer)
├── Tests/                        # XCTest cases
├── Package.swift                 # SwiftPM manifest (PixPutCore library + tests)
├── roadmap/
│   ├── product/                  # Vision, constitution, roadmap, features + per-feature folders
│   │   ├── constitution.md       # 7 load-bearing principles
│   │   └── 001-core-window-memory/  # First feature: spec, plan, tasks, data-model, contracts, quickstart
│   └── arch/                     # C4 model + ADRs
│       ├── c4/                   # Level 1-3 (single-binary app collapses Level 2)
│       └── decisions/            # ADR-0001 (private CGS)
├── agents/                       # Agent prompts (CJCO claude-agents v4.1, retargeted for Swift/macOS)
├── .claude/                      # Constitution, project precepts, hooks, slash commands
└── scripts/                      # Rubric YAMLs + log-run helper
```

## Quick start (developer)

```bash
# yabai (per-window Space moves) is vendored as a submodule
git submodule update --init --recursive

# Run the test suite
swift test

# Build PixlPut.app. This also builds vendor/yabai, signs it with the same
# Developer ID, and installs /Applications/Utilities/yabai.app (SKIP_YABAI=1 to skip).
# It then runs scripts/install-app.sh: installs /Applications/PixlPut.app,
# registers it to open at login, and relaunches it (SKIP_INSTALL=1 to skip).
./scripts/build-app.sh

# One-time privileged yabai setup: sudoers rule for --load-sa, ~/.yabairc,
# launch agent. Re-run after a yabai rebuild that changes the binary.
# Then add /Applications/Utilities/yabai.app under Privacy & Security → Accessibility once;
# the Developer ID signature keeps that grant valid across rebuilds.
./scripts/setup-yabai.sh

# build-app.sh already launched /Applications/PixlPut.app; after that it
# opens at every login. On first launch, grant Accessibility permission when prompted.
# The menu bar icon (rectangle.on.rectangle) appears in the right side
# of the menu bar. Click for the Capture / Restore / Settings menu.

# Tail logs
log stream --predicate 'subsystem == "co.cerebraljuice.pixput"' --info
```

## Signing + notarisation (release-engineering)

When you have a Developer ID Application certificate + App-Specific Password + Sparkle EdDSA keypair ready:

```bash
IDENTITY="Developer ID Application: Your Name (ABCDE12345)" \
KEYCHAIN_PROFILE="AC_PASSWORD" \
./scripts/release-app.sh
```

This signs (Hardened Runtime + entitlements), notarises (via `xcrun notarytool`), and staples the resulting ticket. Then update `Resources/Info.plist`'s `SUFeedURL` + `SUPublicEDKey` (regenerate as needed via Sparkle's `generate_keys`) and push the binary + `sparkle:edSignature` to your appcast host.

## Documents to read in order

1. [`roadmap/product/vision.md`](roadmap/product/vision.md) — what we're building and why
2. [`roadmap/product/constitution.md`](roadmap/product/constitution.md) — the 7 principles that govern the design
3. [`roadmap/product/001-core-window-memory/spec.md`](roadmap/product/001-core-window-memory/spec.md) — first-feature specification
4. [`roadmap/product/001-core-window-memory/plan.md`](roadmap/product/001-core-window-memory/plan.md) — implementation plan
5. [`roadmap/arch/c4/context.md`](roadmap/arch/c4/context.md) — system boundary
6. [`roadmap/arch/decisions/0001-private-cgs-for-spaces.md`](roadmap/arch/decisions/0001-private-cgs-for-spaces.md) — the private-API decision

## Distribution model

- Direct distribution as a Developer-ID-signed, notarised `.app` with Hardened Runtime
- Sparkle 2.x auto-update with EdDSA signature verification
- **Not** distributed via the Mac App Store (sandboxing forbids the Accessibility workflow this product depends on)
- No telemetry, no analytics, no cloud sync — project constitution §IV

## Contributing

This repository uses `@cerebral-juice-co/claude-agents` v4.1 (retargeted for Swift). The factory orchestrates spec → plan → tasks → analyze → RED-GREEN-REFACTOR → QA → reviewers. Hooks at `.claude/hooks/*` gate the workflow; verdict blocks at each phase accumulate state in the feature folder.

Slash commands of interest:
- `/research <topic>` — parallel Market + UX research before `/specify`
- `/tdd-cycle` — RED-GREEN-REFACTOR cycle for an existing feature with `tasks.md`
- `/pr-review [PR]` — strict 6-pass review on the current branch's PR
- `/security-review` — 5-pass macOS-adapted security inspection
- `/stack-swift` — ad-hoc Swift task helper outside the TDD pipeline

## License

TBD (project not yet open-sourced).
