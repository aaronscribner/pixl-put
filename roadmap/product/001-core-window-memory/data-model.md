# Data Model: Core Window Memory

**Feature**: 001-core-window-memory | **Date**: 2026-05-23 |
**Spec**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md) |
**Research**: [research.md](./research.md)

Codable Swift type definitions for every entity in spec.md §Key Entities,
with JSON schema examples and notes on encoding choices. These types live
under `Core/` per the project tree in plan.md.

## Conventions

- Every entity is a `struct`, never a `class`, except where reference
  semantics are required (none in v1).
- Every entity is `Codable` with explicit `CodingKeys` enums — never
  implicit. Renaming a Swift field must not silently break on-disk
  snapshots.
- All persisted dates are ISO-8601 with fractional seconds (`.withInternetDateTime,
  .withFractionalSeconds`), encoded as strings.
- All persisted URLs are absolute file URLs or absolute web URLs,
  encoded as strings. Codable's default URL handling rejects relative
  paths, which is the behavior we want.
- The top-level snapshot file embeds a `schemaVersion: Int` (current: 1).
  A snapshot loader that encounters a version it doesn't recognize logs
  and skips that file rather than throwing.
- Optionals encode as missing keys, not `null`. This is the JSONEncoder
  default; we do not override.

## E-1 — `DisplayFingerprint`

A stable, port-order-independent ID for a single display. See research.md
§R-8.

```swift
struct DisplayFingerprint: Codable, Hashable {
    let id: String                  // hex SHA-256 prefix, 16 bytes
    let vendorID: UInt32
    let productID: UInt32
    let modelNumber: UInt32
    let serialNumber: UInt32        // low 24 bits only
    let displayUUID: String?        // diagnostic only, not part of id

    enum CodingKeys: String, CodingKey {
        case id, vendorID, productID, modelNumber, serialNumber, displayUUID
    }
}
```

JSON:

```json
{
  "id": "a8f3c0d12e8b4f01",
  "vendorID": 1552,
  "productID": 41218,
  "modelNumber": 41218,
  "serialNumber": 0,
  "displayUUID": "37D8832A-2D66-02CA-B9F7-1D4E9B2C7A11"
}
```

## E-2 — `Display`

A display as it exists in a configuration: a fingerprint plus the bounds
the OS placed it at in the global coordinate space.

```swift
struct Display: Codable, Hashable {
    let fingerprint: DisplayFingerprint
    let bounds: CGRectCodable
    let isPrimary: Bool
    let scaleFactor: CGFloat        // 1.0 for non-Retina, 2.0 for Retina

    enum CodingKeys: String, CodingKey {
        case fingerprint, bounds, isPrimary, scaleFactor
    }
}

struct CGRectCodable: Codable, Hashable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
}
```

JSON:

```json
{
  "fingerprint": { "id": "a8f3c0d12e8b4f01", "...": "..." },
  "bounds": { "x": 0, "y": 0, "width": 2560, "height": 1440 },
  "isPrimary": true,
  "scaleFactor": 2.0
}
```

`CGRect` does not conform to `Codable` directly without
`CodableCoreFoundation`, so we use `CGRectCodable`. Same pattern for
`CGPoint` and `CGSize` where they appear standalone (they don't in v1 —
every geometric value is a frame).

## E-3 — `DisplayConfiguration`

The set of displays attached at a moment in time, with a deterministic ID.

```swift
struct DisplayConfiguration: Codable, Hashable {
    let id: String                  // hex SHA-256 prefix of sorted display IDs
    let displays: [Display]         // sorted by fingerprint.id ascending
    let capturedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, displays, capturedAt
    }
}
```

JSON:

```json
{
  "id": "f4b2199d70a3c105",
  "displays": [
    { "fingerprint": { "id": "a8f3c0d12e8b4f01", "...": "..." }, "...": "..." },
    { "fingerprint": { "id": "c19fe2a44b1d0220", "...": "..." }, "...": "..." }
  ],
  "capturedAt": "2026-05-23T18:42:01.117Z"
}
```

