import XCTest
@testable import PixlPutCore

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
        try store.save(snap, spaceIndex: 3)
        let loaded = try store.loadLatest(forConfigurationID: snap.displayConfigurationID, spaceIndex: 3)
        XCTAssertEqual(loaded, snap)
    }

    /// The property the whole per-Space layout exists for: a capture can only
    /// see the Space it is standing on, so writing one Space must not be able
    /// to disturb another. Under the previous single-file layout this was the
    /// wholesale-replace-vs-additive-merge dilemma; here it is structural.
    func test_snapshotStore_whenSavingOneSpace_thenOtherSpacesAreUntouched() throws {
        let store = SnapshotStore(directory: tempDir)
        let base = SnapshotCodecTests.makeFixtureSnapshot()
        let configID = base.displayConfigurationID

        let onSpace2 = Snapshot(name: "space-2", displayConfigurationID: configID,
                                displays: base.displays,
                                capturedAt: Date(timeIntervalSince1970: 100),
                                trigger: .manual, windows: base.windows)
        let onSpace5 = Snapshot(name: "space-5", displayConfigurationID: configID,
                                displays: base.displays,
                                capturedAt: Date(timeIntervalSince1970: 200),
                                trigger: .manual, windows: [])
        try store.save(onSpace2, spaceIndex: 2)
        try store.save(onSpace5, spaceIndex: 5)
        // Re-capture Space 2 with different contents — Space 5 must not move.
        try store.save(onSpace5, spaceIndex: 2)

        XCTAssertEqual(try store.loadLatest(forConfigurationID: configID, spaceIndex: 5)?.name, "space-5")
        XCTAssertEqual(try store.loadLatest(forConfigurationID: configID, spaceIndex: 2)?.name, "space-5")
        XCTAssertNil(try store.loadLatest(forConfigurationID: configID, spaceIndex: 0),
                     "a Space never captured has no config")
    }

    /// A window moved from Space 6 to Space 3 needs no reconciliation step:
    /// re-capturing Space 6 rewrites that file from what is actually there, so
    /// the moved window simply stops being listed.
    func test_snapshotStore_whenSourceSpaceRecaptured_thenMovedWindowIsNoLongerListed() throws {
        let store = SnapshotStore(directory: tempDir)
        let base = SnapshotCodecTests.makeFixtureSnapshot()
        let configID = base.displayConfigurationID

        let before = Snapshot(displayConfigurationID: configID, displays: base.displays,
                              capturedAt: Date(timeIntervalSince1970: 100),
                              trigger: .manual, windows: base.windows)
        try store.save(before, spaceIndex: 6)
        XCTAssertFalse(try XCTUnwrap(store.loadLatest(forConfigurationID: configID, spaceIndex: 6)).windows.isEmpty)

        // User moved the window away, then re-captured Space 6.
        let after = Snapshot(displayConfigurationID: configID, displays: base.displays,
                             capturedAt: Date(timeIntervalSince1970: 300),
                             trigger: .manual, windows: [])
        try store.save(after, spaceIndex: 6)
        XCTAssertTrue(try XCTUnwrap(store.loadLatest(forConfigurationID: configID, spaceIndex: 6)).windows.isEmpty)
    }

    func test_snapshotStore_spaceIndices_listsOnlyCapturedSpacesAscending() throws {
        let store = SnapshotStore(directory: tempDir)
        let base = SnapshotCodecTests.makeFixtureSnapshot()
        let configID = base.displayConfigurationID
        for index in [5, 0, 3] { try store.save(base, spaceIndex: index) }
        XCTAssertEqual(store.spaceIndices(forConfigurationID: configID), [0, 3, 5])
        XCTAssertEqual(store.spaceIndices(forConfigurationID: "other-config"), [])
    }

    func test_snapshotStore_fileNameCarriesTheSpace() throws {
        let store = SnapshotStore(directory: tempDir)
        let snap = SnapshotCodecTests.makeFixtureSnapshot()
        try store.save(snap, spaceIndex: 4)
        let names = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertTrue(names.contains("\(snap.displayConfigurationID).space4.plist"), "got \(names)")
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
            try store.save(s, spaceIndex: 1)
        }
        // A different Space's history must not consume this Space's slots.
        try store.save(base, spaceIndex: 2)
        let history = try store.loadHistory(forConfigurationID: base.displayConfigurationID, spaceIndex: 1)
        XCTAssertEqual(history.count, 3, "Only historyLimit=3 entries should remain.")
        XCTAssertEqual(try store.loadHistory(forConfigurationID: base.displayConfigurationID, spaceIndex: 2).count, 1,
                       "rotation is per Space")
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
        let url = tempDir.appendingPathComponent("\(configID).space0.plist")
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
        XCTAssertThrowsError(try store.loadLatest(forConfigurationID: configID, spaceIndex: 0)) { error in
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
