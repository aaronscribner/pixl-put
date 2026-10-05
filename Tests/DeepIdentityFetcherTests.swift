import XCTest
@testable import PixlPutCore

/// Tests for `DeepIdentityFetcher` and the small per-bundle providers
/// (`XcodeProvider`, `TerminalCWDProvider`).
///
/// The "happy path" of `identitiesForApp` (executor returns a real
/// `NSAppleEventDescriptor` that the parser turns into identities) is
/// exercised via the manual `quickstart.md` scenarios — constructing
/// `NSAppleEventDescriptor` from inside `xctest` triggers Apple Event
/// Manager initialisation that blocks in headless test environments.
/// Unit tests cover the no-descriptor paths: scripted-bundle inventory,
/// session-scoped denial caching, and unsupported-bundle short-circuit.

/// Fake executor that always throws a pre-staged error. Lets us exercise
/// the denial path without invoking the real AppleScript engine.
final class ThrowingAppleScriptExecutor: AppleScriptExecuting, @unchecked Sendable {
    var stagedError: AppleScriptError = AppleScriptError(
        kind: .automationDenied(bundleID: "test"),
        message: "test denial"
    )

    func execute(_ source: String) throws -> NSAppleEventDescriptor {
        throw stagedError
    }
}

final class DeepIdentityFetcherTests: XCTestCase {

    // Unscripted bundle returns nil without invoking the executor at all.
    func test_fetcher_unscriptedBundle_returnsNilWithoutInvocation() async {
        let exec = ThrowingAppleScriptExecutor()
        let fetcher = DeepIdentityFetcher(executor: exec)
        let result = await fetcher.identitiesForApp(bundleID: "com.unknown.app")
        XCTAssertNil(result)
        // If the executor had been invoked, it would have thrown — but the
        // unscripted-bundle short-circuit must run before any execute() call.
        let denied = await fetcher.isDenied("com.unknown.app")
        XCTAssertFalse(denied, "Unscripted bundles must NOT be flagged as denied.")
    }

    // Automation-denied: result is nil + bundle cached as denied.
    func test_fetcher_whenAutomationDenied_thenBundleIsCachedAsDeniedForSession() async {
        let exec = ThrowingAppleScriptExecutor()
        exec.stagedError = AppleScriptError(
            kind: .automationDenied(bundleID: "Brave Browser"),
            message: "Not authorized"
        )
        let fetcher = DeepIdentityFetcher(executor: exec)

        let result = await fetcher.identitiesForApp(bundleID: "com.brave.Browser")
        XCTAssertNil(result)
        let denied = await fetcher.isDenied("com.brave.Browser")
        XCTAssertTrue(denied)
    }

    // Other error kinds (timeout / not-running / execution-failed) DO NOT
    // mark the bundle as denied — the user might grant later, or the app
    // might start, so we don't want to lock them out for the session.
    func test_fetcher_whenAppNotRunning_thenBundleIsNotCachedAsDenied() async {
        let exec = ThrowingAppleScriptExecutor()
        exec.stagedError = AppleScriptError(
            kind: .targetAppNotRunning,
            message: "no process"
        )
        let fetcher = DeepIdentityFetcher(executor: exec)

        let result = await fetcher.identitiesForApp(bundleID: "com.brave.Browser")
        XCTAssertNil(result)
        let denied = await fetcher.isDenied("com.brave.Browser")
        XCTAssertFalse(denied, "Non-permission errors must not poison the session cache.")
    }

    func test_fetcher_whenTimedOut_thenBundleIsNotCachedAsDenied() async {
        let exec = ThrowingAppleScriptExecutor()
        exec.stagedError = AppleScriptError(kind: .timedOut, message: "")
        let fetcher = DeepIdentityFetcher(executor: exec)
        _ = await fetcher.identitiesForApp(bundleID: "com.brave.Browser")
        let denied = await fetcher.isDenied("com.brave.Browser")
        XCTAssertFalse(denied)
    }

    func test_fetcher_whenExecutionFailed_thenBundleIsNotCachedAsDenied() async {
        let exec = ThrowingAppleScriptExecutor()
        exec.stagedError = AppleScriptError(kind: .executionFailed(code: -42), message: "")
        let fetcher = DeepIdentityFetcher(executor: exec)
        _ = await fetcher.identitiesForApp(bundleID: "com.brave.Browser")
        let denied = await fetcher.isDenied("com.brave.Browser")
        XCTAssertFalse(denied)
    }

    // resetSession clears the denial cache (FR-015: at most one prompt per session)
    func test_fetcher_resetSession_clearsDenials() async {
        let exec = ThrowingAppleScriptExecutor()
        exec.stagedError = AppleScriptError(
            kind: .automationDenied(bundleID: "Brave Browser"),
            message: ""
        )
        let fetcher = DeepIdentityFetcher(executor: exec)
        _ = await fetcher.identitiesForApp(bundleID: "com.brave.Browser")
        let deniedAfterCall = await fetcher.isDenied("com.brave.Browser")
        XCTAssertTrue(deniedAfterCall)

        await fetcher.resetSession()
        let deniedAfterReset = await fetcher.isDenied("com.brave.Browser")
        XCTAssertFalse(deniedAfterReset)
    }

