import Foundation

/// Persists snapshots as binary property-list files — **one per (display
/// configuration, Space)** — under `~/Library/Application Support/DisplayMaid-Next/snapshots/`.
/// Rotation caps history at `historyLimit` per Space.
///
/// File layout, keyed by the Desktop's UUID rather than its position:
///   snapshots/<configID>.space-<UUID>.plist        — that Desktop's current snapshot
///   snapshots/<configID>.space-<UUID>.<slot>.plist — its history, slot=1..historyLimit-1
///
/// Callers still speak Space positions. The store translates through
/// `spaceKeys` on every read and write, and rewrites each loaded entry's
/// `spaceIndex` to the Desktop's position now. Positions shift whenever a
/// Desktop is added, removed or reordered — measured 2026-09-14, a deleted and
/// a newly created Desktop sent two Spaces' layouts to the wrong Desktops.
/// Without Desktop UUIDs (no single managed Space set) files fall back to
/// `<configID>.space<N>.plist`; those position-keyed files are ignored whenever
/// UUIDs are available.
///
/// **Why one file per Space?** A capture can only see the Space it is standing
/// on: AX reports exactly the active Space's windows and nothing else (measured
/// on macOS 26.2 — 1 window per app where CG saw 7). Keying storage by Space
/// makes that limitation harmless instead of load-bearing:
///
/// - A capture writes one Space's file and cannot disturb another's, so there is
///   no wholesale replace and no additive cross-capture merge (and none of the
///   bloat that merge caused).
/// - Every entry is written by the AX pass while its Space was active, so every
///   entry carries full deep identity. No windowID-derived placeholder ordinals,
///   and therefore no two-numberings hazard in `ordinalInApp`.
/// - Moving a window between Spaces needs no reconciliation: re-capturing the
///   source Space rewrites it from what is actually there, so the moved window
///   simply stops being listed.
///
/// **Why binary plist?** ~30% smaller than pretty-printed JSON, slightly
/// faster to parse, and not casually `cat`-able. Fully debuggable with
/// `plutil -p file.plist`, or open in Xcode's Property List Editor.
/// NOT a security measure — just less inspector-friendly to a casual user.
public struct SnapshotStore: Sendable {
    public let directory: URL
    /// Desktop UUIDs in Space order — see the file-layout note above.
    public let spaceKeys: any SpaceKeying

    /// UserDefaults key for the total snapshot slot count (including the
    /// current slot 0). Settings UI writes this; the store reads it on
    /// every save so the limit updates live without restarting.
    ///
    /// Semantics: `historyLimit = 1` means "current only, no history".
    /// `historyLimit = 2` (default) means "current + 1 rotated history slot".
    /// Master snapshot lives outside this count and is unaffected.
    public static let historyLimitDefaultsKey = "PixlPut.snapshotHistoryLimit"
    public static let defaultHistoryLimit = 2
    public static let minHistoryLimit = 1
    public static let maxHistoryLimit = 50

    /// Current effective history cap, clamped to [min, max].
    public var historyLimit: Int {
        let raw = UserDefaults.standard.integer(forKey: Self.historyLimitDefaultsKey)
        let value = raw == 0 ? Self.defaultHistoryLimit : raw
        return min(Self.maxHistoryLimit, max(Self.minHistoryLimit, value))
    }

    /// FileManager.default is used inline — `FileManager` is not `Sendable`
    /// in modern Foundation, so we don't store it as a struct property.
    private var fileManager: FileManager { .default }

    public init(directory: URL, spaceKeys: any SpaceKeying = LiveSpaceKeys()) {
        self.directory = directory
        self.spaceKeys = spaceKeys
    }

    public enum StoreError: Error, Equatable {
        case directoryCreationFailed(String)
        case writeFailed(String)
        case readFailed(String)
        case decodeFailed(String)
        case unsupportedSchemaVersion(Int)
    }

    // MARK: - Bootstrap

