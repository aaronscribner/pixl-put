# Component: Core/Triggers

**Status**: Stub | **Layer**: Core

## Purpose

Subscribe to macOS idle / wake / display-reconfiguration events and route them through a debouncer to `Core/Snapshot` for capture or restore. Implements FR-005 through FR-008 (event sources + debounce windows).

## Event Sources

| Event | Source | Routes to |
|---|---|---|
| `com.apple.screensaver.didstart` | Distributed notification | Capture |
| `com.apple.screenIsLocked` | Distributed notification | Capture |
| `NSWorkspace.screensDidSleepNotification` | NSWorkspace | Capture |
| `NSWorkspace.didWakeNotification` | NSWorkspace | Restore |
| `CGDisplayRegisterReconfigurationCallback` | CoreGraphics | Restore (when configuration changes after wake) |

## Responsibilities

- `IdleTriggerWatcher` — subscribe to all three idle-signal sources; emit a single "idle" event per debounce window
- `WakeTriggerWatcher` — subscribe to wake + reconfiguration; emit a single "resume" event per debounce window
- `Debouncer` — generic event coalescer with configurable window (5s default per FR-007, FR-008)
- Honour `MenuBarStatusModel.isAutoCapturePaused` — drop idle events when paused (Story 2 acceptance #3)

## Boundaries

- Subscribes only; does NOT perform capture or restore directly
- Routes via typed publisher to `Core/Snapshot` and `Core/Spaces/SpaceResolver` (active Space at trigger time)
- Distributed notifications subscribed via `DistributedNotificationCenter.default()` only

## Dependencies

- `NSWorkspace`, `DistributedNotificationCenter` (public APIs)
- `Core/Displays/DisplayConfigWatcher` (configuration-change events)
- `Core/Snapshot/SnapshotEngine` (downstream)
- `Core/Snapshot/Restorer` (downstream)
- `MenuBar/MenuBarStatusModel` (pause state)

## Files (per plan.md)

- `Core/Triggers/IdleTriggerWatcher.swift`
- `Core/Triggers/WakeTriggerWatcher.swift`
- `Core/Triggers/Debouncer.swift`

## Constitution Alignment

- §I Native macOS — public NSWorkspace + CoreGraphics + distributed notification APIs
- §V Graceful degradation — events fire even without Automation grants; only Identity resolution downstream is affected
- §VII Performance — debouncer caps event rate, prevents thrashing on rapid sleep/wake cycles

## Open Questions

- Debounce window 5s vs different per event type — observe behaviour in beta.
- `displaySleepNotification` vs `screensDidSleepNotification` — confirm which fires first on Apple Silicon.