    // Scripted-bundle inventory exposed via static accessor (used by SnapshotEngine + AXRestorerBackend)
    func test_fetcher_isScripted_matchesRegistry() {
        XCTAssertTrue(DeepIdentityFetcher.isScripted(bundleID: "com.brave.Browser"))
        XCTAssertTrue(DeepIdentityFetcher.isScripted(bundleID: "com.microsoft.edgemac"))
        XCTAssertTrue(DeepIdentityFetcher.isScripted(bundleID: "com.google.Chrome"))
        XCTAssertTrue(DeepIdentityFetcher.isScripted(bundleID: "company.thebrowser.Browser"))
        XCTAssertTrue(DeepIdentityFetcher.isScripted(bundleID: "com.apple.Safari"))
        XCTAssertTrue(DeepIdentityFetcher.isScripted(bundleID: "com.apple.dt.Xcode"))
        XCTAssertTrue(DeepIdentityFetcher.isScripted(bundleID: "com.googlecode.iterm2"))
        XCTAssertFalse(DeepIdentityFetcher.isScripted(bundleID: "com.microsoft.VSCode"))
        XCTAssertFalse(DeepIdentityFetcher.isScripted(bundleID: "com.apple.Terminal"))
        XCTAssertFalse(DeepIdentityFetcher.isScripted(bundleID: "com.unknown.app"))
    }
}

/// Joining AppleScript results to AX windows. Scripts list an app's windows
/// on every Space; AX lists only the active Space's.
final class DeepIdentityJoinTests: XCTestCase {

    private let brave = "com.brave.Browser"
    private let here = URL(string: "https://example.com/on-this-space")!
    private let elsewhere = URL(string: "https://example.com/on-another-space")!

    /// The script saw a window on another Space first. Joined by position,
    /// this Space's only window took that window's document.
    func test_titleScriptApp_joinsByTitleNotPosition() {
        let docs = ScriptRegistry.documentsByTitle(fromPairs: [
            ["Elsewhere", elsewhere.absoluteString], ["Here", here.absoluteString],
        ])
        let inputs = DeepIdentityFetcher.signalInputs(
            bundleID: brave, indexInApp: 0, title: "Here", axDocumentURL: nil,
            identitiesByIndex: [brave: [0: .documentPath(elsewhere)]],
            documentsByTitle: [brave: docs]
        )
        XCTAssertEqual(inputs.documentURL, here)
        XCTAssertNil(inputs.appProviderIdentity, "the position join must not apply")
    }

    /// One title showing two different documents cannot be told apart by
    /// title; no document beats a guessed one.
    func test_ambiguousTitle_yieldsNoDocument() {
        let docs = ScriptRegistry.documentsByTitle(fromPairs: [
            ["New Tab", "https://a.example/"], ["New Tab", "https://b.example/"],
        ])
        let inputs = DeepIdentityFetcher.signalInputs(
            bundleID: brave, indexInApp: 0, title: "New Tab", axDocumentURL: nil,
            identitiesByIndex: [:], documentsByTitle: [brave: docs]
        )
        XCTAssertNil(inputs.documentURL)
    }

    /// Two windows on the same document share a title; that is not ambiguous.
    func test_sameTitleSameDocument_isKept() {
        let docs = ScriptRegistry.documentsByTitle(fromPairs: [
            ["Here", here.absoluteString], ["Here", here.absoluteString],
        ])
        XCTAssertEqual(docs["Here"], here)
    }

    /// AX and yabai window titles carry the browser's name; AppleScript
    /// window names do not. Before this, 26 of 26 Brave windows on inactive
    /// Spaces went unmatched.
    func test_windowTitleWithAppSuffix_findsScriptWindowName() {
        let docs = ["Here": here]
        XCTAssertEqual(DeepIdentityFetcher.documentURL(forWindowTitle: "Here - Brave", bundleID: brave, in: docs), here)
        XCTAssertEqual(DeepIdentityFetcher.documentURL(forWindowTitle: "Here - Brave - Work", bundleID: brave, in: docs), here,
                       "a profile name after the marker")
        XCTAssertEqual(DeepIdentityFetcher.documentURL(forWindowTitle: "Here - Microsoft Edge", bundleID: "com.microsoft.edgemac", in: docs), here)
        XCTAssertEqual(DeepIdentityFetcher.documentURL(forWindowTitle: "Here - Google Chrome", bundleID: "com.google.Chrome", in: docs), here)
    }

    func test_pageTitleContainingDash_keepsItsOwnDashes() {
        let docs = ["A - B": here, "A": elsewhere]
        XCTAssertEqual(DeepIdentityFetcher.documentURL(forWindowTitle: "A - B - Brave", bundleID: brave, in: docs), here)
    }

