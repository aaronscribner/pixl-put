import XCTest
@testable import PixlPutCore

final class WindowIdentityTests: XCTestCase {

    // T030 — Resolver order: stronger layers shadow weaker ones (constitution §II)
    func test_resolver_whenDocumentPathPresent_thenReturnsLayer1IdentityNotLowerLayer() {
        let resolver = WindowIdentityResolver.defaultV1()
        let signal = WindowSignal(
            bundleID: "com.microsoft.VSCode",
            title: "x.swift — pixput — Visual Studio Code",
            documentURL: URL(fileURLWithPath: "/tmp/x.swift"),
            appProviderIdentity: nil,
            creationOrdinal: 5
        )
        let result = resolver.resolve(signal)
        XCTAssertEqual(result.layer, 1)
        if case .documentPath(let u) = result {
            XCTAssertEqual(u.path, "/tmp/x.swift")
        } else {
            XCTFail("Expected .documentPath, got \(result)")
        }
    }

    // T030 — Falls through layers when stronger signals are absent
    func test_resolver_whenOnlyTitleMatches_thenReturnsLayer3() {
        let resolver = WindowIdentityResolver.defaultV1()
        let signal = WindowSignal(
            bundleID: "com.microsoft.VSCode",
            title: "Restorer.swift — pixput — Visual Studio Code",
            documentURL: nil,
            appProviderIdentity: nil,
            creationOrdinal: 0
        )
        let result = resolver.resolve(signal)
        XCTAssertEqual(result.layer, 3)
    }

    // T030 — Bottoms out at OrdinalProvider when nothing else matches
    func test_resolver_whenNoSignalMatches_thenReturnsOrdinal() {
        let resolver = WindowIdentityResolver.defaultV1()
        let signal = WindowSignal(
            bundleID: "com.unknown.app",
            title: "Untitled",
            documentURL: nil,
            appProviderIdentity: nil,
            creationOrdinal: 7
        )
        let result = resolver.resolve(signal)
        XCTAssertEqual(result, .ordinal(7))
    }

    // T031 — DocumentPathProvider
    func test_documentPathProvider_whenDocumentURLPresent_thenReturnsDocumentPath() {
        let p = DocumentPathProvider()
        let url = URL(fileURLWithPath: "/Users/u/file.txt")
        let result = p.resolve(WindowSignal(
            bundleID: "com.apple.TextEdit",
            title: "file.txt",
            documentURL: url,
            creationOrdinal: 0
        ))
        XCTAssertEqual(result, .documentPath(url))
    }

    func test_documentPathProvider_whenDocumentURLAbsent_thenReturnsNil() {
        let p = DocumentPathProvider()
        XCTAssertNil(p.resolve(WindowSignal(
            bundleID: "com.apple.TextEdit",
            title: "Untitled",
            documentURL: nil,
            creationOrdinal: 0
        )))
    }

    // T032 — TitleRegexProvider (VS Code default pattern)
    func test_titleRegexProvider_whenVSCodeTitleHasWorkspace_thenExtractsCapture() {
        let p = TitleRegexProvider()
        let signal = WindowSignal(
            bundleID: "com.microsoft.VSCode",
            title: "Restorer.swift — pixput — Visual Studio Code",
            creationOrdinal: 0
        )
        guard case .titleRegex(_, let captured) = p.resolve(signal) else {
            return XCTFail("Expected .titleRegex")
        }
        XCTAssertEqual(captured, "pixput")
    }

    func test_titleRegexProvider_whenNoPatternForBundle_thenReturnsNil() {
        let p = TitleRegexProvider()
        XCTAssertNil(p.resolve(WindowSignal(
            bundleID: "com.unknown.app",
            title: "any title",
            creationOrdinal: 0
        )))
    }

    // T033 — OrdinalProvider always resolves
    func test_ordinalProvider_alwaysResolves() {
        let p = OrdinalProvider()
        for n in 0..<5 {
            let r = p.resolve(WindowSignal(
                bundleID: "x", title: "x", creationOrdinal: n
            ))
            XCTAssertEqual(r, .ordinal(n))
        }
    }

    // Layered ordering invariant
    func test_resolver_whenProvidersPassedOutOfOrder_thenStillResolvesByLayer() {
        let resolver = WindowIdentityResolver(providers: [
            OrdinalProvider(),
            DocumentPathProvider(),
            TitleRegexProvider(),
            AppProviderPassthrough(),
        ])
        let signal = WindowSignal(
            bundleID: "com.microsoft.VSCode",
            title: "x.swift — pixput — Visual Studio Code",
            documentURL: URL(fileURLWithPath: "/tmp/x.swift"),
            creationOrdinal: 0
        )
        XCTAssertEqual(resolver.resolve(signal).layer, 1)
    }
}
