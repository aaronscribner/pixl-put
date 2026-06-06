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
