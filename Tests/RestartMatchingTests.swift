import XCTest
import CoreGraphics
@testable import PixlPutCore

/// Matching after an app or the Mac restarts, when every window ID is new.
/// Fixtures follow the cases in the diagnostic logs of 2026-09-30 and
/// 2026-10-01: Teams and Messages (one window each), Firefox with many
/// windows, and saved window IDs that a new boot hands to other windows.
final class RestartMatchingTests: XCTestCase {

    private let displayID = "display-A"
    /// Captures happened before this boot; live windows belong to it.
    private let beforeBoot = Date(timeIntervalSince1970: 1_000)
    private let bootTime = Date(timeIntervalSince1970: 2_000)

    private func frame(_ x: Double) -> CGRectCodable {
        CGRectCodable(x: x, y: 40, width: 1200, height: 900)
    }

    private func saved(_ bundle: String, ordinal: Int, x: Double, title: String?,
                       windowID: CGWindowID? = nil, space: Int = 0,
                       identity: WindowIdentity? = nil) -> WindowEntry {
        WindowEntry(bundleID: bundle, identity: identity ?? .ordinal(ordinal), ordinalInApp: ordinal,
                    displayFingerprintID: displayID, spaceIndex: space, frame: frame(x),
                    isMinimized: false, isFullscreen: false, capturedAt: beforeBoot,
                    windowID: windowID, title: title)
    }

    private func live(_ bundle: String, ordinal: Int, title: String?, windowID: CGWindowID,
                      identity: WindowIdentity? = nil) -> LiveWindow {
        LiveWindow(bundleID: bundle, identity: identity ?? .ordinal(ordinal), ordinalInApp: ordinal,
                   currentFrame: CGRectCodable(x: 5, y: 5, width: 300, height: 300),
                   currentDisplayFingerprintID: displayID, windowID: windowID,
                   isFullscreen: false, title: title)
    }

    private func snapshot(_ entries: [WindowEntry]) -> Snapshot {
        Snapshot(
            displayConfigurationID: "cfg",
            displays: [DisplaySnapshot(
                fingerprint: DisplayFingerprint(vendorID: 1, productID: 1, modelNumber: 1,
                                                serialNumber: 1, displayUUID: displayID),
                bounds: CGRectCodable(x: 0, y: 0, width: 3840, height: 2160),
                isPrimary: true, scaleFactor: 2.0)],
            capturedAt: beforeBoot, trigger: .manual, windows: entries
        )
    }

    private func restore(_ entries: [WindowEntry], live: [LiveWindow]) async throws
        -> (RestoreReport, [(LiveWindow, CGRectCodable)]) {
        let backend = FakeBackend(live: live)
        let report = try await Restorer(backend: backend)
            .apply(snapshot(entries), activeDisplayFingerprintIDs: [displayID], windowIDsValidSince: bootTime)
        return (report, await backend.moveRequests)
    }

    // MARK: - Restoring the Desktop on screen

    /// Teams has one window, known only by list position; after a restart
    /// its window ID is new. Being the app's only window identifies it.
    func test_teams_singleWindow_restoresAfterRestart() async throws {
        let (report, moves) = try await restore(
            [saved("com.microsoft.teams2", ordinal: 0, x: -3794, title: "Chat | Microsoft Teams", windowID: 665)],
            live: [live("com.microsoft.teams2", ordinal: 0, title: "Activity | Microsoft Teams", windowID: 120)]
        )
        XCTAssertEqual(report.moved, 1)
        XCTAssertEqual(moves.first?.1.x, -3794)
    }

    /// Firefox restores its session after a reboot, so titles come back while
    /// list order does not. Each window must get its own frame.
    func test_firefox_uniqueTitles_eachWindowGetsItsOwnFrame() async throws {
        let (report, moves) = try await restore(
            [saved("org.mozilla.firefox", ordinal: 0, x: 100, title: "MakerWorld"),
             saved("org.mozilla.firefox", ordinal: 1, x: 900, title: "YouTube"),
             saved("org.mozilla.firefox", ordinal: 2, x: 1700, title: "MongoDB")],
            live: [live("org.mozilla.firefox", ordinal: 0, title: "MongoDB", windowID: 31),
                   live("org.mozilla.firefox", ordinal: 1, title: "MakerWorld", windowID: 32),
                   live("org.mozilla.firefox", ordinal: 2, title: "YouTube", windowID: 33)]
        )
        XCTAssertEqual(report.moved, 3)
        let xByTitle = Dictionary(uniqueKeysWithValues: moves.map { ($0.0.title ?? "", $0.1.x) })
        XCTAssertEqual(xByTitle, ["MakerWorld": 100, "YouTube": 900, "MongoDB": 1700])
    }

