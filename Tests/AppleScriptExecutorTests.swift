import XCTest
@testable import PixlPutCore

/// `AppleScriptExecutor.execute(_:)` itself is exercised end-to-end via the
/// manual `quickstart.md` scenarios that touch browsers and editors —
/// running real AppleScript from `xctest` (a CLI process without a proper
/// app bundle) triggers Apple Event Manager initialisation that blocks in
/// headless test environments. These unit tests therefore cover only the
/// pieces that don't require constructing `NSAppleEventDescriptor` values.
final class AppleScriptExecutorTests: XCTestCase {

    // AppleScriptError equality semantics — used by callers to compare
    // .automationDenied results across calls.
    func test_appleScriptError_kindEquatable() {
        let a = AppleScriptError.Kind.automationDenied(bundleID: "com.brave.Browser")
        let b = AppleScriptError.Kind.automationDenied(bundleID: "com.brave.Browser")
        let c = AppleScriptError.Kind.automationDenied(bundleID: "com.google.Chrome")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(AppleScriptError.Kind.targetAppNotRunning, .targetAppNotRunning)
        XCTAssertEqual(AppleScriptError.Kind.compileFailed, .compileFailed)
        XCTAssertEqual(AppleScriptError.Kind.executionFailed(code: -1), .executionFailed(code: -1))
        XCTAssertNotEqual(AppleScriptError.Kind.executionFailed(code: -1), .executionFailed(code: -2))
    }

    // Constructor preserves kind + message
    func test_appleScriptError_construction() {
        let err = AppleScriptError(
            kind: .automationDenied(bundleID: "test"),
            message: "denied"
        )
        XCTAssertEqual(err.kind, .automationDenied(bundleID: "test"))
        XCTAssertEqual(err.message, "denied")
    }

    // REGRESSION: empty AE list previously crashed parsers with
    // `Range requires lowerBound <= upperBound` (the `1...0` trap).
    // Happens when a scripted app is running but has zero windows.
    // We only construct .list() with no items here — that path doesn't
    // touch the Apple Event Manager dispatch the way insertion does,
    // so xctest stays stable.
    func test_stringList_emptyDescriptor_returnsEmptyArrayWithoutTrap() {
        let empty = NSAppleEventDescriptor.list()
        XCTAssertEqual(empty.numberOfItems, 0)
        XCTAssertEqual(AppleScriptResult.stringList(empty), [])
    }

    func test_nestedStringList_emptyDescriptor_returnsEmptyArrayWithoutTrap() {
        let empty = NSAppleEventDescriptor.list()
        XCTAssertEqual(empty.numberOfItems, 0)
        XCTAssertEqual(AppleScriptResult.nestedStringList(empty), [])
    }
}
