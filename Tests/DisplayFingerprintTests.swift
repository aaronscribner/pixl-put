import XCTest
@testable import PixlPutCore

final class DisplayFingerprintTests: XCTestCase {

    // T050 — Determinism: same inputs → same id
    func test_displayFingerprint_whenSameInputs_thenSameID() {
        let a = DisplayFingerprint(vendorID: 0x05ac, productID: 0xa050,
                                   modelNumber: 0xa050, serialNumber: 0,
                                   displayUUID: "37D8832A-...")
        let b = DisplayFingerprint(vendorID: 0x05ac, productID: 0xa050,
                                   modelNumber: 0xa050, serialNumber: 0,
                                   displayUUID: "37D8832A-...")
        XCTAssertEqual(a.id, b.id)
    }

    // Different inputs → different ids
    func test_displayFingerprint_whenDifferentInputs_thenDifferentID() {
        let a = DisplayFingerprint(vendorID: 0x05ac, productID: 0xa050,
                                   modelNumber: 0xa050, serialNumber: 0,
                                   displayUUID: "A")
        let b = DisplayFingerprint(vendorID: 0x05ac, productID: 0xa050,
                                   modelNumber: 0xa050, serialNumber: 0,
                                   displayUUID: "B")
        XCTAssertNotEqual(a.id, b.id)
    }

    // T051 — DisplayConfigurationID is port-order-independent (FR-001)
    func test_displayConfigurationID_isPortOrderIndependent() {
        let d1 = DisplayFingerprint(vendorID: 1, productID: 1, modelNumber: 1, serialNumber: 1, displayUUID: "A")
        let d2 = DisplayFingerprint(vendorID: 2, productID: 2, modelNumber: 2, serialNumber: 2, displayUUID: "B")
        let d3 = DisplayFingerprint(vendorID: 3, productID: 3, modelNumber: 3, serialNumber: 3, displayUUID: "C")
        let idA = DisplayConfigurationID.compute(from: [d1, d2, d3])
        let idB = DisplayConfigurationID.compute(from: [d3, d1, d2])
        let idC = DisplayConfigurationID.compute(from: [d2, d3, d1])
        XCTAssertEqual(idA, idB)
        XCTAssertEqual(idA, idC)
    }

    // Different sets → different ids
    func test_displayConfigurationID_whenDifferentSet_thenDifferentID() {
        let d1 = DisplayFingerprint(vendorID: 1, productID: 1, modelNumber: 1, serialNumber: 1, displayUUID: "A")
        let d2 = DisplayFingerprint(vendorID: 2, productID: 2, modelNumber: 2, serialNumber: 2, displayUUID: "B")
        let alone = DisplayConfigurationID.compute(from: [d1])
        let pair = DisplayConfigurationID.compute(from: [d1, d2])
        XCTAssertNotEqual(alone, pair)
    }

    // Serial-number 24-bit clamp
    func test_displayFingerprint_serialNumber_isClampedTo24Bits() {
        let fp = DisplayFingerprint(vendorID: 0, productID: 0, modelNumber: 0,
                                    serialNumber: 0xFF_FF_FF_FF, displayUUID: nil)
        XCTAssertEqual(fp.serialNumber, 0x00_FF_FF_FF)
    }

    // The three real-world configurations the project owner switches
    // between — each must produce a distinct displayConfigurationID so
    // each gets its own snapshot history file.
    //
    //   Desktop: 1× Samsung Neo G9 (ultra-wide, single CGDirectDisplayID)
    //   Travel : 1× MacBook built-in + 2× InnovView Portal 15.6"
    //   On the go: 1× MacBook built-in only
    func test_displayConfigurationID_threeRealSetups_eachProduceDistinctID() {
        // Apple vendor ID for MacBook displays
        let mbp = DisplayFingerprint(
            vendorID: 0x05AC, productID: 0xA050, modelNumber: 0xA050,
            serialNumber: 0, displayUUID: nil
        )
        // Samsung vendor ID + a representative G9 model
        let g9 = DisplayFingerprint(
            vendorID: 0x4C2D, productID: 0x7077, modelNumber: 0x7077,
            serialNumber: 0x123456, displayUUID: nil
        )
        // InnovView (placeholder vendor) — both panels report distinct serials
        let portalA = DisplayFingerprint(
            vendorID: 0x4949, productID: 0x1560, modelNumber: 0x1560,
            serialNumber: 0xAA0001, displayUUID: nil
        )
        let portalB = DisplayFingerprint(
            vendorID: 0x4949, productID: 0x1560, modelNumber: 0x1560,
            serialNumber: 0xAA0002, displayUUID: nil
        )

        let desktopConfig  = DisplayConfigurationID.compute(from: [g9])
        let travelConfig   = DisplayConfigurationID.compute(from: [mbp, portalA, portalB])
        let onTheGoConfig  = DisplayConfigurationID.compute(from: [mbp])

        XCTAssertNotEqual(desktopConfig,  travelConfig)
        XCTAssertNotEqual(desktopConfig,  onTheGoConfig)
        XCTAssertNotEqual(travelConfig,   onTheGoConfig)

        // And they're deterministic per setup — same set in either order.
        XCTAssertEqual(
            travelConfig,
            DisplayConfigurationID.compute(from: [portalB, mbp, portalA])
        )
    }

    // Edge case the project owner flagged: two identical external
    // monitors that BOTH report serial 0 (some cheap panels do). Their
    // per-display fingerprints collide; only one "kind" of display is
    // represented even though there are two physically present. The
    // CONFIG id still differs from the single-monitor case (because the
    // sorted-IDs set has two elements vs one... actually wait, a Set
    // collapses duplicates).
    //
    // We document the current behaviour: DisplayConfigurationID hashes
    // the sorted *list* (not set), so [fp, fp] != [fp]. The two-Portal
    // config gets a different ID from one-Portal config. What breaks
    // for these users is per-window display-affinity, not config-bucketing.
    func test_displayConfigurationID_twoIdenticalSerialZeroDisplays_stillDistinctFromOne() {
        let mbp = DisplayFingerprint(
            vendorID: 0x05AC, productID: 0xA050, modelNumber: 0xA050,
            serialNumber: 0, displayUUID: nil
        )
        let cheapNoSerial = DisplayFingerprint(
            vendorID: 0x9999, productID: 0x1111, modelNumber: 0x1111,
            serialNumber: 0, displayUUID: nil
        )
        let oneExternal = DisplayConfigurationID.compute(from: [mbp, cheapNoSerial])
        let twoIdenticalExternals = DisplayConfigurationID.compute(from: [mbp, cheapNoSerial, cheapNoSerial])
        XCTAssertNotEqual(oneExternal, twoIdenticalExternals,
                          "Config hash counts duplicates; 1+1 ≠ 1+2 externals even when externals are indistinguishable.")
    }
}
