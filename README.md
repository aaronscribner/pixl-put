# PixlPut

A macOS menu bar app that remembers where every window was, on every Desktop, and puts each one back after sleep, wake, a display change, or a restart.

Most window-restore tools treat all windows of an app as interchangeable: restore four browser windows and you get four browser windows somewhere, not each one where it was. PixlPut tells windows apart. It matches browser windows by their open tab, editor windows by their workspace or project, and document windows by their document, so each one goes back to its own spot.

> **Before you go further:** PixlPut is a personal tool, developed and tested on exactly one hardware setup (described in [Supported configuration](#supported-configuration)). It may work elsewhere, but nothing else has been tested. Moving windows between Desktops also depends on [yabai](https://github.com/asmvik/yabai) with System Integrity Protection partially disabled. Read [Requirements](#requirements) before installing.

## Contents

- [What it does](#what-it-does)
- [Supported configuration](#supported-configuration)
- [Requirements](#requirements)
- [Install](#install)
- [Using PixlPut](#using-pixlput)
- [How windows are recognized](#how-windows-are-recognized)
- [Privacy](#privacy)
- [Files and logs](#files-and-logs)
- [Troubleshooting](#troubleshooting)
- [Building from source](#building-from-source)
- [Releasing](#releasing)
- [Project layout](#project-layout)
- [Design documents](#design-documents)
- [Contributing](#contributing)
- [Acknowledgements](#acknowledgements)
- [License](#license)

## What it does

- **Restores after sleep and wake.** Waking the Mac, waking the displays, unlocking, or a display reconfiguration triggers a restore. Windows already in place are left alone.
- **Keeps a layout per Desktop.** Each Mission Control Desktop (Space) has its own saved layout, stored by the Desktop's identity rather than its position, so adding, removing or reordering Desktops doesn't send layouts to the wrong place.
- **Puts windows back on the right Desktop.** "Restore windows to their Spaces" moves windows that macOS shuffled onto the wrong Desktop back where they belong (needs yabai, see below).
- **Restores after a restart.** When PixlPut starts within 15 minutes of boot, it waits for relaunching apps to settle, waits for unlock, then restores every window to its Desktop and position. It repeats the restore for apps that open late, for up to 10 minutes.
- **Only saves when you ask.** The saved layout changes only when you click **Capture now**. Moving a window afterwards doesn't overwrite anything.
- **Keeps history.** Older captures are kept, and **Restore from history…** lets you go back to one.
- **Stays local.** No account, no telemetry, no analytics. The only network call is the update check.

## Supported configuration

PixlPut is developed on, and only tested on, this setup:

| | |
|---|---|
| Mac | Apple Silicon, macOS 26.2 |
| Display | Samsung Odyssey G9, driven as two logical 3840×2160 displays |
| Mission Control | **"Displays have separate Spaces" turned off** (`defaults read com.apple.spaces spans-displays` returns `1`) |

With "Displays have separate Spaces" turned off, macOS keeps a single set of Desktops that spans every display. PixlPut relies on that: the code that maps a Desktop to a display assumes there is only one set. On any other configuration, including the macOS default of separate Spaces per display, PixlPut refuses to do cross-Desktop restores and says so, rather than guessing and scattering your windows. The reasoning is in [ADR-0003](roadmap/arch/decisions/0003-single-hardware-target-and-oss.md).

Per-Desktop restore (position and size on the Desktop you're looking at) doesn't depend on this, but it has also only been tested on the setup above.

## Requirements

**Always:**

- macOS 14 Sonoma or later.
- The **Accessibility** permission. PixlPut asks for it on first launch; macOS requires it for any app that reads or moves other apps' windows.

**To move windows between Desktops, and for restore after a restart:**

- [yabai](https://github.com/asmvik/yabai), built from the [vendored fork](#yabai) in this repo.
- **System Integrity Protection partially disabled**, so yabai's scripting addition can load into Dock. On Apple Silicon this also needs the `-arm64e_preview_abi` boot argument. Follow yabai's guide: [Disabling System Integrity Protection](https://github.com/asmvik/yabai/wiki/Disabling-System-Integrity-Protection).

macOS gives apps no public way to move another app's window to a different Desktop. Every in-process approach was measured and refused by the window server (details in [ADR-0002](roadmap/arch/decisions/0002-cross-space-relocation-via-process-assignment.md) and the [changelog](CHANGELOG.md)). yabai works because its scripting addition runs inside Dock, which owns the windows.

**What still works without yabai:**

- Capture, and restore of position and size on each Desktop, including automatic restore on wake.
- "Restore windows to their Spaces" falls back to moving whole apps: every window of an app moves together, and an app whose windows are spread across several Desktops is left where it is.
- Restore after a restart can't put windows back on other Desktops.

**Optional permissions:**

- **Automation**, per app, only if you turn on "Identify individual browser/editor windows". PixlPut uses it to ask browsers which tab each window shows.
- **Screen Recording**, only if you turn on per-Desktop thumbnails, behind an explicit consent screen.

## Install

There are no prebuilt releases yet, so install by building from source.

```sh
git clone --recurse-submodules https://github.com/aaronscribner/pixl-put.git
cd pixl-put
./scripts/build-app.sh
```

`build-app.sh`:

1. Builds yabai from `vendor/yabai`, signs it, and installs it as `/Applications/Utilities/yabai.app`. Set `SKIP_YABAI=1` to skip this.
2. Builds `PixlPut.app` and signs it if a matching Developer ID certificate is in your keychain (see [Signing](#signing)). Otherwise it leaves the app unsigned.
3. Runs `scripts/install-app.sh`, which quits any running PixlPut, copies the app to `/Applications/PixlPut.app`, registers a launch agent so it opens at every login, and starts it. Set `SKIP_INSTALL=1` to leave the app in `build/`.

On first launch, grant Accessibility when prompted. The PixlPut icon appears in the right side of the menu bar.

The login launch agent appears in System Settings → General → Login Items under "Allow in the Background". It's needed for restore after a restart: something has to start PixlPut at boot.

### yabai

Only needed for moving windows between Desktops. After SIP is configured:

```sh
./scripts/setup-yabai.sh
```

This asks for your password once and:

- writes a sudoers rule so `yabai --load-sa` can run at boot without a password. The rule is pinned to the binary's hash, so **re-run the script after any yabai rebuild**, or the scripting addition silently fails to load at the next boot.
- creates or updates `~/.yabairc` to load the scripting addition and keep every window floating, so yabai doesn't start tiling your desktop.
- points yabai's launch agent at the installed binary.

Then add `/Applications/Utilities/yabai.app` under System Settings → Privacy & Security → Accessibility. When yabai is signed with a Developer ID, the grant survives rebuilds; an unsigned build has to be re-approved after every rebuild.

PixlPut looks for yabai at `/Applications/Utilities/yabai.app` first. The fork exists because stock yabai tracks no windows at all when "Displays have separate Spaces" is off; the [1.1.0 changelog](CHANGELOG.md) has the details.

## Using PixlPut

1. Arrange your windows on each Desktop.
2. On each Desktop, click **Capture now** in the menu bar. Stay on the Desktop for a few seconds; PixlPut refuses the capture if you switch away before it finishes, rather than file it under the wrong Desktop.
3. Carry on. After sleep, wake or a display change, the Desktop on screen is restored straight away, and each other Desktop the first time you visit it after that wake. Later visits leave windows alone until the next wake.

### Menu

| Item | What it does |
|---|---|
| **Capture now** | Saves the layout of the Desktop on screen. |
| **Restore now** | Applies the saved layout of the Desktop on screen. |
| **Restore windows to their Spaces** | Moves windows on every Desktop back to their saved Desktop and position. |
| **Restore from history…** | Picks an older capture to restore. |
| **Auto-restore on Space switch & wake** | Turns automatic restore on or off. |
| **Settings…** | See below. |
| **Set up deep identity…** | Walks through the per-app Automation permissions. |
| **Check for updates…** | Checks for a new release. |

### Settings

- **General:** permissions status, "Auto-restore on Space switch & wake", "Restore after a restart", and how many history snapshots to keep.
- **Identity & Apps:** "Identify individual browser/editor windows" (off by default), per-Desktop thumbnails (off by default), and a summary of how each kind of app is recognized.
- **Updates:** automatic update checks.
- **Diagnostics:** recent sleep and wake times, and buttons to open the snapshots and logs folders.

## How windows are recognized

Each saved window records the app and an identity. While an app keeps running, PixlPut matches its windows exactly by window ID. After the app or the Mac restarts, window IDs are reissued, so it falls back to these rules:

| Apps | Matched by |
|---|---|
| Brave, Edge, Chrome, Arc, Safari | The open tab (needs "Identify individual browser/editor windows") |
| VS Code, Cursor, VSCodium, Windsurf, VS Code Insiders, JetBrains IDEs, Xcode | The workspace or project |
| Terminal, TextEdit, Preview and other document apps | The folder or document |
| Everything else (Teams, Outlook, Messages, Firefox, Slack, …) | An exact window title that's unique on both sides, or the app's only window |

When an app has several windows PixlPut can't tell apart, it leaves them where they are instead of guessing, and the restore message says so. It never pairs windows by list order: that order changes whenever an app restarts or a window is focused.

**Finder is never captured or restored.** Finder reopens its own windows on their Desktops after a restart, and a second restore would only fight it.

## Privacy

- Snapshots hold window positions, sizes, Desktops, app bundle IDs and window titles. With deep identity on, they also hold the tab URL, workspace or document each window shows.
- Everything stays in `~/Library/Application Support/DisplayMaid-Next/`. Nothing is uploaded.
- The only network call is the Sparkle update check, which sends nothing beyond a User-Agent. That rule is written into the project [constitution](roadmap/product/constitution.md) (§IV): any new network endpoint needs an amendment.
- No analytics, no crash reporting, no third-party SDKs besides [Sparkle](https://sparkle-project.org).

## Files and logs

| Path | Contents |
|---|---|
| `~/Library/Application Support/DisplayMaid-Next/snapshots/` | Saved layouts, one file per display configuration and Desktop, plus history and optional thumbnails |
| `~/Library/Application Support/DisplayMaid-Next/logs/diagnostic.log` | Plain-text trace of every capture and restore decision; the previous runs are kept as `diagnostic.1.log` and so on |
| `/Applications/PixlPut.app` | The installed app |
| `~/Library/LaunchAgents/co.cerebraljuice.pixlput.login.plist` | Opens PixlPut at login |

(`DisplayMaid-Next` is the project's earlier name; the folder keeps it so existing layouts aren't lost.)

To stream the unified log as well:

```sh
/usr/bin/log stream --predicate 'subsystem == "co.cerebraljuice.pixlput"' --info
```

To remove all saved data, quit PixlPut and delete the `DisplayMaid-Next` folder.

## Troubleshooting

The diagnostic log is the first place to look; every skip and refusal is written there with a reason. Useful lines to search for: `BLOCKED`, `REFUSED`, `REFUSE-SAVE`, `did not land`, `yabai --space failed`, `window query failed`, `still locked`.

**Accessibility shows as missing even though PixlPut is listed.** Unsigned builds get a new code identity on every rebuild, so the existing entry no longer matches. Turn PixlPut off in Privacy & Security → Accessibility, wait a second, and turn it back on.

**"Restore windows to their Spaces" says yabai isn't running.** Run `./scripts/setup-yabai.sh` and check yabai is approved under Accessibility. If you rebuilt yabai, re-run the setup script: the sudoers rule is pinned to the old binary's hash.

**"Unsupported display/Spaces configuration".** "Displays have separate Spaces" is on. See [Supported configuration](#supported-configuration).

**Some windows weren't moved, "couldn't tell these windows apart".** The app has several windows with no identity PixlPut can use after a restart. For browsers, turn on "Identify individual browser/editor windows". Otherwise, give the windows distinct titles where the app allows it.

**A capture was refused because the display left the Desktop.** Capture again and stay on the Desktop until it finishes.

**After adding or removing Desktops, a Desktop has no layout.** Layouts belong to a specific Desktop. A newly created Desktop needs its own capture.

## Building from source

**Prerequisites:** Xcode 15.4 or later (Swift 5.10), macOS 14 or later, and `git submodule update --init --recursive` if you didn't clone with `--recurse-submodules`.

```sh
swift build            # debug build
swift test             # unit tests
./scripts/build-app.sh          # debug .app bundle, installed to /Applications
./scripts/build-app.sh release  # release configuration
```

Environment variables for `build-app.sh`:

| Variable | Effect |
|---|---|
| `SKIP_YABAI=1` | Don't build or install yabai |
| `SKIP_INSTALL=1` | Leave the bundle in `build/`; don't install, register at login, or relaunch |
| `SIGN_IDENTITY="…"` | Codesigning identity to use; `SIGN_IDENTITY=""` builds unsigned |

### Signing

The scripts default to the maintainer's Developer ID. If you don't have that certificate, the build is left unsigned automatically. Unsigned builds work, but macOS forgets their Accessibility grant on every rebuild (see [Troubleshooting](#troubleshooting)). If you have your own Developer ID Application certificate, pass it in:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build-app.sh
```

`scripts/build-yabai.sh` takes the same variable.

## Releasing

Releases are Developer ID signed, notarized and stapled:

```sh
IDENTITY="Developer ID Application: Your Name (TEAMID)" \
KEYCHAIN_PROFILE="AC_PASSWORD" \
./scripts/release-app.sh
```

`KEYCHAIN_PROFILE` is a profile saved once with `xcrun notarytool store-credentials`. The script signs every nested Sparkle component inside-out (never with `--deep`), notarizes, and staples the ticket.

`scripts/sparkle-release.sh` then zips the app, signs the zip with the Sparkle EdDSA key, and writes the `<item>` entry for the appcast.

Auto-update isn't live yet. `SUPublicEDKey` in [Resources/Info.plist](Resources/Info.plist) is still a placeholder, and the `SUFeedURL` host isn't set up. Until both are, "Check for updates…" can't find releases.

## Project layout

```
App/
  App/            App lifecycle, permissions bootstrap, entry point
  Core/           PixlPutCore library: everything testable
    Accessibility/  AX client and window eligibility
    Displays/       Display fingerprints and configuration IDs
    Identity/       Window identity resolution and per-app providers
    Screenshots/    Optional per-Desktop thumbnails
    Snapshot/       Capture engine, snapshot store, restorer, matching
    Spaces/         Space resolution, private CGS wrappers, native window query, yabai backend
    Triggers/       Sleep/wake/idle/display watchers, debouncing, boot detection
  Infra/          Paths, logging, Sparkle updates
  MenuBar/        Menu bar controller, onboarding, deep-identity wizard, restore picker
  Settings/       Settings window
Tests/            XCTest suite for PixlPutCore
Resources/        Info.plist and entitlements
scripts/          Build, install, release, yabai setup, diagnostics probes
vendor/yabai/     yabai fork (git submodule)
marketing/        Project website (Astro)
roadmap/          Product docs, architecture model and decision records
```

## Design documents

- [Vision](roadmap/product/vision.md): what PixlPut is for and why
- [Constitution](roadmap/product/constitution.md): the principles every change is checked against, including the network rule
- [Spec 001: core window memory](roadmap/product/001-core-window-memory/spec.md)
- Architecture decisions:
  - [ADR-0001](roadmap/arch/decisions/0001-private-cgs-for-spaces.md): using private CoreGraphics Services calls for Spaces
  - [ADR-0002](roadmap/arch/decisions/0002-cross-space-relocation-via-process-assignment.md): how windows are moved between Spaces
  - [ADR-0003](roadmap/arch/decisions/0003-single-hardware-target-and-oss.md): one supported hardware configuration; open source
- [Changelog](CHANGELOG.md): what changed in each release, with the measurements behind the fixes

PixlPut uses undocumented macOS APIs (CoreGraphics Services) for Space information. That's why it isn't, and can't be, on the Mac App Store, and why a macOS update can break it.

## Contributing

Issues and pull requests are welcome, with one caveat: support for configurations other than the [supported one](#supported-configuration) is a deliberate non-goal for now. A fix that makes another setup work without risking the supported one is welcome; a change that trades correctness on the supported setup for generality isn't.

Before opening a pull request:

- Run `swift test` and make sure everything passes.
- Add a test for the behaviour you changed, in `Tests/`.
- Check the change against the [constitution](roadmap/product/constitution.md). In particular, add no network calls.
- Add an entry under `[Unreleased]` in [CHANGELOG.md](CHANGELOG.md).

The `agents/`, `.claude/` and `.azure-pipelines/` folders are the maintainer's AI-assisted development tooling. They aren't needed to build, test or contribute.

## Acknowledgements

- [yabai](https://github.com/asmvik/yabai), for the only working way to move another app's windows between Spaces. The vendored fork lives at [aaronscribner/yabai](https://github.com/aaronscribner/yabai).
- [Sparkle](https://sparkle-project.org) for updates.

## License

TBD.