Invariant (checked in the initializer): `displays` is sorted by
`fingerprint.id` and `id` equals the hash of that sorted list. Decoders
verify this and reject mismatches as corruption.

## E-4 — `WindowIdentity`

Tagged union over the layered identity strategies in constitution §II.
This is the most important data shape in the system.

```swift
enum WindowIdentity: Codable, Hashable {
    case documentPath(URL)
    case browserTabSet(hash: String, urls: [URL])
    case editorWorkspace(URL, confidence: Confidence)
    case terminalCWD(URL)
    case titleRegex(pattern: String, capturedValue: String)
    case ordinal(index: Int)

    enum Confidence: String, Codable { case verified, titleOnly }
}
```

The `hash` field on `browserTabSet` is the matching key at restore (see
research.md §R-3); `urls` is stored for the v1.x diff viewer. The two
must always agree — `hash == SHA256(sort(urls).join("\n"))[0..16]` —
checked on decode.

### Codable encoding for `WindowIdentity`

We encode as `{ "kind": "...", "value": { ... } }` rather than
ProtocolBuffers-style discriminated payloads or Swift's default
single-key-per-case shape. The reasons:

- `kind` is grep-able. Users inspecting their snapshots can find every
  `browserTabSet` entry with a single search.
- The `value` payload is uniform across kinds, which simplifies migration
  if a new identity kind is added in a future version.

```swift
extension WindowIdentity {
    private enum CodingKeys: String, CodingKey { case kind, value }

    private enum Kind: String, Codable {
        case documentPath, browserTabSet, editorWorkspace,
             terminalCWD, titleRegex, ordinal
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .documentPath(let url):
            try c.encode(Kind.documentPath, forKey: .kind)
            try c.encode(["url": url], forKey: .value)
        case .browserTabSet(let hash, let urls):
            try c.encode(Kind.browserTabSet, forKey: .kind)
            try c.encode(BrowserTabSetPayload(hash: hash, urls: urls),
                         forKey: .value)
        // ... one case per variant
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .documentPath:
            let p = try c.decode([String: URL].self, forKey: .value)
            guard let url = p["url"] else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value, in: c,
                    debugDescription: "documentPath missing url")
            }
            self = .documentPath(url)
        // ... one case per variant
        }
    }
}
```

JSON examples — one per variant:

```json
{ "kind": "documentPath",
  "value": { "url": "file:///Users/me/Documents/notes.md" } }

{ "kind": "browserTabSet",
  "value": {
    "hash": "1c4f8a902d5b6e34",
    "urls": [
      "https://docs.python.org/3/library/asyncio.html",
      "https://github.com/anthropics/claude-code",
      "https://news.ycombinator.com/"
    ]
  } }

{ "kind": "editorWorkspace",
  "value": {
    "url": "file:///Users/me/src/PixPut/",
    "confidence": "verified"
  } }

{ "kind": "terminalCWD",
  "value": { "url": "file:///Users/me/src/PixPut/" } }

{ "kind": "titleRegex",
  "value": {
    "pattern": "^(.+?) — Visual Studio Code$",
    "capturedValue": "PixPut"
  } }

{ "kind": "ordinal",
  "value": { "index": 2 } }
```

## E-5 — `WindowEntry`

A single window's recorded state.

```swift
struct WindowEntry: Codable, Hashable {
    let bundleID: String
    let identity: WindowIdentity
    let displayID: String           // == Display.fingerprint.id
    let spaceID: SpaceReference?    // nil if Space resolution unavailable
    let frame: CGRectCodable        // global coordinates, points
    let isMinimized: Bool
    let isFullscreen: Bool
    let title: String               // diagnostic only, never used for identity
    let capturedAt: Date

    enum CodingKeys: String, CodingKey {
        case bundleID, identity, displayID, spaceID,
             frame, isMinimized, isFullscreen, title, capturedAt
    }
}

struct SpaceReference: Codable, Hashable {
    let index: Int                  // ordinal among Spaces on this display
    let id64: UInt64                // private CGS Space ID
    let uuid: String?               // private CGS Space UUID, if available
}
```

