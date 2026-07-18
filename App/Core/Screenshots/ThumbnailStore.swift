import Foundation

/// Persists per-Space JPEG thumbnails next to the snapshot files.
///
/// Filename layout (mirrors snapshot rotation):
///   snapshots/<configID>.space<N>.thumb.jpg          — current (slot 0)
///   snapshots/<configID>.<slot>.space<N>.thumb.jpg   — rotated (slot ≥ 1)
///   snapshots/<configID>.master.space<N>.thumb.jpg   — master snapshot
///
/// Thumbnails rotate in lockstep with snapshots: when SnapshotStore rotates
/// `<id>.plist → <id>.1.plist`, this store rotates the matching thumbnails.
/// Whether rotated thumbnails are kept or dropped is controlled by
/// `MenuBarStatusModel.enableSnapshotHistoryThumbnails` — passed in as
/// `preserveRotated` to `rotateForward`.
public struct ThumbnailStore: Sendable {
    public let directory: URL

    private var fileManager: FileManager { .default }

    public init(directory: URL) {
        self.directory = directory
    }

    public enum StoreError: Error, Equatable {
        case writeFailed(String)
        case readFailed(String)
    }

    // MARK: - Slot-keyed save / load / delete

    /// Save a JPEG. `slot == 0` is current, `slot ≥ 1` are rotated history.
    public func save(_ jpegData: Data, configID: String, spaceIndex: Int, slot: Int = 0) throws {
        let url = self.url(configID: configID, spaceIndex: spaceIndex, slot: slot)
        do {
            try jpegData.write(to: url, options: .atomic)
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
    }

    public func load(configID: String, spaceIndex: Int, slot: Int = 0) -> Data? {
        let url = self.url(configID: configID, spaceIndex: spaceIndex, slot: slot)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    public func delete(configID: String, spaceIndex: Int, slot: Int = 0) {
        let url = self.url(configID: configID, spaceIndex: spaceIndex, slot: slot)
        try? fileManager.removeItem(at: url)
    }

    /// Remove ALL thumbnails — used when the user revokes screenshot
    /// consent. Don't leave images on disk after the user opts out.
    public func deleteAll() {
        guard let contents = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in contents where name.contains(".thumb.jpg") {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Remove all rotated (slot ≥ 1) thumbnails for every config. Used
    /// when the user disables history thumbnails — keeps only slot 0.
    public func deleteAllRotatedThumbnails() {
        for location in listAllThumbnails() where location.slot >= 1 {
            try? fileManager.removeItem(at: location.url)
        }
    }

    public func url(configID: String, spaceIndex: Int, slot: Int = 0) -> URL {
        if slot == 0 {
            return directory.appendingPathComponent("\(configID).space\(spaceIndex).thumb.jpg")
        }
        return directory.appendingPathComponent("\(configID).\(slot).space\(spaceIndex).thumb.jpg")
    }

    // MARK: - Rotation

    /// Rotate all current (slot 0) thumbnails forward to slot 1, slot 1
    /// to slot 2, etc. — mirrors `SnapshotStore.rotateForward`. Call this
    /// AFTER `SnapshotStore.save` so the just-displaced snapshot's
    /// thumbnails follow it into the rotated slot.
    ///
    /// - Parameters:
    ///   - configID: which display configuration to rotate
    ///   - historyLimit: matches `SnapshotStore.historyLimit`; anything that
    ///     would exceed this is deleted instead of promoted
    ///   - preserveRotated: when true, slot 0 → slot 1 (etc.). When false,
    ///     slot 0 is simply deleted — used when the user has disabled the
    ///     "keep history thumbnails" option.
    public func rotateForward(configID: String, historyLimit: Int, preserveRotated: Bool) {
        let prefix = "\(configID)."
        let suffix = ".thumb.jpg"
        let entries = listAllThumbnails().filter {
            $0.url.lastPathComponent.hasPrefix(prefix) && $0.url.lastPathComponent.hasSuffix(suffix) &&
                isThumbnailForConfig($0.url.lastPathComponent, configID: configID)
        }

        if !preserveRotated {
            // Drop slot 0; also clean up any orphaned higher slots from a
            // previous "preserveRotated == true" period.
            for entry in entries {
                try? fileManager.removeItem(at: entry.url)
            }
            return
        }

        // Preserve: walk slots highest-first so we don't clobber a file
        // we're about to move.
        let sorted = entries.sorted { $0.slot > $1.slot }
        for entry in sorted {
            let newSlot = entry.slot + 1
            if newSlot >= historyLimit {
                try? fileManager.removeItem(at: entry.url)
                continue
            }
            let newURL = url(configID: configID, spaceIndex: entry.spaceIndex, slot: newSlot)
            try? fileManager.removeItem(at: newURL)
            try? fileManager.moveItem(at: entry.url, to: newURL)
        }
    }

    // MARK: - Enumeration

    public struct Location: Sendable {
        public let configID: String
        public let slot: Int
        public let spaceIndex: Int
        public let url: URL
    }

    /// Enumerate every thumbnail file in the directory, parsing the
    /// filename pattern. Skips `.master.` files — those live outside the
    /// rotating-history scheme and are managed separately.
    public func listAllThumbnails() -> [Location] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        var result: [Location] = []
        for name in names {
            guard name.hasSuffix(".thumb.jpg") else { continue }
            if name.contains(".master.") { continue }   // master is managed separately
            guard let parsed = parseThumbnailName(name) else { continue }
            result.append(Location(
                configID: parsed.configID,
                slot: parsed.slot,
                spaceIndex: parsed.spaceIndex,
                url: directory.appendingPathComponent(name)
            ))
        }
        return result
    }

    // MARK: - Filename parsing

    private struct ParsedName { let configID: String; let slot: Int; let spaceIndex: Int }

    /// Parse one of:
    ///   <configID>.space<N>.thumb.jpg            (slot 0)
    ///   <configID>.<slot>.space<N>.thumb.jpg     (slot ≥ 1)
    private func parseThumbnailName(_ name: String) -> ParsedName? {
        guard name.hasSuffix(".thumb.jpg") else { return nil }
        let trimmed = String(name.dropLast(".thumb.jpg".count))
        // `trimmed` is now `<configID>.space<N>` or `<configID>.<slot>.space<N>`.
        guard let spaceRange = trimmed.range(of: ".space", options: .backwards) else { return nil }
        let beforeSpace = String(trimmed[..<spaceRange.lowerBound])
        let spaceIndexStr = String(trimmed[spaceRange.upperBound...])
        guard let spaceIndex = Int(spaceIndexStr) else { return nil }
        // beforeSpace is either `<configID>` (slot 0) or `<configID>.<slot>` (slot ≥ 1).
        if let lastDot = beforeSpace.lastIndex(of: "."),
           let slot = Int(beforeSpace[beforeSpace.index(after: lastDot)...]) {
            let configID = String(beforeSpace[..<lastDot])
            return ParsedName(configID: configID, slot: slot, spaceIndex: spaceIndex)
        }
        return ParsedName(configID: beforeSpace, slot: 0, spaceIndex: spaceIndex)
    }

    private func isThumbnailForConfig(_ filename: String, configID: String) -> Bool {
        parseThumbnailName(filename)?.configID == configID
    }
}
