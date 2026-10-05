import XCTest
import CoreGraphics
@testable import PixlPutCore

/// Finder restores its own windows after a restart, so PixPut neither
/// captures nor restores them.
final class ExcludedAppsTests: XCTestCase {

    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pixput-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Snapshots captured before Finder was excluded still hold Finder
    /// entries. Every restore path reads through the store, so they are
    /// dropped there, and those snapshots need no re-capture.
    func test_store_dropsExcludedAppWindowsOnLoad() throws {
        let store = SnapshotStore(directory: tempDir, spaceKeys: FixedSpaceKeys(count: 2))
        let base = SnapshotCodecTests.makeFixtureSnapshot()
        let template = base.windows[0]
        let finder = WindowEntry(
            bundleID: "com.apple.finder", identity: .ordinal(0), ordinalInApp: 0,
            displayFingerprintID: template.displayFingerprintID, spaceIndex: template.spaceIndex,
            frame: template.frame, isMinimized: false, isFullscreen: false,
            capturedAt: template.capturedAt
        )
        let withFinder = Snapshot(
            id: base.id, name: base.name, displayConfigurationID: base.displayConfigurationID,
            displays: base.displays, capturedAt: base.capturedAt, trigger: base.trigger,
            windows: base.windows + [finder]
        )
        try store.save(withFinder, spaceIndex: 0)

        let loaded = try XCTUnwrap(store.loadLatest(forConfigurationID: base.displayConfigurationID, spaceIndex: 0))

        XCTAssertEqual(loaded.windows, base.windows)
        XCTAssertEqual(loaded.id, base.id)
        XCTAssertEqual(
            store.listHistory(forConfigurationID: base.displayConfigurationID, spaceIndex: 0).first?.windowCount,
            base.windows.count
        )
    }

    func test_removing_leavesSnapshotWithoutExcludedAppsUnchanged() {
        let base = SnapshotCodecTests.makeFixtureSnapshot()
        XCTAssertEqual(ExcludedApps.removing(from: base), base)
    }

    /// Live Finder windows on other Spaces do not enter the restore plan, so
    /// they are neither moved nor reported as unmatched.
    func test_crossSpaceIndex_leavesOutExcludedApps() {
        let bounds = CGRectCodable(x: 0, y: 0, width: 800, height: 600)
        let rows = NativeWindowQuery.build(
            descriptors: [
                CGWindowDescriptor(windowID: 1, ownerPID: 7, bundleID: "com.apple.finder",
                                   title: "Downloads", bounds: bounds, isOnScreen: false),
                CGWindowDescriptor(windowID: 2, ownerPID: 8, bundleID: "com.microsoft.VSCode",
                                   title: "a.md — PixPut", bounds: bounds, isOnScreen: false),
            ],
            spaceIDsByWindow: [1: [30], 2: [30]],
            orderedSpaceIDs: [30]
        )

        let index = CrossSpaceWindowIndex.build(
            yabaiWindows: rows,
            bundleIDByPID: [7: "com.apple.finder", 8: "com.microsoft.VSCode"],
            displayBoundsByID: [:]
        )

        XCTAssertEqual(index.map(\.live.bundleID), ["com.microsoft.VSCode"])
    }

    /// No Finder AppleScript runs, so no Automation permission for Finder is
    /// ever requested.
    func test_finderIsNotScripted() {
        XCTAssertFalse(DeepIdentityFetcher.isScripted(bundleID: "com.apple.finder"))
        XCTAssertFalse(DeepIdentityFetcher.reportsDocumentsByTitle(bundleID: "com.apple.finder"))
        XCTAssertFalse(DeepIdentityFetcher.allScriptedBundleIDs().contains("com.apple.finder"))
    }
}
