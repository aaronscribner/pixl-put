import XCTest
@testable import PixlPutCore

/// Fake backend records every move + reports configurable outcomes.
actor FakeBackend: RestorerBackend {
    var live: [LiveWindow]
    /// Frames the backend was asked to move to (in call order).
    var moveRequests: [(LiveWindow, CGRectCodable)] = []
    var fullscreenRequests: [(LiveWindow, String)] = []
    /// If `true`, the next `move` returns `false` (user interaction simulated).
    var nextMoveCancelled: Bool = false

    init(live: [LiveWindow]) {
        self.live = live
    }

    func enumerateLiveWindows(limitToBundleIDs: Set<String>?) async throws -> [LiveWindow] { live }

    func move(window: LiveWindow, to frame: CGRectCodable, policy: MovePolicy) async throws -> Bool {
        moveRequests.append((window, frame))
        if nextMoveCancelled {
            nextMoveCancelled = false
            return false
        }
        return true
    }

    func setFullscreen(window: LiveWindow, on displayFingerprintID: String) async throws -> Bool {
        fullscreenRequests.append((window, displayFingerprintID))
        return true
    }

    func setNextMoveCancelled(_ value: Bool) { nextMoveCancelled = value }
    func moveRequestCount() -> Int { moveRequests.count }
    func fullscreenRequestCount() -> Int { fullscreenRequests.count }
    func moveRequestFrames() -> [CGRectCodable] { moveRequests.map(\.1) }
}

final class RestorerTests: XCTestCase {

    /// Helper: construct a LiveWindow from a fixture WindowEntry with the
    /// caller-supplied current frame + fullscreen state.
    static func liveFromEntry(
        _ entry: WindowEntry,
        currentFrame: CGRectCodable,
        isFullscreen: Bool? = nil
    ) -> LiveWindow {
        LiveWindow(
            bundleID: entry.bundleID,
            identity: entry.identity,
            ordinalInApp: entry.ordinalInApp,
            currentFrame: currentFrame,
            currentDisplayFingerprintID: entry.displayFingerprintID,
            isFullscreen: isFullscreen ?? entry.isFullscreen
        )
    }

    // T012 — Idempotence: 1px tolerance, no move (FR-010, constitution §III).
    // This applies to windowed AND fullscreen windows alike — a fullscreen window
    // already fullscreen on the correct display at the correct frame must NOT be
    // re-entered into fullscreen (that would violate §III).
    func test_restorer_whenWindowAlreadyAtFrameWithin1px_thenDoesNotMove() async throws {
        let snap = SnapshotCodecTests.makeFixtureSnapshot()
        let entry1 = snap.windows[0]
        let entry2 = snap.windows[1]
        let live1 = Self.liveFromEntry(entry1, currentFrame: CGRectCodable(x: 0.5, y: 0.2, width: 1024.4, height: 767.8))
        let live2 = Self.liveFromEntry(entry2, currentFrame: entry2.frame)

        let backend = FakeBackend(live: [live1, live2])
        let restorer = Restorer(backend: backend, tolerancePoints: 1.0)
        let report = try await restorer.apply(snap, activeDisplayFingerprintIDs: [entry1.displayFingerprintID])

        XCTAssertEqual(report.skippedAlreadyAtFrame, 2, "Both windows are already at the recorded state; idempotence should skip both.")
        XCTAssertEqual(report.moved, 0)
        XCTAssertEqual(report.fullscreenAttempts, 0, "Already-fullscreen window must not trigger setFullscreen (§III idempotence).")
        let moves = await backend.moveRequestCount()
        let fsCalls = await backend.fullscreenRequestCount()
        XCTAssertEqual(moves, 0)
        XCTAssertEqual(fsCalls, 0)
    }

