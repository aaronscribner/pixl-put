import XCTest
@testable import PixPutCore

final class SnapshotStoreTests: XCTestCase {

    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pixput-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // T017 — write/read round-trip
    func test_snapshotStore_whenSaveThenLoadLatest_thenReturnsEqualSnapshot() throws {
        let store = SnapshotStore(directory: tempDir)
        let snap = SnapshotCodecTests.makeFixtureSnapshot()
        try store.save(snap)
        let loaded = try store.loadLatest(forConfigurationID: snap.displayConfigurationID)
        XCTAssertEqual(loaded, snap)
    }

    // T017 — historyLimit=3 retains 3 generations including current
    func test_snapshotStore_whenSavingPastLimit_thenOldestIsDropped() throws {
        // historyLimit is now driven by UserDefaults, read live on every save.
        UserDefaults.standard.set(3, forKey: SnapshotStore.historyLimitDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: SnapshotStore.historyLimitDefaultsKey) }
        let store = SnapshotStore(directory: tempDir)
        let base = SnapshotCodecTests.makeFixtureSnapshot()
        // 5 distinct snapshots, distinguished by `id`
        var ids: [UUID] = []
        for i in 0..<5 {
            let id = UUID()
            ids.append(id)
            let s = Snapshot(
                id: id,
                name: "gen-\(i)",
                displayConfigurationID: base.displayConfigurationID,
                displays: base.displays,
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(i)),
                trigger: .manual,
                windows: base.windows
            )
            try store.save(s)
        }
        let history = try store.loadHistory(forConfigurationID: base.displayConfigurationID)
        XCTAssertEqual(history.count, 3, "Only historyLimit=3 entries should remain.")
        // Newest first: ids should be the last three saved, in reverse order.
        XCTAssertEqual(history.map(\.id), Array(ids.suffix(3).reversed()))
    }

    // Schema-version refusal (forward-compat)
    func test_snapshotStore_whenLoadingUnknownSchema_thenThrowsUnsupportedSchemaVersion() throws {
        let store = SnapshotStore(directory: tempDir)
        try store.bootstrap()
        let configID = "deadbeef"
        // Slot-0 file is a property list (the store migrated off JSON). Write
        // a fully-decodable snapshot plist with an unknown schemaVersion so
        // the version guard — not a decode failure — is what trips.
        let url = tempDir.appendingPathComponent("\(configID).plist")
        let valid = Snapshot(
            displayConfigurationID: configID,
            displays: [],
            capturedAt: Date(timeIntervalSince1970: 0),
            trigger: .manual,
            windows: []
        )
        let data = try PropertyListEncoder().encode(valid)
        var dict = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as! [String: Any]
        dict["schemaVersion"] = 999
        let bad = try PropertyListSerialization.data(
            fromPropertyList: dict, format: .binary, options: 0
        )
        try bad.write(to: url)
        XCTAssertThrowsError(try store.loadLatest(forConfigurationID: configID)) { error in
            guard case SnapshotStore.StoreError.unsupportedSchemaVersion(let v) = error else {
                return XCTFail("Wrong error: \(error)")
            }
            XCTAssertEqual(v, 999)
        }
    }

    // Mode 0o700 on bootstrap (constitution §IV — sensitive data)
    func test_snapshotStore_whenBootstrapping_thenDirectoryHasMode0o700() throws {
        let store = SnapshotStore(directory: tempDir)
        try store.bootstrap()
        let attrs = try FileManager.default.attributesOfItem(atPath: tempDir.path)
        let posix = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(posix, 0o700)
    }
}
