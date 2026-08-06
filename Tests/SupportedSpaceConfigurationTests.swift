import XCTest
@testable import PixlPutCore

/// ADR-0003 — this project supports exactly one display/Spaces configuration:
/// a single managed Space set. These assert that an unsupported or ambiguous
/// lookup **refuses** rather than guessing, since a wrong guess relocates an
/// app's windows onto a Space the user never chose.
final class SupportedSpaceConfigurationTests: XCTestCase {

    private var cgsAvailable: Bool { PrivateCGS.isAvailable }

    func test_negativeIndexIsRefused() {
        // Cheap invariant, independent of host configuration.
        XCTAssertNil(PrivateCGS.spaceID(atIndex: -1, displayUUID: nil))
    }

    func test_indexBeyondTheSpaceCountIsRefused() throws {
        try XCTSkipUnless(cgsAvailable, "private CGS symbols unavailable")
        XCTAssertNil(PrivateCGS.spaceID(atIndex: 9_999, displayUUID: nil))
    }

    /// A `DisplayFingerprint.id` is the WRONG namespace — CGS keys managed
    /// displays by its own "Display Identifier" string (`"Main"` on the target
    /// hardware). On a single-set host such a hint is unresolvable but also
    /// unnecessary: the lone set is the only possible meaning, so the lookup
    /// ignores the bad hint instead of failing the restore.
    func test_onSupportedConfiguration_unknownDisplayHintIsIgnoredNotFatal() throws {
        try XCTSkipUnless(cgsAvailable, "private CGS symbols unavailable")
        try XCTSkipUnless(PrivateCGS.isSingleManagedSpaceSet,
                          "host has multiple managed Space sets — unsupported per ADR-0003")
        XCTAssertEqual(
            PrivateCGS.spaceID(atIndex: 0, displayUUID: "0792DD76-39D8-44C0-AE3A-429E73620126"),
            PrivateCGS.spaceID(atIndex: 0, displayUUID: nil),
            "with one managed set the hint cannot change the answer"
        )
    }

    /// The refusal that ADR-0003 actually turns on: an out-of-range index is
    /// never satisfied by falling through to some other display's set.
    func test_outOfRangeIndexIsRefusedEvenWithADisplayHint() throws {
        try XCTSkipUnless(cgsAvailable, "private CGS symbols unavailable")
        XCTAssertNil(PrivateCGS.spaceID(atIndex: 9_999, displayUUID: "Main"))
    }

    func test_resolverAgreesWithTheUnderlyingProbe() throws {
        try XCTSkipUnless(cgsAvailable, "private CGS symbols unavailable")
        XCTAssertEqual(SpaceResolver().hasSupportedSpaceConfiguration,
                       PrivateCGS.isSingleManagedSpaceSet)
    }

    /// On a supported host, index 0 must resolve — a refusal there would mean
    /// the guard is too aggressive and Restore Spaces could never run.
    func test_onSupportedConfiguration_indexZeroResolves() throws {
        try XCTSkipUnless(cgsAvailable, "private CGS symbols unavailable")
        try XCTSkipUnless(PrivateCGS.isSingleManagedSpaceSet,
                          "host has multiple managed Space sets — unsupported per ADR-0003")
        XCTAssertNotNil(PrivateCGS.spaceID(atIndex: 0, displayUUID: nil))
    }
}
