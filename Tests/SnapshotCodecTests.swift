import XCTest
@testable import PixlPutCore

final class SnapshotCodecTests: XCTestCase {

    // T010 — Codable round-trip equality
    func test_snapshotCodec_whenRoundTripped_thenEqualToOriginal() throws {
        let original = Self.makeFixtureSnapshot()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Snapshot.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    // T011 — schemaVersion stamped on every snapshot
    func test_snapshot_whenInitialized_thenSchemaVersionIsCurrent() {
        let s = Self.makeFixtureSnapshot()
        XCTAssertEqual(s.schemaVersion, Snapshot.currentSchemaVersion)
        XCTAssertEqual(s.schemaVersion, 1)
    }

    // Variant-key uniqueness per contracts/snapshot.schema.json oneOf
    func test_windowIdentity_whenEncoded_thenExactlyOneVariantKeyPresent() throws {
        let identities: [WindowIdentity] = [
            .documentPath(URL(fileURLWithPath: "/tmp/a.txt")),
            .browserTabSet([URL(string: "https://example.com")!]),
            .editorWorkspace(URL(fileURLWithPath: "/tmp/ws")),
            .terminalCWD(URL(fileURLWithPath: "/tmp/cwd")),
            .titleRegex(pattern: "^x$", capturedValue: "x"),
            .ordinal(0),
        ]
        let encoder = JSONEncoder()
        for id in identities {
            let data = try encoder.encode(id)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(obj?.count, 1, "Each WindowIdentity must encode with exactly one variant key.")
        }
    }

    // Decoder rejects multi-variant objects (defends the oneOf invariant on read)
    func test_windowIdentity_whenDecodingMultipleVariants_thenThrows() {
        let bad = #"{"documentPath":"file:///a","ordinal":1}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(WindowIdentity.self, from: bad))
    }

    // CGRectCodable approximate-equality used by Restorer (FR-010, constitution §III)
    func test_cgRectCodable_whenWithinTolerance_thenIsApproximatelyTrue() {
        let a = CGRectCodable(x: 100, y: 100, width: 800, height: 600)
        let b = CGRectCodable(x: 100.4, y: 100.6, width: 800.3, height: 600.2)
        let c = CGRectCodable(x: 102, y: 100, width: 800, height: 600)
        XCTAssertTrue(a.isApproximately(b, tolerance: 1.0))
        XCTAssertFalse(a.isApproximately(c, tolerance: 1.0))
        XCTAssertTrue(a.isApproximately(c, tolerance: 3.0))
    }

    // MARK: - Helpers

    static func makeFixtureSnapshot() -> Snapshot {
        let fp = DisplayFingerprint(
            vendorID: 0x05ac, productID: 0xa050,
            modelNumber: 0xa050, serialNumber: 0,
            displayUUID: "37D8832A-2D66-02CA-B9F7-1D4E9B2C7A11"
        )
        let display = DisplaySnapshot(
            fingerprint: fp,
            bounds: CGRectCodable(x: 0, y: 0, width: 1920, height: 1080),
            isPrimary: true,
            scaleFactor: 2.0
        )
        let windows: [WindowEntry] = [
            WindowEntry(
                bundleID: "com.brave.Browser",
                identity: .browserTabSet([URL(string: "https://example.com")!]),
                ordinalInApp: 0,
                displayFingerprintID: fp.id,
                spaceIndex: 0,
                frame: CGRectCodable(x: 0, y: 0, width: 1024, height: 768),
                isMinimized: false,
                isFullscreen: false,
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            WindowEntry(
                bundleID: "com.microsoft.VSCode",
                identity: .editorWorkspace(URL(fileURLWithPath: "/Users/u/Code/pixput")),
                ordinalInApp: 0,
                displayFingerprintID: fp.id,
                spaceIndex: 0,
                frame: CGRectCodable(x: 1024, y: 0, width: 1024, height: 1080),
                isMinimized: false,
                isFullscreen: true,
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
        ]
        return Snapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: nil,
            displayConfigurationID: DisplayConfigurationID.compute(from: [fp]),
            displays: [display],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            trigger: .screensaverStart,
            windows: windows
        )
    }
}