    // REGRESSION — frames are re-anchored to a display's CURRENT origin.
    // A window saved at x=-3763 on a monitor that was at origin x=-3840 must
    // land at x=+77 when that same monitor now sits at origin x=0 (e.g. the
    // second display was unplugged). Without re-anchoring it would be flung
    // off-screen to x=-3763 — the "none of the windows go to the right place
    // after a monitor change" bug.
    func test_restorer_whenDisplayMovedOrigin_thenFrameIsReanchored() async throws {
        let fp = DisplayFingerprint(vendorID: 1, productID: 2, modelNumber: 3, serialNumber: 4, displayUUID: "mon-A")
        // Snapshot: monitor A was at origin (-3840, 0); window sits near its left edge.
        let savedDisplay = DisplaySnapshot(
            fingerprint: fp,
            bounds: CGRectCodable(x: -3840, y: 0, width: 3840, height: 2160),
            isPrimary: false, scaleFactor: 2.0
        )
        let entry = WindowEntry(
            bundleID: "com.example.app",
            identity: .ordinal(0), ordinalInApp: 0,
            displayFingerprintID: fp.id, spaceIndex: 0,
            frame: CGRectCodable(x: -3763, y: 49, width: 2264, height: 1555),
            isMinimized: false, isFullscreen: false,
            capturedAt: Date(timeIntervalSince1970: 0)
        )
        let snap = Snapshot(
            displayConfigurationID: "cfg", displays: [savedDisplay],
            capturedAt: Date(timeIntervalSince1970: 0), trigger: .manual, windows: [entry]
        )
        // The window currently sits somewhere else so a move is required.
        let live = Self.liveFromEntry(entry, currentFrame: CGRectCodable(x: 100, y: 100, width: 500, height: 400))
        let backend = FakeBackend(live: [live])
        let restorer = Restorer(backend: backend, tolerancePoints: 1.0)

        // Monitor A is now the ONLY display, at origin (0, 0).
        let report = try await restorer.apply(
            snap,
            activeDisplayFingerprintIDs: [fp.id],
            currentDisplayBoundsByID: [fp.id: CGRectCodable(x: 0, y: 0, width: 3840, height: 2160)]
        )

        XCTAssertEqual(report.moved, 1)
        let frames = await backend.moveRequestFrames()
        XCTAssertEqual(frames.count, 1)
        // dx = 0 - (-3840) = +3840  ->  x: -3763 + 3840 = 77 ; y unchanged.
        XCTAssertEqual(frames[0].x, 77, accuracy: 0.001)
        XCTAssertEqual(frames[0].y, 49, accuracy: 0.001)
        XCTAssertEqual(frames[0].width, 2264, accuracy: 0.001)
    }

    // Same-origin (or unknown origin) must NOT change the frame — no regression.
    func test_restorer_whenDisplayOriginUnchanged_thenFrameIsRaw() async throws {
        let fp = DisplayFingerprint(vendorID: 9, productID: 8, modelNumber: 7, serialNumber: 6, displayUUID: "mon-B")
        let bounds = CGRectCodable(x: 0, y: 0, width: 3840, height: 2160)
        let savedDisplay = DisplaySnapshot(fingerprint: fp, bounds: bounds, isPrimary: true, scaleFactor: 2.0)
        let entry = WindowEntry(
            bundleID: "com.example.app", identity: .ordinal(0), ordinalInApp: 0,
            displayFingerprintID: fp.id, spaceIndex: 0,
            frame: CGRectCodable(x: 1200, y: 300, width: 800, height: 600),
            isMinimized: false, isFullscreen: false, capturedAt: Date(timeIntervalSince1970: 0)
        )
        let snap = Snapshot(
            displayConfigurationID: "cfg", displays: [savedDisplay],
            capturedAt: Date(timeIntervalSince1970: 0), trigger: .manual, windows: [entry]
        )
        let live = Self.liveFromEntry(entry, currentFrame: CGRectCodable(x: 0, y: 0, width: 500, height: 400))
        let backend = FakeBackend(live: [live])
        let restorer = Restorer(backend: backend, tolerancePoints: 1.0)
        let report = try await restorer.apply(
            snap, activeDisplayFingerprintIDs: [fp.id],
            currentDisplayBoundsByID: [fp.id: bounds]
        )
        XCTAssertEqual(report.moved, 1)
        let frames = await backend.moveRequestFrames()
        XCTAssertEqual(frames[0].x, 1200, accuracy: 0.001)
        XCTAssertEqual(frames[0].y, 300, accuracy: 0.001)
    }