JSON:

```json
{
  "bundleID": "com.brave.Browser",
  "identity": {
    "kind": "browserTabSet",
    "value": {
      "hash": "1c4f8a902d5b6e34",
      "urls": ["https://docs.python.org/3/library/asyncio.html", "..."]
    }
  },
  "displayID": "a8f3c0d12e8b4f01",
  "spaceID": {
    "index": 1,
    "id64": 4294967312,
    "uuid": "9F2A1C4B-..."
  },
  "frame": { "x": 100, "y": 200, "width": 1280, "height": 800 },
  "isMinimized": false,
  "isFullscreen": false,
  "title": "asyncio — Python 3.13 — Brave",
  "capturedAt": "2026-05-23T18:42:01.117Z"
}
```

Notes:

- `title` is stored only for human-readable debug and for the v1.x diff
  viewer. The codepath that resolves a snapshot entry to a live window
  never consults this field. Constitution §II would be violated if it
  did.
- `spaceID` may be nil; see research.md §R-6 graceful-degradation path.
- `frame` is in global (logical) point coordinates. Per-display scale
  factor is *not* applied here — restore uses the same logical
  coordinate space.

## E-6 — `Snapshot`

An ordered collection of `WindowEntry` records for a single capture
event.

```swift
struct Snapshot: Codable, Hashable {
    let id: UUID                    // unique snapshot ID
    let displayConfigurationID: String
    let trigger: TriggerKind
    let entries: [WindowEntry]      // sorted by (bundleID, identity.kind, ...)
    let capturedAt: Date
    let name: String?               // user-supplied, set by US5 only

    enum CodingKeys: String, CodingKey {
        case id, displayConfigurationID, trigger,
             entries, capturedAt, name
    }
}

enum TriggerKind: String, Codable {
    case screensaverStart, displaySleep, screenLock,
         manual, wake, displayConfigChange
}
```

JSON:

```json
{
  "id": "D4F7C612-7F2A-4B0E-9C13-2F8E0A1B6E55",
  "displayConfigurationID": "f4b2199d70a3c105",
  "trigger": "screensaverStart",
  "entries": [
    { "bundleID": "com.brave.Browser", "...": "..." },
    { "bundleID": "com.microsoft.VSCode", "...": "..." }
  ],
  "capturedAt": "2026-05-23T18:42:01.117Z",
  "name": null
}
```

