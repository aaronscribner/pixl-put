import XCTest
import CoreGraphics
@testable import PixlPutCore

/// Restore after a reboot, end to end at the unit level: boot detection, the
/// login-storm settle rule, yabai's window query as the cross-Space view,
/// identity for windows AX cannot see, and window-to-entry matching that
/// carries frames as well as Spaces.
final class CrossSpaceRestoreTests: XCTestCase {

    // MARK: - Boot detection and settle

    func test_freshBoot_isUptimeUnderThreshold() {
        XCTAssertTrue(BootDetection.isFreshBoot(uptime: 120))
        XCTAssertTrue(BootDetection.isFreshBoot(uptime: 14 * 60))
        XCTAssertFalse(BootDetection.isFreshBoot(uptime: 15 * 60))
        XCTAssertFalse(BootDetection.isFreshBoot(uptime: 3 * 3600))
        XCTAssertFalse(BootDetection.isFreshBoot(uptime: -1))
    }

    func test_settleTracker_requiresConsecutiveEqualSamples() {
        var t = SettleTracker(requiredStableSamples: 3)
        XCTAssertFalse(t.isSettled)
        t.record(10); t.record(14); t.record(14)
        XCTAssertFalse(t.isSettled, "only two equal samples")
        t.record(14)
        XCTAssertTrue(t.isSettled)
        t.record(15)
        XCTAssertFalse(t.isSettled, "a new app appearing unsettles it again")
        XCTAssertEqual(t.latest, 15)
    }

    // MARK: - yabai JSON

    private let yabaiWindowsJSON = """
    [
      {"id":613,"pid":900,"app":"Code","title":"main.swift — PixPut — Visual Studio Code",
       "frame":{"x":0.0,"y":25.0,"w":1900.0,"h":1100.0},"role":"AXWindow","subrole":"AXStandardWindow",
       "display":1,"space":3,"level":0,"is-visible":false,"is-minimized":false,"is-hidden":false,
       "is-sticky":false,"is-native-fullscreen":false,"has-focus":false,"opacity":1.0},
      {"id":620,"pid":901,"app":"Brave Browser","title":"Keystone — Netflix TechBlog",
       "frame":{"x":1920.0,"y":25.0,"w":1800.0,"h":1000.0},"role":"AXWindow","subrole":"AXStandardWindow",
       "display":1,"space":1,"is-sticky":false,"is-minimized":false},
      {"id":621,"pid":901,"app":"Brave Browser","title":"",
       "frame":{"x":0.0,"y":0.0,"w":10.0,"h":10.0},"role":"AXWindow","subrole":"AXUnknown","space":1},
      {"id":700,"pid":902,"app":"Stickies","title":"note","frame":{"x":5,"y":5,"w":300,"h":300},
       "role":"AXWindow","subrole":"AXStandardWindow","space":1,"is-sticky":true}
    ]
    """

    func test_yabaiWindows_decodeAndClassify() throws {
        let windows = try YabaiJSON.windows(from: Data(yabaiWindowsJSON.utf8))
        XCTAssertEqual(windows.count, 4)
        let code = try XCTUnwrap(windows.first { $0.id == 613 })
        XCTAssertEqual(code.pixputSpaceIndex, 2, "yabai index 3 is PixPut index 2")
        XCTAssertTrue(code.isStandardPlacement)
        XCTAssertEqual(code.frame.rect, CGRectCodable(x: 0, y: 25, width: 1900, height: 1100))
        XCTAssertFalse(try XCTUnwrap(windows.first { $0.id == 621 }).isStandardPlacement, "non-standard subrole")
        XCTAssertFalse(try XCTUnwrap(windows.first { $0.id == 700 }).isStandardPlacement, "sticky windows are on every Space")
    }

    func test_yabaiSpaces_decode() throws {
        let json = """
        [{"id":3,"uuid":"x","index":1,"label":"","type":"bsp","display":1,"windows":[620],"has-focus":true,"is-visible":true},
         {"id":5,"index":3,"display":1,"has-focus":false}]
        """
        let spaces = try YabaiJSON.spaces(from: Data(json.utf8))
        XCTAssertEqual(spaces.map(\.index), [1, 3])
        XCTAssertEqual(spaces[0].hasFocus, true)
    }

    // MARK: - Cross-Space index

    private let displays = ["d1": CGRectCodable(x: 0, y: 0, width: 3840, height: 2160)]