    // T013 — Skip missing window, continue with the rest (FR-011, Story-1 acceptance #3)
    func test_restorer_whenWindowMissing_thenSkipsAndContinues() async throws {
        let snap = SnapshotCodecTests.makeFixtureSnapshot()
        let entry2 = snap.windows[1]
        let live = Self.liveFromEntry(entry2, currentFrame: CGRectCodable(x: 0, y: 0, width: 1, height: 1), isFullscreen: false)
        let backend = FakeBackend(live: [live])
        let restorer = Restorer(backend: backend)
        let report = try await restorer.apply(snap, activeDisplayFingerprintIDs: [entry2.displayFingerprintID])
        XCTAssertEqual(report.skippedMissingWindow, 1)
        XCTAssertEqual(report.fullscreenAttempts, 1)
    }

    // T014 — Fullscreen re-entry on recorded display (Story-1 acceptance #4)
    func test_restorer_whenEntryIsFullscreen_thenFullscreenBackendIsCalled() async throws {
        let snap = SnapshotCodecTests.makeFixtureSnapshot()
        let entry1 = snap.windows[0]
        let entry2 = snap.windows[1]
        let live1 = Self.liveFromEntry(entry1, currentFrame: entry1.frame, isFullscreen: false)
        let live2 = Self.liveFromEntry(entry2, currentFrame: CGRectCodable(x: 0, y: 0, width: 800, height: 600), isFullscreen: false)

        let backend = FakeBackend(live: [live1, live2])
        let restorer = Restorer(backend: backend)
        let report = try await restorer.apply(snap, activeDisplayFingerprintIDs: [entry2.displayFingerprintID])

        XCTAssertEqual(report.fullscreenAttempts, 1)
        XCTAssertEqual(report.fullscreenSucceeded, 1)
        let fsCalls = await backend.fullscreenRequestCount()
        let moveCalls = await backend.moveRequestCount()
        XCTAssertEqual(fsCalls, 1)
        XCTAssertEqual(moveCalls, 0)
    }

    // FR-012 — user dragging during restore cancels for that single window
    func test_restorer_whenUserCancelsMove_thenCountedAsCancelledAndOtherWindowsProceed() async throws {
        let snap = SnapshotCodecTests.makeFixtureSnapshot()
        let entry1 = snap.windows[0]
        let entry2 = snap.windows[1]
        let live1 = Self.liveFromEntry(entry1, currentFrame: CGRectCodable(x: 999, y: 999, width: 100, height: 100), isFullscreen: false)
        let live2 = Self.liveFromEntry(entry2, currentFrame: CGRectCodable(x: 999, y: 999, width: 100, height: 100), isFullscreen: false)

        let backend = FakeBackend(live: [live1, live2])
        await backend.setNextMoveCancelled(true)
        let restorer = Restorer(backend: backend)
        let report = try await restorer.apply(snap, activeDisplayFingerprintIDs: [entry1.displayFingerprintID])
        XCTAssertEqual(report.cancelledByUserInteraction, 1)
        XCTAssertEqual(report.fullscreenAttempts, 1)
    }

