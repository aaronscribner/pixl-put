# DisplayMaid-Next — Product Vision

## One-liner

A macOS menu bar utility that remembers where every window was — including
*which* window — and puts each one back where it belongs when the Mac wakes up.

## Who it's for

Power users on macOS 14+ who run a desk-and-go workflow with one or more
external displays, keep many windows of the same app open simultaneously
(multiple browser windows, several VS Code workspaces, two browser profiles),
and lose ten minutes a day re-laying-out their workspace after a sleep cycle,
a dock/undock, or a screen-saver wake.

This is not a tiling window manager. It is not a launcher. It is a
restore-state utility for people whose workflow already works — when their
windows are where they put them.

## The problem with existing tools

Existing save/restore utilities (DisplayMaid included) treat all instances of
an app as interchangeable. Restore four Brave windows and you get four Brave
windows somewhere on the screen — but window A might be where window C was,
and the user has to manually shuffle them. The promise of "restore my setup"
is broken the moment more than one window of an app exists, which for the
target user is always.

The underlying cause: window identity is resolved by title or ordinal, both
of which are unstable. Titles drift as tabs change; ordinals depend on launch
order which the OS does not preserve across sleep.

## The DisplayMaid-Next principle

**Window identity is layered, strongest signal first.** A window is identified
by the strongest stable signal we can extract:

1. Document path (the file the window is editing)
2. App-specific deep identity (browser tab URL set, editor workspace path,
   terminal working directory)
3. Stable title-derived fingerprint
4. Ordinal fallback

Title-only is never the primary strategy. Adding support for a new app means
adding a new identity provider, not weakening the existing layers.

This is the entire reason the product exists. See
[`constitution.md`](./constitution.md) §II.

## What success looks like

A user with four Brave windows, three VS Code workspaces, and two terminals,
working across a laptop and one external monitor:

- Closes the lid. Goes home. Opens the lid on the couch — the windows are
  arranged for laptop-only work.
- Returns to the desk. Plugs in the external monitor. The windows are
  arranged for desk work, with each Brave window back on the display and
  frame it was on yesterday, identified by its specific tab set.
- Never opens the app's UI. Never touches a menu. Notices the product only
  when it is missing.

## What we explicitly do not build

These are not v1 trade-offs — they are out of scope for the product, forever
or until reconsidered with a strong reason:

- **No cloud sync.** Snapshots stay on-device. A user-initiated export
  feature may be added later, but there is no service, no account, no
  background sync. See constitution §IV.
- **No telemetry.** Ever. No analytics, no usage metrics, no crash-reporter
  callbacks. Crash reports are local files the user chooses to share.
- **No window arrangement / tiling features.** We restore arrangements the
  user already made. We do not create them.
- **No Mac App Store distribution.** Direct distribution with notarized
  `.app` + Sparkle is a non-goal-of-the-store decision, not a step toward
  it. The store's sandboxing forbids the AX-driven workflow.
- **No Windows or Linux build.** Native macOS only. See constitution §I.
- **No iOS / iPadOS companion app.** Cross-device is out of scope.
- **No support for macOS 13 or earlier.** v1 baseline is macOS 14 Sonoma.

## Distribution and trust model

- Distributed as a Developer-ID-signed, notarized `.app`, Hardened-Runtime
  enabled. Updates via Sparkle 2.x with EdDSA signature verification.
- Private CoreGraphics symbols (`CGSCopyManagedDisplaySpaces`,
  `CGSGetActiveSpace`) are used where they materially improve correctness,
  isolated to a single file with a documented graceful-degradation path.
- The only network traffic under default settings is the Sparkle appcast
  fetch. Verifiable by 24-hour Little Snitch / Charles capture (see
  spec.md SC-007).