    func test_index_usesAXIdentityWhenAvailable_andTitleOrDocumentOtherwise() throws {
        let windows = try YabaiJSON.windows(from: Data(yabaiWindowsJSON.utf8))
        let pids: [pid_t: String] = [900: "com.microsoft.VSCode", 901: "com.brave.Browser", 902: "com.apple.Stickies"]
        let axBrave = LiveWindow(
            bundleID: "com.brave.Browser",
            identity: .documentPath(URL(string: "https://netflixtechblog.com/keystone")!),
            ordinalInApp: 4,
            currentFrame: CGRectCodable(x: 1920, y: 25, width: 1800, height: 1000),
            currentDisplayFingerprintID: "d1", windowID: 620, isFullscreen: false)

        let index = CrossSpaceWindowIndex.build(
            yabaiWindows: windows,
            bundleIDByPID: pids,
            axLiveByWindowID: [620: axBrave],
            documentsByTitle: [:],
            displayBoundsByID: displays
        )
        XCTAssertEqual(index.map { $0.live.windowID }, [620, 613], "sorted by bundle, sticky and tiny windows dropped")

        let brave = index[0]
        XCTAssertEqual(brave.live, axBrave, "AX identity is authoritative on the active Space")
        XCTAssertEqual(brave.spaceIndex, 0)

        let code = index[1]
        XCTAssertEqual(code.spaceIndex, 2)
        XCTAssertEqual(code.live.identity, .titleRegex(pattern: "editor.workspace", capturedValue: "PixPut"),
                       "VS Code resolves from the title exactly as capture does")
        XCTAssertEqual(code.live.currentDisplayFingerprintID, "d1")
    }

    func test_index_documentsByTitle_giveBrowsersOnOtherSpacesADocumentIdentity() throws {
        let windows = try YabaiJSON.windows(from: Data(yabaiWindowsJSON.utf8))
        let pids: [pid_t: String] = [900: "com.microsoft.VSCode", 901: "com.brave.Browser"]
        let url = URL(string: "https://netflixtechblog.com/keystone-real-time")!
        let index = CrossSpaceWindowIndex.build(
            yabaiWindows: windows,
            bundleIDByPID: pids,
            documentsByTitle: ["com.brave.Browser": ["Keystone — Netflix TechBlog": url]],
            displayBoundsByID: displays
        )
        let brave = try XCTUnwrap(index.first { $0.live.windowID == 620 })
        XCTAssertEqual(brave.live.identity, .documentPath(url))
    }

    func test_index_unknownPIDsAreDropped() throws {
        let windows = try YabaiJSON.windows(from: Data(yabaiWindowsJSON.utf8))
        let index = CrossSpaceWindowIndex.build(
            yabaiWindows: windows, bundleIDByPID: [900: "com.microsoft.VSCode"], displayBoundsByID: displays)
        XCTAssertEqual(index.map { $0.live.windowID }, [613])
    }

    // MARK: - Matching carries frames

    private func entry(_ bundleID: String, identity: WindowIdentity, space: Int, ordinal: Int = 0,
                       frame: CGRectCodable = CGRectCodable(x: 0, y: 0, width: 100, height: 100)) -> WindowEntry {
        WindowEntry(bundleID: bundleID, identity: identity, ordinalInApp: ordinal,
                    displayFingerprintID: "d1", spaceIndex: space, frame: frame,
                    isMinimized: false, isFullscreen: false, capturedAt: Date(timeIntervalSince1970: 0))
    }

    private func live(_ bundleID: String, identity: WindowIdentity, windowID: CGWindowID?, ordinal: Int = 0) -> LiveWindow {
        LiveWindow(bundleID: bundleID, identity: identity, ordinalInApp: ordinal,
                   currentFrame: CGRectCodable(x: 0, y: 0, width: 100, height: 100),
                   currentDisplayFingerprintID: "d1", windowID: windowID, isFullscreen: false)
    }

    private let workspace = WindowIdentity.titleRegex(pattern: "editor.workspace", capturedValue: "PixPut")

