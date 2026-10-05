import XCTest
@testable import PixlPutCore

/// Performance floor tests for the post-AX portion of the snapshot
/// pipeline. The full capture-to-disk path (including live AX calls)
/// is measured manually per `quickstart.md` §20. These tests guard
/// against regressions in the parts that DON'T require live AX.
///
/// Budgets here are deliberately tight (~10% of constitution §VII) so
/// that the AX portion has the rest of the 500ms budget to work with.
final class PerformanceTests: XCTestCase {

    // 100-window snapshot Codable encode + write to disk
    // Budget: 50ms on Apple Silicon. Constitution §VII total capture
    // budget is 500ms; this leaves 450ms for AX calls + identity probes.
    func test_snapshot_encodeAndWrite_100windows_under50ms() throws {
        let snap = Self.make100WindowSnapshot()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pixput-perf-\(UUID().uuidString)", isDirectory: true)
        let store = SnapshotStore(directory: tempDir, spaceKeys: FixedSpaceKeys(count: 1))

        defer { try? FileManager.default.removeItem(at: tempDir) }

        let t0 = Date()
        try store.save(snap, spaceIndex: 0)
        let elapsed = Date().timeIntervalSince(t0)

        XCTAssertLessThan(elapsed, 0.050, "Encode+write 100-window snapshot took \(elapsed * 1000)ms; budget is 50ms.")
    }

    // 100-window Restorer.apply with a no-op backend.
    // Budget: 100ms on Apple Silicon. Constitution §VII restore budget
    // for 50 windows is 2s; 100-window pure-Swift orchestration should
    // be a small fraction of that.
    func test_restorer_apply_100windows_pureLogic_under100ms() async throws {
        let snap = Self.make100WindowSnapshot()
        let liveWindows = snap.windows.map { entry in
            LiveWindow(
                bundleID: entry.bundleID,
                identity: entry.identity,
                ordinalInApp: entry.ordinalInApp,
                currentFrame: CGRectCodable(x: 999, y: 999, width: 1, height: 1), // forces move
                currentDisplayFingerprintID: entry.displayFingerprintID,
                isFullscreen: false
            )
        }
        let backend = NoOpBackend(live: liveWindows)
        let restorer = Restorer(backend: backend, tolerancePoints: 1.0)
        let activeIDs = Set(snap.displays.map(\.fingerprint.id))

        let t0 = Date()
        let report = try await restorer.apply(snap, activeDisplayFingerprintIDs: activeIDs)
        let elapsed = Date().timeIntervalSince(t0)

        XCTAssertGreaterThan(report.moved, 0)
        XCTAssertLessThan(elapsed, 0.100, "Restorer.apply on 100 windows took \(elapsed * 1000)ms; budget is 100ms.")
    }

    // Codable round-trip of a 100-window snapshot
    func test_snapshot_codecRoundTrip_100windows_under30ms() throws {
        let snap = Self.make100WindowSnapshot()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let t0 = Date()
        let data = try encoder.encode(snap)
        let decoded = try decoder.decode(Snapshot.self, from: data)
        let elapsed = Date().timeIntervalSince(t0)

        XCTAssertEqual(decoded, snap)
        XCTAssertLessThan(elapsed, 0.030, "100-window encode+decode took \(elapsed * 1000)ms; budget is 30ms.")
    }

    // MARK: - Fixture

    static func make100WindowSnapshot() -> Snapshot {
        let fp = DisplayFingerprint(
            vendorID: 0x05ac, productID: 0xa050,
            modelNumber: 0xa050, serialNumber: 0,
            displayUUID: nil
        )
        let display = DisplaySnapshot(
            fingerprint: fp,
            bounds: CGRectCodable(x: 0, y: 0, width: 3024, height: 1964),
            isPrimary: true,
            scaleFactor: 2.0
        )
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let bundles = [
            "com.brave.Browser", "com.microsoft.VSCode", "com.apple.dt.Xcode",
            "com.googlecode.iterm2", "com.apple.Terminal", "com.apple.Safari",
            "com.tinyspeck.slackmacgap", "com.notion.id", "com.linear", "com.figma.Desktop",
        ]
        var windows: [WindowEntry] = []
        for i in 0..<100 {
            let bundle = bundles[i % bundles.count]
            let identity: WindowIdentity = (i % 4 == 0)
                ? .documentPath(URL(fileURLWithPath: "/Users/u/file-\(i).txt"))
                : (i % 4 == 1)
                    ? .browserTabSet([URL(string: "https://example.com/page-\(i)")!])
                    : (i % 4 == 2)
                        ? .editorWorkspace(URL(fileURLWithPath: "/Users/u/Code/proj-\(i)"))
                        : .ordinal(i)
            windows.append(WindowEntry(
                bundleID: bundle,
                identity: identity,
                ordinalInApp: i / bundles.count,
                displayFingerprintID: fp.id,
                spaceIndex: 0,
                frame: CGRectCodable(
                    x: CGFloat(i * 10),
                    y: CGFloat(i * 5),
                    width: 1024, height: 768
                ),
                isMinimized: false,
                isFullscreen: false,
                capturedAt: capturedAt
            ))
        }
        return Snapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000100")!,
            name: nil,
            displayConfigurationID: DisplayConfigurationID.compute(from: [fp]),
            displays: [display],
            capturedAt: capturedAt,
            trigger: .screensaverStart,
            windows: windows
        )
    }
}

/// Always-succeeds backend, used for pure-orchestration timing.
actor NoOpBackend: RestorerBackend {
    private let liveWindows: [LiveWindow]
    init(live: [LiveWindow]) { self.liveWindows = live }
    func enumerateLiveWindows(limitToBundleIDs: Set<String>?) async throws -> [LiveWindow] { liveWindows }
    func move(window: LiveWindow, to frame: CGRectCodable, policy: MovePolicy) async throws -> Bool { true }
    func setFullscreen(window: LiveWindow, on displayFingerprintID: String) async throws -> Bool { true }
}