`entries` is sorted deterministically to make snapshot diffs noise-free:
by `bundleID` ascending, then by a stable ordering on `identity` (by
`kind` first, then by the variant's principal field). This is enforced in
`Snapshot.init` and verified on decode.

## E-7 — `SnapshotFile`

The actual top-level shape persisted per display configuration. Wraps a
bounded history of `Snapshot`.

```swift
struct SnapshotFile: Codable {
    let schemaVersion: Int          // current: 1
    let displayConfiguration: DisplayConfiguration
    let history: [Snapshot]         // newest first; len <= maxHistory
    let writtenAt: Date

    enum CodingKeys: String, CodingKey {
        case schemaVersion, displayConfiguration, history, writtenAt
    }
}
```

File path:

```
~/Library/Application Support/DisplayMaid-Next/snapshots/<configurationID>.json
```

JSON skeleton:

```json
{
  "schemaVersion": 1,
  "displayConfiguration": {
    "id": "f4b2199d70a3c105",
    "displays": [ { "...": "..." } ],
    "capturedAt": "2026-05-23T18:00:00.000Z"
  },
  "history": [
    { "id": "...", "trigger": "screensaverStart", "...": "..." }
  ],
  "writtenAt": "2026-05-23T18:42:01.200Z"
}
```

Invariants:

- `history[0]` is always the most recent snapshot. Auto-restore on wake
  reads `history[0]`.
- `history.count <= preferences.maxHistoryPerConfig` (default 10). On
  capture, after appending, the tail is trimmed.
- `displayConfiguration.id == filename without ".json"`. Decoders
  enforce.
- `displayConfiguration` is the configuration *at the time the file was
  first created*. Subsequent captures may re-verify but do not rewrite
  this field (rewriting would change the file's identity).

## E-8 — `Preferences`

User preferences, persisted as a single JSON file, intentionally not in
`UserDefaults` so users can inspect / portage them.

```swift
struct Preferences: Codable {
    let schemaVersion: Int                  // current: 1
    let autoCaptureEnabled: Bool            // default true
    let autoRestoreEnabled: Bool            // default true
    let maxHistoryPerConfig: Int            // default 10, range 1...50
    let relaunchMissingApps: Bool           // default false (v1)
    let restoreMinimized: Bool              // default false (v1)
    let spaceSwitchKeyChord: KeyChord       // default ctrl+arrow
    let perBundleOverrides: [String: BundleOverride]
    let lastModified: Date
}

struct KeyChord: Codable {
    let modifiers: Set<CGEventFlags.RawValue>
    let keyCode: UInt16
}

struct BundleOverride: Codable {
    let bundleID: String
    let providerStrategy: ProviderStrategy
    let excluded: Bool                      // skip entirely

    enum ProviderStrategy: String, Codable {
        case auto                           // default: try all layers
        case ordinalOnly                    // skip deep identity even if available
        case titleOnly                      // skip deep identity, use title
    }
}
```

File path: `~/Library/Application Support/DisplayMaid-Next/preferences.json`.

JSON:

```json
{
  "schemaVersion": 1,
  "autoCaptureEnabled": true,
  "autoRestoreEnabled": true,
  "maxHistoryPerConfig": 10,
  "relaunchMissingApps": false,
  "restoreMinimized": false,
  "spaceSwitchKeyChord": {
    "modifiers": [262144],
    "keyCode": 124
  },
  "perBundleOverrides": {
    "com.apple.Terminal": {
      "bundleID": "com.apple.Terminal",
      "providerStrategy": "titleOnly",
      "excluded": false
    }
  },
  "lastModified": "2026-05-23T18:42:01.117Z"
}
```

## E-9 — `LogEntry`

For completeness — what gets written to the rotating log files under
`logs/`. Not a persistence target the rest of the system reads back, but
defining the shape now keeps log analysis consistent.

```swift
struct LogEntry: Codable {
    let timestamp: Date
    let level: LogLevel
    let subsystem: String           // e.g. "Snapshot", "Identity.Browser"
    let message: String
    let context: [String: String]?  // optional structured fields

    enum LogLevel: String, Codable {
        case debug, info, notice, warning, error, fault
    }
}
```

## Entity relationships

```text
SnapshotFile
 ├── displayConfiguration : DisplayConfiguration
 │     └── displays : [Display]
 │           └── fingerprint : DisplayFingerprint
 └── history : [Snapshot]
       └── entries : [WindowEntry]
             ├── identity : WindowIdentity  (tagged union)
             ├── displayID : String  (-> Display.fingerprint.id)
             └── spaceID : SpaceReference?
```

One `SnapshotFile` per `DisplayConfiguration`. One `Snapshot` per capture
event. One `WindowEntry` per captured window. `WindowEntry.displayID`
references `Display.fingerprint.id` within the same file's
`displayConfiguration.displays` — verified on load; an entry whose
`displayID` is absent from the configuration is dropped with a log line.

## Migration policy

`schemaVersion` is incremented when an incompatible change is made to any
persisted shape (`SnapshotFile` or `Preferences`). The loader:

- Reads `schemaVersion` first via `JSONSerialization` (cheap probe).
- If the version is the current one, decodes via `JSONDecoder`.
- If older, runs the registered migration from that version up to
  current, in sequence.
- If newer (user downgraded the app), logs and refuses to load that file
  — does NOT overwrite. Better to lose one config's snapshot than to
  destroy a user's setup.

For v1 there is only `schemaVersion: 1`; the migration framework is in
place but has no registered migrations. The first migration is expected
when v1.x adds per-app rules expansion to `BundleOverride`.