    func test_matches_pairEntryWithFrame() {
        let target = CGRectCodable(x: 1920, y: 25, width: 1800, height: 1000)
        let matches = SpaceAssignmentPlanner.perWindowMatches(
            snapshot: [entry("com.microsoft.VSCode", identity: workspace, space: 3, frame: target)],
            live: [live("com.microsoft.VSCode", identity: workspace, windowID: 613, ordinal: 9)]
        )
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].entry.frame, target)
        XCTAssertEqual(matches[0].entry.spaceIndex, 3)
        XCTAssertEqual(matches[0].windowID, 613)
    }

    func test_matches_twoWindowsOfOneWorkspaceOnOneSpace_bothPlaced_eachEntryOnce() {
        let a = entry("com.microsoft.VSCode", identity: workspace, space: 3, ordinal: 0,
                      frame: CGRectCodable(x: 0, y: 0, width: 500, height: 500))
        let b = entry("com.microsoft.VSCode", identity: workspace, space: 3, ordinal: 1,
                      frame: CGRectCodable(x: 600, y: 0, width: 500, height: 500))
        let matches = SpaceAssignmentPlanner.perWindowMatches(
            snapshot: [a, b],
            live: [live("com.microsoft.VSCode", identity: workspace, windowID: 1, ordinal: 7),
                   live("com.microsoft.VSCode", identity: workspace, windowID: 2, ordinal: 8)]
        )
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(Set(matches.map(\.entry)), [a, b], "each captured entry is consumed exactly once")
        XCTAssertTrue(matches.allSatisfy { $0.entry.spaceIndex == 3 })
    }

    func test_matches_sameIdentityOnTwoSpaces_needsExactOrdinal() {
        let matches = SpaceAssignmentPlanner.perWindowMatches(
            snapshot: [entry("com.brave.Browser", identity: .documentPath(URL(string: "https://a")!), space: 1, ordinal: 0),
                       entry("com.brave.Browser", identity: .documentPath(URL(string: "https://a")!), space: 5, ordinal: 3)],
            live: [live("com.brave.Browser", identity: .documentPath(URL(string: "https://a")!), windowID: 10, ordinal: 3),
                   live("com.brave.Browser", identity: .documentPath(URL(string: "https://a")!), windowID: 11, ordinal: 9)]
        )
        XCTAssertEqual(matches.map(\.windowID), [10])
        XCTAssertEqual(matches[0].entry.spaceIndex, 5)
    }

    // MARK: - AppleScript result shaping (pure halves)

    func test_documentsByTitle_pathsBecomeFileURLs_andAmbiguousTitlesAreDropped() {
        let docs = ScriptRegistry.documentsByTitle(fromPairs: [
            ["Downloads", "/Users/me/Downloads"],
            ["Keystone — Netflix TechBlog", "https://netflixtechblog.com/keystone"],
            ["Untitled", ""],
            ["Dup", "https://a.example"],
            ["Dup", "https://b.example"],
        ])
        XCTAssertEqual(docs["Downloads"], URL(fileURLWithPath: "/Users/me/Downloads").standardizedFileURL)
        XCTAssertEqual(docs["Keystone — Netflix TechBlog"], URL(string: "https://netflixtechblog.com/keystone"))
        XCTAssertNil(docs["Untitled"])
        XCTAssertNil(docs["Dup"], "one title, two documents: unresolvable")
    }

    func test_finderFolders_becomeDocumentPathIdentities() {
        let ids = ScriptRegistry.folderIdentities(fromPaths: ["/Users/me/Downloads/", "", "/tmp"])
        XCTAssertEqual(ids[0], .documentPath(URL(fileURLWithPath: "/Users/me/Downloads/").standardizedFileURL))
        XCTAssertNil(ids[1])
        XCTAssertEqual(ids[2], .documentPath(URL(fileURLWithPath: "/tmp").standardizedFileURL))
    }

    func test_finderIsScripted_andReportsDocumentsByTitle() {
        XCTAssertTrue(DeepIdentityFetcher.isScripted(bundleID: "com.apple.finder"))
        XCTAssertTrue(DeepIdentityFetcher.reportsDocumentsByTitle(bundleID: "com.apple.finder"))
        XCTAssertTrue(DeepIdentityFetcher.reportsDocumentsByTitle(bundleID: "com.brave.Browser"))
        XCTAssertFalse(DeepIdentityFetcher.reportsDocumentsByTitle(bundleID: "com.apple.Stickies"))
    }

    func test_passthrough_acceptsFinderFolderIdentity_butNotTitleOrOrdinal() {
        let folder = WindowIdentity.documentPath(URL(fileURLWithPath: "/Users/me/Downloads"))
        let resolver = WindowIdentityResolver.defaultV1()
        let resolved = resolver.resolve(WindowSignal(
            bundleID: "com.apple.finder", title: "Downloads", documentURL: nil,
            appProviderIdentity: folder, creationOrdinal: 4))
        XCTAssertEqual(resolved, folder)

        let passthrough = AppProviderPassthrough()
        XCTAssertNil(passthrough.resolve(WindowSignal(
            bundleID: "x", title: "t", appProviderIdentity: .ordinal(1), creationOrdinal: 1)))
        XCTAssertNil(passthrough.resolve(WindowSignal(
            bundleID: "x", title: "t", appProviderIdentity: .titleRegex(pattern: "p", capturedValue: "v"), creationOrdinal: 1)))
    }
}