    /// The swap the old count-equal rule allowed: same number of windows,
    /// nothing but list order to go on. Left alone, and reported as such.
    func test_firefox_untitledWindows_areLeftAloneRatherThanSwapped() async throws {
        let (report, moves) = try await restore(
            [saved("org.mozilla.firefox", ordinal: 0, x: 100, title: nil),
             saved("org.mozilla.firefox", ordinal: 1, x: 900, title: nil)],
            live: [live("org.mozilla.firefox", ordinal: 0, title: "B", windowID: 31),
                   live("org.mozilla.firefox", ordinal: 1, title: "A", windowID: 32)]
        )
        XCTAssertTrue(moves.isEmpty)
        XCTAssertEqual(report.skippedUnidentified, 2)
        XCTAssertEqual(report.skippedMissingWindow, 0, "the windows are open, just not identifiable")
    }

    /// One window closed and one navigated: the titled ones restore, the two
    /// leftovers (one saved without a window, one live without a match) are
    /// not forced together.
    func test_firefox_closedAndNavigatedWindows_onlyTitledOnesMove() async throws {
        let (report, moves) = try await restore(
            [saved("org.mozilla.firefox", ordinal: 0, x: 100, title: "A"),
             saved("org.mozilla.firefox", ordinal: 1, x: 900, title: "B"),
             saved("org.mozilla.firefox", ordinal: 2, x: 1700, title: "C"),
             saved("org.mozilla.firefox", ordinal: 3, x: 2500, title: "D")],
            live: [live("org.mozilla.firefox", ordinal: 0, title: "A", windowID: 31),
                   live("org.mozilla.firefox", ordinal: 1, title: "B", windowID: 32),
                   live("org.mozilla.firefox", ordinal: 2, title: "C-navigated", windowID: 33)]
        )
        XCTAssertEqual(report.moved, 2)
        XCTAssertEqual(Set(moves.map(\.1.x)), [100, 900])
        XCTAssertEqual(report.skippedUnidentified, 2)
    }

    /// A saved window ID from before the reboot now belongs to another Terminal
    /// window. It must not decide the pairing; the titles do.
    func test_staleWindowIDFromEarlierBoot_isIgnored_titlesDecide() async throws {
        let (report, moves) = try await restore(
            [saved("com.apple.Terminal", ordinal: 0, x: 100, title: "build", windowID: 77),
             saved("com.apple.Terminal", ordinal: 1, x: 900, title: "logs", windowID: 78)],
            live: [live("com.apple.Terminal", ordinal: 0, title: "logs", windowID: 77),
                   live("com.apple.Terminal", ordinal: 1, title: "build", windowID: 78)]
        )
        XCTAssertEqual(report.moved, 2)
        let xByTitle = Dictionary(uniqueKeysWithValues: moves.map { ($0.0.title ?? "", $0.1.x) })
        XCTAssertEqual(xByTitle, ["build": 100, "logs": 900], "window 77 is 'logs' now, not 'build'")
    }

    // MARK: - Restoring every Desktop

    /// The 2026-10-01 post-reboot run: Teams, Messages and Firefox were all
    /// skipped as "ordinal-only". Now the sole windows and the uniquely
    /// titled ones go back to their Desktops.
    func test_crossSpace_afterReboot_soleAndTitledOrderOnlyWindowsMatch() {
        let entries = [
            saved("com.microsoft.teams2", ordinal: 0, x: -3794, title: "Chat | Microsoft Teams", space: 6),
            saved("com.apple.MobileSMS", ordinal: 0, x: -3772, title: "Messages", space: 0),
            saved("org.mozilla.firefox", ordinal: 0, x: 100, title: "MakerWorld", space: 0),
            saved("org.mozilla.firefox", ordinal: 1, x: 900, title: "YouTube", space: 2),
        ]
        let windows = [
            live("com.microsoft.teams2", ordinal: 0, title: "Activity | Microsoft Teams", windowID: 665),
            live("com.apple.MobileSMS", ordinal: 0, title: "Messages", windowID: 400),
            live("org.mozilla.firefox", ordinal: 0, title: "YouTube", windowID: 501),
            live("org.mozilla.firefox", ordinal: 1, title: "MakerWorld", windowID: 502),
        ]
        let matches = SpaceAssignmentPlanner.perWindowMatches(snapshot: entries, live: windows,
                                                              windowIDsValidSince: bootTime)
        let spaceByWindow = Dictionary(uniqueKeysWithValues: matches.map { ($0.windowID, $0.entry.spaceIndex) })
        XCTAssertEqual(spaceByWindow, [665: 6, 400: 0, 501: 2, 502: 0])
        XCTAssertEqual(matches.first { $0.windowID == 665 }?.matchedBy, "sole-window")
        XCTAssertEqual(matches.first { $0.windowID == 501 }?.matchedBy, "title")
    }