    /// Ensure the snapshots directory exists with restrictive permissions.
    /// Mode 0o700 — the user's snapshots may contain browser tab URLs and
    /// document paths (sensitive per project constitution §IV).
    public func bootstrap() throws {
        if !fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw StoreError.directoryCreationFailed(error.localizedDescription)
            }
        }
    }

    // MARK: - Write

    /// Write a Space's snapshot. Rotates that Space's older files one slot
    /// down; drops the oldest when history limit is exceeded. Atomic per-file
    /// via `Data.write(to:options:.atomic)`.
    ///
    /// `spaceIndex` is the Space the snapshot was captured on. Only that
    /// Space's files are touched — every other Space is untouched by
    /// construction, which is the whole point of the layout.
    public func save(_ snapshot: Snapshot, spaceIndex: Int) throws {
        try bootstrap()
        let configID = snapshot.displayConfigurationID

        // Rotate existing files: N → N+1, dropping oldest when N+1 > limit.
        // Newest snapshot is the slot-0 file. Numbered files start at .1.
        let key = spaceKey(for: spaceIndex)
        try rotateForward(configID: configID, key: key)

        let url = self.url(for: configID, key: key, slot: 0)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        do {
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
    }

    /// Overwrite a Space's current snapshot without rotating history. For
    /// refreshes that change no placement (window titles), which should not
    /// push a real earlier layout out of history.
    public func replaceCurrent(_ snapshot: Snapshot, spaceIndex: Int) throws {
        try bootstrap()
        let url = self.url(for: snapshot.displayConfigurationID, key: spaceKey(for: spaceIndex), slot: 0)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        do {
            try encoder.encode(snapshot).write(to: url, options: .atomic)
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
    }

    /// Move current → .1, .1 → .2, … dropping the oldest file when it would exceed historyLimit-1.
    private func rotateForward(configID: String, key: String) throws {
        // Build list of existing slots (from highest backward), then rename
        // bottom-up so we never overwrite a file we still need to read.
        for slot in stride(from: historyLimit - 1, through: 0, by: -1) {
            let src = url(for: configID, key: key, slot: slot)
            let dst = url(for: configID, key: key, slot: slot + 1)
            guard fileManager.fileExists(atPath: src.path) else { continue }
            if slot + 1 >= historyLimit {
                // Drops the would-be-oldest entry.
                try? fileManager.removeItem(at: src)
            } else {
                if fileManager.fileExists(atPath: dst.path) {
                    try? fileManager.removeItem(at: dst)
                }
                try fileManager.moveItem(at: src, to: dst)
            }
        }
    }

    /// The file-name key for a Space position: `space-<UUID>` for the Desktop
    /// at that position when the window server reports Desktop UUIDs, else
    /// `space<N>`. A position past the end of the Desktop list gets a key no
    /// file has, so a stale position-keyed file can never answer for it.
    func spaceKey(for spaceIndex: Int) -> String {
        guard let uuids = spaceKeys.orderedSpaceUUIDs() else { return "space\(spaceIndex)" }
        guard uuids.indices.contains(spaceIndex) else { return "space-none-\(spaceIndex)" }
        return "space-\(uuids[spaceIndex])"
    }

    private func url(for configID: String, key: String, slot: Int) -> URL {
        if slot == 0 {
            return directory.appendingPathComponent("\(configID).\(key).plist")
        }
        return directory.appendingPathComponent("\(configID).\(key).\(slot).plist")
    }

    // MARK: - Slot inspection (for the restore picker)

    /// Returns metadata for every present rotation slot, newest first.
    /// Used by the Restore Picker UI to show the history list without
    /// having to fully decode each snapshot.
    public struct HistoryEntry: Sendable, Identifiable {
        public let slot: Int                 // 0 = current, 1..N = older
        public let capturedAt: Date
        public let windowCount: Int
        public let url: URL
        public var id: Int { slot }
    }

    public func listHistory(forConfigurationID configID: String, spaceIndex: Int) -> [HistoryEntry] {
        var result: [HistoryEntry] = []
        let key = spaceKey(for: spaceIndex)
        for slot in 0..<historyLimit {
            let u = url(for: configID, key: key, slot: slot)
            guard fileManager.fileExists(atPath: u.path) else { continue }
            // Cheap: just decode for the metadata we care about.
            guard let data = try? Data(contentsOf: u),
                  let snap = try? PropertyListDecoder().decode(Snapshot.self, from: data) else {
                continue
            }
            result.append(HistoryEntry(
                slot: slot,
                capturedAt: snap.capturedAt,
                windowCount: ExcludedApps.removing(from: snap).windows.count,
                url: u
            ))
        }
        return result
    }

    /// Load a specific historical slot directly. Used by the picker's
    /// "Apply" button after the user has chosen a row.
    public func load(forConfigurationID configID: String, spaceIndex: Int, slot: Int) throws -> Snapshot? {
        try loadFromSlot(configID: configID, spaceIndex: spaceIndex, slot: slot)
    }

    /// Permanently delete a specific slot.
    public func delete(forConfigurationID configID: String, spaceIndex: Int, slot: Int) {
        let u = url(for: configID, key: spaceKey(for: spaceIndex), slot: slot)
        try? fileManager.removeItem(at: u)
    }

    /// Every Space index that currently has a slot-0 config for this display
    /// configuration, ascending. Lets callers act on "all Spaces we know
    /// about" without assuming how many Spaces exist.
    public func spaceIndices(forConfigurationID configID: String) -> [Int] {
        if let uuids = spaceKeys.orderedSpaceUUIDs() {
            // Where the Desktops that have a layout are now. A deleted
            // Desktop's layout is not listed.
            return uuids.indices.filter { index in
                fileManager.fileExists(atPath: url(for: configID, key: "space-\(uuids[index])", slot: 0).path)
            }
        }
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        let prefix = "\(configID).space"
        var found: Set<Int> = []
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".plist") {
            // "<configID>.space<N>.plist" — history slots carry an extra
            // ".<slot>" component and are deliberately ignored here.
            let middle = name.dropFirst(prefix.count).dropLast(".plist".count)
            if let index = Int(middle) { found.insert(index) }
        }
        return found.sorted()
    }

    // MARK: - Read

    /// Load the most recent snapshot for one Space of a display configuration.
    /// Returns `nil` if that Space has never been captured.
    /// Throws `unsupportedSchemaVersion` if the file's `schemaVersion` is unknown.
    public func loadLatest(forConfigurationID configID: String, spaceIndex: Int) throws -> Snapshot? {
        try loadFromSlot(configID: configID, spaceIndex: spaceIndex, slot: 0)
    }

    /// All snapshots for one Space of a configuration (newest first).
    public func loadHistory(forConfigurationID configID: String, spaceIndex: Int) throws -> [Snapshot] {
        var result: [Snapshot] = []
        for slot in 0..<historyLimit {
            if let s = try? loadFromSlot(configID: configID, spaceIndex: spaceIndex, slot: slot) {
                result.append(s)
            }
        }
        return result
    }

    private func loadFromSlot(configID: String, spaceIndex: Int, slot: Int) throws -> Snapshot? {
        let url = self.url(for: configID, key: spaceKey(for: spaceIndex), slot: slot)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw StoreError.readFailed(error.localizedDescription) }
        return Self.placing(try decode(data), onSpace: spaceIndex)
    }

    private func decode(_ data: Data) throws -> Snapshot {
        do {
            let decoder = PropertyListDecoder()
            let snapshot = try decoder.decode(Snapshot.self, from: data)
            guard snapshot.schemaVersion == Snapshot.currentSchemaVersion else {
                throw StoreError.unsupportedSchemaVersion(snapshot.schemaVersion)
            }
            // Every restore path reads through here, so snapshots captured
            // before an app was excluded lose its windows without a re-capture.
            return ExcludedApps.removing(from: snapshot)
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.decodeFailed(error.localizedDescription)
        }
    }

    /// `snapshot` with every entry on `spaceIndex` — the Desktop's position
    /// now, which differs from capture time when Desktops were added, removed
    /// or reordered since. Cross-Space moves target this value.
    static func placing(_ snapshot: Snapshot, onSpace spaceIndex: Int) -> Snapshot {
        guard snapshot.windows.contains(where: { $0.spaceIndex != spaceIndex }) else { return snapshot }
        let windows = snapshot.windows.map { e in
            WindowEntry(
                bundleID: e.bundleID, identity: e.identity, ordinalInApp: e.ordinalInApp,
                displayFingerprintID: e.displayFingerprintID, spaceIndex: spaceIndex,
                frame: e.frame, isMinimized: e.isMinimized, isFullscreen: e.isFullscreen,
                capturedAt: e.capturedAt, windowID: e.windowID
            )
        }
        return Snapshot(
            id: snapshot.id, name: snapshot.name,
            displayConfigurationID: snapshot.displayConfigurationID,
            displays: snapshot.displays, capturedAt: snapshot.capturedAt,
            trigger: snapshot.trigger, windows: windows
        )
    }
}
