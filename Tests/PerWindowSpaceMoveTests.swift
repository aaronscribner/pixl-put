import XCTest
import CoreGraphics
@testable import PixlPutCore

/// Per-window Space relocation (ADR-0002) — the path that uses deep identity
/// to tell two windows of the same app apart, which the per-app backend
/// cannot express.
final class PerWindowSpaceMoveTests: XCTestCase {

    private func entry(_ bundleID: String, identity: WindowIdentity, space: Int, ordinal: Int = 0) -> WindowEntry {
        WindowEntry(
            bundleID: bundleID, identity: identity, ordinalInApp: ordinal,
            displayFingerprintID: "d1", spaceIndex: space,
            frame: CGRectCodable(x: 0, y: 0, width: 100, height: 100),
            isMinimized: false, isFullscreen: false, capturedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func live(_ bundleID: String, identity: WindowIdentity, windowID: CGWindowID?, ordinal: Int = 0) -> LiveWindow {
        LiveWindow(
            bundleID: bundleID, identity: identity, ordinalInApp: ordinal,
            currentFrame: CGRectCodable(x: 0, y: 0, width: 100, height: 100),
            currentDisplayFingerprintID: "d1", windowID: windowID, isFullscreen: false
        )
    }

    private let braveA = WindowIdentity.browserTabSet([URL(string: "https://a.example")!])
    private let braveB = WindowIdentity.browserTabSet([URL(string: "https://b.example")!])

    /// The headline case: two windows of ONE app, captured on different
    /// Spaces, each sent to its own Space.
    func test_twoWindowsOfSameApp_goToDifferentSpaces() {
        let moves = SpaceAssignmentPlanner.perWindowMoves(
            snapshot: [
                entry("com.brave.Browser", identity: braveA, space: 3),
                entry("com.brave.Browser", identity: braveB, space: 7, ordinal: 1),
            ],
            live: [
                live("com.brave.Browser", identity: braveA, windowID: 101),
                live("com.brave.Browser", identity: braveB, windowID: 202, ordinal: 1),
            ]
        )
        XCTAssertEqual(moves.count, 2)
        XCTAssertEqual(moves.first { $0.windowID == 101 }?.targetSpaceIndex, 3)
        XCTAssertEqual(moves.first { $0.windowID == 202 }?.targetSpaceIndex, 7)
    }

    /// An app's only window can't be confused with another, so it is
    /// relocated even though its identity is just a list position.
    func test_soleOrderOnlyWindow_isRelocated() {
        let moves = SpaceAssignmentPlanner.perWindowMoves(
            snapshot: [entry("com.apple.Terminal", identity: .ordinal(0), space: 5)],
            live: [live("com.apple.Terminal", identity: .ordinal(0), windowID: 303)]
        )
        XCTAssertEqual(moves, [SpaceAssignmentPlanner.WindowMove(windowID: 303, targetSpaceIndex: 5,
                                                                 bundleID: "com.apple.Terminal")])
    }

    func test_orderOnlyWindows_withNothingToTellThemApart_areNeverRelocated() {
        // Ordinals shift across app restarts and focus changes; moving on
        // that guess relocates the wrong window.
        let moves = SpaceAssignmentPlanner.perWindowMoves(
            snapshot: [entry("com.apple.Terminal", identity: .ordinal(0), space: 5),
                       entry("com.apple.Terminal", identity: .ordinal(1), space: 2, ordinal: 1)],
            live: [live("com.apple.Terminal", identity: .ordinal(0), windowID: 303),
                   live("com.apple.Terminal", identity: .ordinal(1), windowID: 304, ordinal: 1)]
        )
        XCTAssertTrue(moves.isEmpty)
    }

    func test_windowWithoutCGWindowID_isSkipped() {
        let moves = SpaceAssignmentPlanner.perWindowMoves(
            snapshot: [entry("com.brave.Browser", identity: braveA, space: 3)],
            live: [live("com.brave.Browser", identity: braveA, windowID: nil)]
        )
        XCTAssertTrue(moves.isEmpty, "no CGWindowID means no way to address the window")
    }

    func test_sameKeyCapturedOnTwoSpaces_isDroppedAsAmbiguous() {
        let moves = SpaceAssignmentPlanner.perWindowMoves(
            snapshot: [
                entry("com.brave.Browser", identity: braveA, space: 3),
                entry("com.brave.Browser", identity: braveA, space: 7),
            ],
            live: [live("com.brave.Browser", identity: braveA, windowID: 101)]
        )
        XCTAssertTrue(moves.isEmpty, "unresolvable target must move nothing")
    }

    func test_liveWindowWithNoSnapshotEntry_isLeftAlone() {
        let moves = SpaceAssignmentPlanner.perWindowMoves(
            snapshot: [entry("com.brave.Browser", identity: braveA, space: 3)],
            live: [
                live("com.brave.Browser", identity: braveA, windowID: 101),
                live("com.apple.Notes", identity: .documentPath(URL(fileURLWithPath: "/tmp/n")), windowID: 999),
            ]
        )
        XCTAssertEqual(moves.map(\.windowID), [101])
    }

    func test_outputOrderIsDeterministic() {
        let snapshot = [
            entry("com.brave.Browser", identity: braveA, space: 3),
            entry("com.brave.Browser", identity: braveB, space: 7, ordinal: 1),
        ]
        let liveWindows = [
            live("com.brave.Browser", identity: braveB, windowID: 202, ordinal: 1),
            live("com.brave.Browser", identity: braveA, windowID: 101),
        ]
        let first = SpaceAssignmentPlanner.perWindowMoves(snapshot: snapshot, live: liveWindows)
        for _ in 0..<25 {
            XCTAssertEqual(SpaceAssignmentPlanner.perWindowMoves(snapshot: snapshot, live: liveWindows), first)
        }
    }

    // MARK: - Backend selection

    func test_cgsBackendRefusesPerWindowMoves() {
        // It must not claim success it can't deliver: CGSMoveWindowsToManagedSpace
        // silently ignores foreign windows.
        let backend = CGSProcessRelocationBackend()
        XCTAssertFalse(backend.supportsPerWindowMoves)
        XCTAssertFalse(backend.move(windowID: 123, toSpaceIndex: 2))
    }

    func test_yabaiBackendIsNotFoundWhenBinaryIsAbsent() {
        XCTAssertNil(YabaiRelocationBackend.locate(searchPaths: ["/nonexistent/yabai"]))
    }

    func test_factoryFallsBackToPerAppBackendWhenYabaiMissing() {
        // On a machine without yabai the factory must still return something
        // usable rather than nil.
        let backend = SpaceRelocationBackendFactory.best()
        if YabaiRelocationBackend.locate() == nil {
            XCTAssertFalse(backend.supportsPerWindowMoves)
            XCTAssertEqual(backend.name, "macOS (per-app)")
        }
    }

    /// yabai indices are 1-based and PixPut's are 0-based; an off-by-one here
    /// silently sends every window to the wrong Space.
    func test_yabaiSpaceIndexIsConvertedToOneBased() throws {
        let script = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fake-yabai-\(UUID().uuidString).sh")
        let output = script.appendingPathExtension("args")
        try """
        #!/bin/sh
        echo "$@" > "\(output.path)"
        exit 0
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        defer {
            try? FileManager.default.removeItem(at: script)
            try? FileManager.default.removeItem(at: output)
        }

        let backend = YabaiRelocationBackend(executableURL: script)
        XCTAssertTrue(backend.move(windowID: 4242, toSpaceIndex: 0))

        let recorded = try String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(recorded, "-m window 4242 --space 1",
                       "0-based PixPut index must become 1-based yabai index")
    }
}