    // REGRESSION — Cross-bundle ordinal collision must NOT cause windows
    // to "disappear" (i.e. be moved to wrong frames or skipped as missing).
    // This is the "TextEdit window vanishes on restore" bug class.
    //
    // Two different bundles each have a window whose identity resolves to
    // `.ordinal(0)`. With the original `[WindowIdentity: LiveWindow]`
    // matching, the second one overwrote the first; one snapshot entry
    // got "missing", the other got moved to the wrong frame.
    func test_restorer_whenTwoBundlesShareOrdinalIdentity_thenEachWindowMovesToItsOwnFrame() async throws {
        let fp = DisplayFingerprint(vendorID: 1, productID: 1, modelNumber: 1, serialNumber: 1, displayUUID: nil)
        let display = DisplaySnapshot(
            fingerprint: fp,
            bounds: CGRectCodable(x: 0, y: 0, width: 3000, height: 2000),
            isPrimary: true, scaleFactor: 1.0
        )
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        // Snapshot: two windows, different bundles, both with identity .ordinal(0).
        let textEditEntry = WindowEntry(
            bundleID: "com.apple.TextEdit",
            identity: .ordinal(0),
            ordinalInApp: 0,
            displayFingerprintID: fp.id,
            spaceIndex: 0,
            frame: CGRectCodable(x: 100, y: 100, width: 600, height: 400),
            isMinimized: false, isFullscreen: false,
            capturedAt: capturedAt
        )
        let braveEntry = WindowEntry(
            bundleID: "com.brave.Browser",
            identity: .ordinal(0),
            ordinalInApp: 0,
            displayFingerprintID: fp.id,
            spaceIndex: 0,
            frame: CGRectCodable(x: 1500, y: 200, width: 1200, height: 900),
            isMinimized: false, isFullscreen: false,
            capturedAt: capturedAt
        )
        let snap = Snapshot(
            displayConfigurationID: DisplayConfigurationID.compute(from: [fp]),
            displays: [display],
            capturedAt: capturedAt,
            trigger: .manual,
            windows: [textEditEntry, braveEntry]
        )
        // Both live windows currently at the WRONG frame, so both should move.
        let textEditLive = Self.liveFromEntry(textEditEntry, currentFrame: CGRectCodable(x: 0, y: 0, width: 1, height: 1))
        let braveLive = Self.liveFromEntry(braveEntry, currentFrame: CGRectCodable(x: 0, y: 0, width: 1, height: 1))

        let backend = FakeBackend(live: [textEditLive, braveLive])
        let restorer = Restorer(backend: backend)
        let report = try await restorer.apply(snap, activeDisplayFingerprintIDs: [fp.id])

        XCTAssertEqual(report.moved, 2, "Both windows must move; cross-bundle ordinal collision must not eat one.")
        XCTAssertEqual(report.skippedMissingWindow, 0, "Neither window should be reported missing.")

        // Verify the actual move requests went to the right frames per bundle.
        let moves = await backend.moveRequests
        XCTAssertEqual(moves.count, 2)
        let textEditMove = moves.first { $0.0.bundleID == "com.apple.TextEdit" }
        let braveMove = moves.first { $0.0.bundleID == "com.brave.Browser" }
        XCTAssertEqual(textEditMove?.1, textEditEntry.frame, "TextEdit window must be moved to its OWN frame, not Brave's.")
        XCTAssertEqual(braveMove?.1, braveEntry.frame, "Brave window must be moved to its OWN frame, not TextEdit's.")
    }

    // Phase C — onlySpaceIndex filter restores ONLY entries whose
    // spaceIndex matches; entries on other Spaces are left alone, NOT
    // counted as "missing".
    func test_restorer_onlySpaceIndex_restoresMatchingSpaceOnly() async throws {
        let fp = DisplayFingerprint(vendorID: 1, productID: 1, modelNumber: 1, serialNumber: 1, displayUUID: nil)
        let display = DisplaySnapshot(
            fingerprint: fp,
            bounds: CGRectCodable(x: 0, y: 0, width: 3000, height: 2000),
            isPrimary: true, scaleFactor: 1.0
        )
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        // Two entries — one on Space 0, one on Space 1.
        let space0Entry = WindowEntry(
            bundleID: "com.brave.Browser", identity: .ordinal(0), ordinalInApp: 0,
            displayFingerprintID: fp.id, spaceIndex: 0,
            frame: CGRectCodable(x: 100, y: 100, width: 800, height: 600),
            isMinimized: false, isFullscreen: false, capturedAt: capturedAt
        )
        let space1Entry = WindowEntry(
            bundleID: "com.apple.TextEdit", identity: .ordinal(0), ordinalInApp: 0,
            displayFingerprintID: fp.id, spaceIndex: 1,
            frame: CGRectCodable(x: 200, y: 200, width: 800, height: 600),
            isMinimized: false, isFullscreen: false, capturedAt: capturedAt
        )
        let snap = Snapshot(
            displayConfigurationID: DisplayConfigurationID.compute(from: [fp]),
            displays: [display],
            capturedAt: capturedAt, trigger: .manual,
            windows: [space0Entry, space1Entry]
        )
        // Both windows live, but the Restorer is asked to restore only Space 0.
        let live0 = Self.liveFromEntry(space0Entry, currentFrame: CGRectCodable(x: 0, y: 0, width: 1, height: 1))
        let live1 = Self.liveFromEntry(space1Entry, currentFrame: CGRectCodable(x: 0, y: 0, width: 1, height: 1))

        let backend = FakeBackend(live: [live0, live1])
        let restorer = Restorer(backend: backend)
        let report = try await restorer.apply(
            snap,
            activeDisplayFingerprintIDs: [fp.id],
            onlySpaceIndex: 0
        )
        XCTAssertEqual(report.moved, 1, "Only the Space-0 entry should move.")
        XCTAssertEqual(report.skippedMissingWindow, 0, "Space-1 entry must NOT be counted as missing.")

        let moves = await backend.moveRequests
        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual(moves.first?.0.bundleID, "com.brave.Browser")
        XCTAssertEqual(moves.first?.1, space0Entry.frame)
    }

