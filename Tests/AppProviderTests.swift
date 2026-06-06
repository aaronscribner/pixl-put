import XCTest
@testable import PixlPutCore

final class BrowserTabSetProviderTests: XCTestCase {

    // T034 — Tab URLs produce a stable browserTabSet identity
    func test_browserTabSet_whenTabsProvided_thenIdentityIsSortedAndNormalized() throws {
        let p = BrowserTabSetProvider()
        let raw: [URL] = [
            URL(string: "https://example.com/two?utm=ad#frag")!,
            URL(string: "https://example.com/one")!,
        ]
        guard case .browserTabSet(let urls) = p.identity(from: raw) else {
            return XCTFail("Expected .browserTabSet")
        }
        XCTAssertEqual(urls.map(\.absoluteString), [
            "https://example.com/one",
            "https://example.com/two",
        ])
    }

    func test_browserTabSet_whenEmpty_thenReturnsNil() {
        XCTAssertNil(BrowserTabSetProvider().identity(from: []))
    }

    func test_browserTabSet_supportsAllChromiumFamilyBundleIDsAndSafari() {
        let p = BrowserTabSetProvider()
        for id in [
            "com.brave.Browser",
            "com.microsoft.edgemac",
            "com.google.Chrome",
            "company.thebrowser.Browser",   // Arc
            "com.apple.Safari",
        ] {
            XCTAssertTrue(p.supports(bundleID: id), "Expected \(id) to be supported")
        }
        // Negative cases — unrelated bundles must not match.
        XCTAssertFalse(p.supports(bundleID: "com.unknown.app"))
        XCTAssertFalse(p.supports(bundleID: "com.microsoft.VSCode"))
    }

    // Fixture round-trip — uses Bundle.module to find the test resource
    func test_browserTabSet_fixtureFile_loadsAndProducesIdentity() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/BraveTabSets", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: [String]]
        let windowA = try XCTUnwrap(json["windowA"]).compactMap { URL(string: $0) }
        let identity = BrowserTabSetProvider().identity(from: windowA)
        guard case .browserTabSet(let urls) = identity else {
            return XCTFail("Expected .browserTabSet")
        }
        XCTAssertEqual(urls.count, 3)
    }
}

final class VSCodeWorkspaceProviderTests: XCTestCase {

    // T035 — Extract workspace name from canonical title
    func test_vscode_workspaceName_fromCanonicalTitle() {
        let p = VSCodeWorkspaceProvider()
        XCTAssertEqual(
            p.workspaceName(fromTitle: "Restorer.swift — pixput — Visual Studio Code"),
            "pixput"
        )
    }

    // Working-tree decoration is stripped
    func test_vscode_workspaceName_stripsWorkingTreeDecoration() {
        let p = VSCodeWorkspaceProvider()
        XCTAssertEqual(
            p.workspaceName(fromTitle: "WindowIdentity.swift — pixput [Working Tree] — Visual Studio Code"),
            "pixput"
        )
    }

    // No-file-open variant
    func test_vscode_workspaceName_whenNoFileOpen_thenReturnsWorkspace() {
        let p = VSCodeWorkspaceProvider()
        XCTAssertEqual(
            p.workspaceName(fromTitle: "pixput — Visual Studio Code"),
            "pixput"
        )
    }

    // identity(fromWorkspaceURL:) requires a file URL
    func test_vscode_identity_fromWorkspaceURL_returnsEditorWorkspace() {
        let p = VSCodeWorkspaceProvider()
        let url = URL(fileURLWithPath: "/Users/u/Code/pixput")
        guard case .editorWorkspace(let resolved) = p.identity(fromWorkspaceURL: url) else {
            return XCTFail("Expected .editorWorkspace")
        }
        XCTAssertEqual(resolved.path, "/Users/u/Code/pixput")
    }

    func test_vscode_identity_fromNonFileURL_returnsNil() {
        let p = VSCodeWorkspaceProvider()
        XCTAssertNil(p.identity(fromWorkspaceURL: URL(string: "https://example.com")!))
    }
}