    /// Same boot: the window ID pairs an order-only window exactly, which
    /// the cross-Desktop restore previously never tried.
    func test_crossSpace_sameBoot_windowIDPairsOrderOnlyWindows() {
        let entries = [
            WindowEntry(bundleID: "org.mozilla.firefox", identity: .ordinal(0), ordinalInApp: 0,
                        displayFingerprintID: displayID, spaceIndex: 3, frame: frame(100),
                        isMinimized: false, isFullscreen: false, capturedAt: bootTime.addingTimeInterval(60),
                        windowID: 501),
            WindowEntry(bundleID: "org.mozilla.firefox", identity: .ordinal(1), ordinalInApp: 1,
                        displayFingerprintID: displayID, spaceIndex: 5, frame: frame(900),
                        isMinimized: false, isFullscreen: false, capturedAt: bootTime.addingTimeInterval(60),
                        windowID: 502),
        ]
        let windows = [live("org.mozilla.firefox", ordinal: 0, title: nil, windowID: 502),
                       live("org.mozilla.firefox", ordinal: 1, title: nil, windowID: 501)]
        let matches = SpaceAssignmentPlanner.perWindowMatches(snapshot: entries, live: windows,
                                                              windowIDsValidSince: bootTime)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: matches.map { ($0.windowID, $0.entry.spaceIndex) }),
                       [501: 3, 502: 5])
        XCTAssertTrue(matches.allSatisfy { $0.matchedBy == "windowID" })
    }

    /// After a reboot VS Code drew window numbers 283–291 again, in a new
    /// order. A stale ID must not override identity.
    func test_crossSpace_staleWindowID_doesNotOverrideIdentity() {
        let workspaceA = WindowIdentity.titleRegex(pattern: "editor.workspace", capturedValue: "PixPut")
        let workspaceB = WindowIdentity.titleRegex(pattern: "editor.workspace", capturedValue: "Platform")
        let entries = [saved("com.microsoft.VSCode", ordinal: 0, x: 100, title: nil, windowID: 283,
                             space: 1, identity: workspaceA)]
        let windows = [live("com.microsoft.VSCode", ordinal: 0, title: nil, windowID: 283, identity: workspaceB)]
        let matches = SpaceAssignmentPlanner.perWindowMatches(snapshot: entries, live: windows,
                                                              windowIDsValidSince: bootTime)
        XCTAssertTrue(matches.isEmpty, "window 283 is the Platform workspace this boot")
    }

    // MARK: - Reporting

    func test_unmatchedWindows_areClassifiedByWhy() {
        let saved = [
            saved("org.mozilla.firefox", ordinal: 0, x: 0, title: nil),
            saved("org.mozilla.firefox", ordinal: 1, x: 0, title: nil),
            saved("com.apple.MobileSMS", ordinal: 0, x: 0, title: nil),
        ]
        let summary = UnmatchedWindows.classify(
            unmatchedLive: ["org.mozilla.firefox", "org.mozilla.firefox", "com.tinyspeck.slackmacgap",
                            "com.apple.MobileSMS"],
            saved: saved,
            matched: [saved[2]]
        )
        XCTAssertEqual(summary.couldNotTellApart, [.init(bundleID: "org.mozilla.firefox", count: 2)])
        XCTAssertEqual(summary.notInSavedLayout, [.init(bundleID: "com.tinyspeck.slackmacgap", count: 1)])
        XCTAssertEqual(summary.newSinceCapture, [.init(bundleID: "com.apple.MobileSMS", count: 1)])
    }

    // MARK: - Saved titles

    func test_title_roundTripsAndIsOptionalInOlderSnapshots() throws {
        let entry = saved("org.mozilla.firefox", ordinal: 0, x: 100, title: "MakerWorld")
        let decoded = try JSONDecoder().decode(WindowEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded.title, "MakerWorld")

        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as! [String: Any]
        legacy.removeValue(forKey: "title")
        let legacyDecoded = try JSONDecoder().decode(WindowEntry.self,
                                                     from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(legacyDecoded.title)
    }

    func test_bootTime_rule() {
        XCTAssertTrue(BootDetection.windowIDIsCurrent(capturedAt: bootTime.addingTimeInterval(1), bootTime: bootTime))
        XCTAssertFalse(BootDetection.windowIDIsCurrent(capturedAt: beforeBoot, bootTime: bootTime))
        XCTAssertTrue(BootDetection.windowIDIsCurrent(capturedAt: beforeBoot, bootTime: nil))
        XCTAssertNotNil(BootDetection.currentBootTime)
        XCTAssertLessThan(BootDetection.currentBootTime!, Date())
    }
}