    // REGRESSION — Within-bundle same-identity collision must use ordinalInApp
    // to disambiguate. Two iTerm2 windows both in ~/work both resolve to
    // `.terminalCWD("file:///Users/u/work")`. The ordinal pairs them off.
    func test_restorer_whenTwoWindowsSameBundleSameIdentity_thenOrdinalPairsThem() async throws {
        let fp = DisplayFingerprint(vendorID: 1, productID: 1, modelNumber: 1, serialNumber: 1, displayUUID: nil)
        let display = DisplaySnapshot(
            fingerprint: fp,
            bounds: CGRectCodable(x: 0, y: 0, width: 3000, height: 2000),
            isPrimary: true, scaleFactor: 1.0
        )
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let bundleID = "com.googlecode.iterm2"
        let identity: WindowIdentity = .terminalCWD(URL(fileURLWithPath: "/Users/u/work"))
        let entry0 = WindowEntry(
            bundleID: bundleID, identity: identity, ordinalInApp: 0,
            displayFingerprintID: fp.id, spaceIndex: 0,
            frame: CGRectCodable(x: 100, y: 100, width: 800, height: 600),
            isMinimized: false, isFullscreen: false, capturedAt: capturedAt
        )
        let entry1 = WindowEntry(
            bundleID: bundleID, identity: identity, ordinalInApp: 1,
            displayFingerprintID: fp.id, spaceIndex: 0,
            frame: CGRectCodable(x: 1200, y: 100, width: 800, height: 600),
            isMinimized: false, isFullscreen: false, capturedAt: capturedAt
        )
        let snap = Snapshot(
            displayConfigurationID: DisplayConfigurationID.compute(from: [fp]),
            displays: [display],
            capturedAt: capturedAt, trigger: .manual,
            windows: [entry0, entry1]
        )
        // Live windows currently NOT at target frames.
        let live0 = Self.liveFromEntry(entry0, currentFrame: CGRectCodable(x: 0, y: 0, width: 1, height: 1))
        let live1 = Self.liveFromEntry(entry1, currentFrame: CGRectCodable(x: 0, y: 0, width: 1, height: 1))

        let backend = FakeBackend(live: [live0, live1])
        let restorer = Restorer(backend: backend)
        let report = try await restorer.apply(snap, activeDisplayFingerprintIDs: [fp.id])

        XCTAssertEqual(report.moved, 2)
        XCTAssertEqual(report.skippedMissingWindow, 0)

        // Ordinal-0 entry must end up at entry0.frame; ordinal-1 entry at entry1.frame.
        let moves = await backend.moveRequests
        let move0 = moves.first { $0.0.ordinalInApp == 0 }
        let move1 = moves.first { $0.0.ordinalInApp == 1 }
        XCTAssertEqual(move0?.1, entry0.frame)
        XCTAssertEqual(move1?.1, entry1.frame)
    }
}
