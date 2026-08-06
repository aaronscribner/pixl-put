import XCTest
import CoreGraphics
@testable import PixlPutCore

/// Restore matching, windowID-first. The CG window number is stable for the
/// owning app's process lifetime, so it pairs snapshot entries to live
/// windows with an integer compare — bypassing the identity/ordinal
/// heuristics and the failure modes they carry.
final class WindowIDMatchingTests: XCTestCase {

    private let displayID = "display-A"

    private func entry(
        bundle: String = "com.brave.Browser",
        identity: WindowIdentity,
        ordinal: Int = 0,
        frame: CGRectCodable,
        windowID: CGWindowID?
    ) -> WindowEntry {
        WindowEntry(
            bundleID: bundle, identity: identity, ordinalInApp: ordinal,
            displayFingerprintID: displayID, spaceIndex: 0, frame: frame,
            isMinimized: false, isFullscreen: false,
            capturedAt: Date(timeIntervalSince1970: 0), windowID: windowID
        )
    }

    private func liveWindow(
        bundle: String = "com.brave.Browser",
        identity: WindowIdentity,
        ordinal: Int = 0,
        frame: CGRectCodable,
        windowID: CGWindowID?
    ) -> LiveWindow {
        LiveWindow(
            bundleID: bundle, identity: identity, ordinalInApp: ordinal,
            currentFrame: frame, currentDisplayFingerprintID: displayID,
            windowID: windowID, isFullscreen: false
        )
    }

    private func snapshot(_ entries: [WindowEntry]) -> Snapshot {
        Snapshot(
            displayConfigurationID: "cfg",
            displays: [DisplaySnapshot(
                fingerprint: DisplayFingerprint(vendorID: 1, productID: 1, modelNumber: 1,
                                                serialNumber: 1, displayUUID: displayID),
                bounds: CGRectCodable(x: 0, y: 0, width: 3840, height: 2160),
                isPrimary: true, scaleFactor: 2.0)],
            capturedAt: Date(timeIntervalSince1970: 0),
            trigger: .manual,
            windows: entries
        )
    }

    private let target = CGRectCodable(x: 100, y: 100, width: 1200, height: 900)
    private let elsewhere = CGRectCodable(x: 700, y: 500, width: 800, height: 600)

    /// The scenario identity matching cannot solve: the browser's tab set
    /// changed since capture, so identity no longer matches — but it is the
    /// same physical window, and the windowID knows it.
    func test_windowID_pairsWindow_evenWhenIdentityChangedSinceCapture() async throws {
        let capturedTabs = WindowIdentity.browserTabSet([URL(string: "https://old.example")!])
        let currentTabs = WindowIdentity.browserTabSet([URL(string: "https://new.example")!])

        let snap = snapshot([entry(identity: capturedTabs, frame: target, windowID: 101)])
        let backend = FakeBackend(live: [liveWindow(identity: currentTabs, frame: elsewhere, windowID: 101)])
        let restorer = Restorer(backend: backend, tolerancePoints: 1.0)

        let report = try await restorer.apply(snap, activeDisplayFingerprintIDs: [displayID])

        XCTAssertEqual(report.moved, 1, "same windowID must pair despite the identity drift")
        XCTAssertEqual(report.skippedMissingWindow, 0)
        let frames = await backend.moveRequestFrames()
        XCTAssertEqual(frames.first?.x, target.x)
    }

    /// Ordinal-identity entries are normally skipped when the window count
    /// changed (ordinal mapping unreliable). A windowID match overrides that
    /// caution: the pairing isn't a guess anymore.
    func test_windowID_pairsOrdinalWindow_despiteOrdinalCountMismatch() async throws {
        // Snapshot: two ordinal windows. Live: only one left — a count
        // mismatch that poisons ordinal matching for the whole bundle.
        let snap = snapshot([
            entry(bundle: "com.apple.Terminal", identity: .ordinal(0), ordinal: 0, frame: target, windowID: 301),
            entry(bundle: "com.apple.Terminal", identity: .ordinal(1), ordinal: 1, frame: elsewhere, windowID: 302),
        ])
        let backend = FakeBackend(live: [
            liveWindow(bundle: "com.apple.Terminal", identity: .ordinal(0), ordinal: 0,
                       frame: elsewhere, windowID: 301),
        ])
        let restorer = Restorer(backend: backend, tolerancePoints: 1.0)

        let report = try await restorer.apply(snap, activeDisplayFingerprintIDs: [displayID])

        XCTAssertEqual(report.moved, 1, "windowID 301 is certain; the count-mismatch guard is for guesses")
        let frames = await backend.moveRequestFrames()
        XCTAssertEqual(frames.first?.x, target.x, "must get entry 301's frame, not 302's")
    }

    /// App quit and something else drew the same window number — the bundle
    /// check must force the entry down the identity-fallback path instead of
    /// moving a stranger's window.
    func test_windowIDReuseByDifferentApp_doesNotPair() async throws {
        let snap = snapshot([entry(bundle: "com.brave.Browser",
                                   identity: .browserTabSet([URL(string: "https://a.example")!]),
                                   frame: target, windowID: 101)])
        let backend = FakeBackend(live: [liveWindow(bundle: "com.microsoft.VSCode",
                                                    identity: .ordinal(0),
                                                    frame: elsewhere, windowID: 101)])
        let restorer = Restorer(backend: backend, tolerancePoints: 1.0)

        let report = try await restorer.apply(snap, activeDisplayFingerprintIDs: [displayID])

        XCTAssertEqual(report.moved, 0)
        XCTAssertEqual(report.skippedMissingWindow, 1, "no identity match either — reported missing")
    }

    /// Legacy snapshots (windowID nil) still restore via identity — the join
    /// is an upgrade, not a requirement.
    func test_nilWindowID_fallsBackToIdentityMatching() async throws {
        let tabs = WindowIdentity.browserTabSet([URL(string: "https://a.example")!])
        let snap = snapshot([entry(identity: tabs, frame: target, windowID: nil)])
        let backend = FakeBackend(live: [liveWindow(identity: tabs, frame: elsewhere, windowID: 404)])
        let restorer = Restorer(backend: backend, tolerancePoints: 1.0)

        let report = try await restorer.apply(snap, activeDisplayFingerprintIDs: [displayID])

        XCTAssertEqual(report.moved, 1)
    }

    /// A live window claimed by the windowID join must not ALSO satisfy an
    /// identity-matched entry — one window, one move.
    func test_windowClaimedByJoin_isNotReusedByIdentityFallback() async throws {
        let tabs = WindowIdentity.browserTabSet([URL(string: "https://a.example")!])
        // Two entries describe the same identity; only one live window exists.
        let snap = snapshot([
            entry(identity: tabs, ordinal: 0, frame: target, windowID: 101),
            entry(identity: tabs, ordinal: 1, frame: elsewhere, windowID: nil),
        ])
        let backend = FakeBackend(live: [liveWindow(identity: tabs, frame: elsewhere, windowID: 101)])
        let restorer = Restorer(backend: backend, tolerancePoints: 1.0)

        let report = try await restorer.apply(snap, activeDisplayFingerprintIDs: [displayID])

        XCTAssertEqual(report.moved, 1, "the joined pair moves")
        XCTAssertEqual(report.skippedMissingWindow, 1, "the second entry finds no free window")
        let moves = await backend.moveRequestCount()
        XCTAssertEqual(moves, 1)
    }
}