    func test_exactTitleMatches_andOnlyTheAppMarkerIsStripped() {
        XCTAssertEqual(DeepIdentityFetcher.documentURL(forWindowTitle: "Here", bundleID: "company.thebrowser.Browser", in: ["Here": here]), here)
        XCTAssertNil(DeepIdentityFetcher.documentURL(forWindowTitle: "Here - Elsewhere", bundleID: brave, in: ["Here": here]))
        XCTAssertNil(DeepIdentityFetcher.documentURL(forWindowTitle: "Brave", bundleID: brave, in: ["": here]),
                     "a bare marker has no page title to look up")
    }

    func test_axDocument_winsOverTitleJoin() {
        let ax = URL(string: "https://example.com/from-ax")!
        let inputs = DeepIdentityFetcher.signalInputs(
            bundleID: "com.brave.Browser", indexInApp: 0, title: "Tab", axDocumentURL: ax,
            identitiesByIndex: [:],
            documentsByTitle: ["com.brave.Browser": ["Tab": URL(string: "https://example.com/other")!]]
        )
        XCTAssertEqual(inputs.documentURL, ax)
    }

    /// Scripted apps without a documents-by-title script keep the position join.
    func test_appWithoutTitleScript_keepsPositionJoin() {
        let workspace = WindowIdentity.editorWorkspace(URL(fileURLWithPath: "/Users/u/App.xcodeproj"))
        let inputs = DeepIdentityFetcher.signalInputs(
            bundleID: "com.apple.dt.Xcode", indexInApp: 1, title: "App", axDocumentURL: nil,
            identitiesByIndex: ["com.apple.dt.Xcode": [1: workspace]], documentsByTitle: [:]
        )
        XCTAssertEqual(inputs.appProviderIdentity, workspace)
    }

    /// Capture and the cross-Space restore must resolve a window to the same
    /// identity, or a saved window never matches its live one.
    func test_titleJoinedIdentity_matchesCrossSpaceIndex() {
        // Script names are page titles; window titles carry " - Brave".
        let docs = [brave: ["Here": here]]
        let inputs = DeepIdentityFetcher.signalInputs(
            bundleID: brave, indexInApp: 0, title: "Here - Brave", axDocumentURL: nil,
            identitiesByIndex: [:], documentsByTitle: docs
        )
        let captured = WindowIdentityResolver.defaultV1().resolve(WindowSignal(
            bundleID: brave, title: "Here - Brave", documentURL: inputs.documentURL,
            appProviderIdentity: inputs.appProviderIdentity, creationOrdinal: 0
        ))

        let rows = NativeWindowQuery.build(
            descriptors: [CGWindowDescriptor(
                windowID: 5, ownerPID: 7, bundleID: brave, title: "",
                bounds: CGRectCodable(x: 0, y: 0, width: 800, height: 600), isOnScreen: false
            )],
            spaceIDsByWindow: [5: [40]],
            orderedSpaceIDs: [30, 40],
            titlesByWindowID: [5: "Here - Brave"]
        )
        let live = CrossSpaceWindowIndex.build(
            yabaiWindows: rows, bundleIDByPID: [7: brave],
            documentsByTitle: docs, displayBoundsByID: [:]
        )

        XCTAssertEqual(captured, .documentPath(here))
        XCTAssertEqual(live.first?.live.identity, captured)
    }
}

final class XcodeAndTerminalProviderTests: XCTestCase {

    func test_xcodeProvider_identityFromPath_returnsEditorWorkspace() {
        let p = XcodeProvider()
        guard case .editorWorkspace(let url) = p.identity(fromWorkspacePath: "/Users/u/Code/pixput.xcodeproj") else {
            return XCTFail("Expected editorWorkspace")
        }
        XCTAssertEqual(url.path, "/Users/u/Code/pixput.xcodeproj")
    }

    func test_xcodeProvider_emptyPath_returnsNil() {
        XCTAssertNil(XcodeProvider().identity(fromWorkspacePath: ""))
    }

    func test_xcodeProvider_supportsXcodeOnly() {
        let p = XcodeProvider()
        XCTAssertTrue(p.supports(bundleID: "com.apple.dt.Xcode"))
        XCTAssertFalse(p.supports(bundleID: "com.microsoft.VSCode"))
    }

    func test_terminalProvider_identityFromCWD_returnsTerminalCWD() {
        let p = TerminalCWDProvider()
        guard case .terminalCWD(let url) = p.identity(fromCWDPath: "/Users/u/work") else {
            return XCTFail("Expected terminalCWD")
        }
        XCTAssertEqual(url.path, "/Users/u/work")
    }

    func test_terminalProvider_emptyPath_returnsNil() {
        XCTAssertNil(TerminalCWDProvider().identity(fromCWDPath: ""))
    }

    func test_terminalProvider_supportsITermOnly() {
        let p = TerminalCWDProvider()
        XCTAssertTrue(p.supports(bundleID: "com.googlecode.iterm2"))
        XCTAssertFalse(p.supports(bundleID: "com.apple.Terminal"))
    }
}
