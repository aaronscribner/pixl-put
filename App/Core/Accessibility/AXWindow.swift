import Foundation
import ApplicationServices
import CoreGraphics

/// Typed wrapper around an `AXUIElement` representing a window.
///
/// **AX queue discipline** (project constitution §VII): every attribute on
/// this struct is pre-fetched inside `AXClient.enumerateWindows()` while
/// running on the dedicated AX dispatch queue. Code outside `AXClient`
/// MUST NOT issue any AX call — read the stored properties instead.
/// `element` is exposed only so move / fullscreen operations on the AX
/// queue can mutate the window; passing it to any direct `AXUIElement*`
/// call from a non-AX-queue thread is a bug.
public struct AXWindow: @unchecked Sendable {
    public let element: AXUIElement
    public let bundleID: String
    public let creationOrdinal: Int
    public let indexInApp: Int

    // Pre-fetched attributes — populated on the AX queue at enumeration.
    public let title: String
    public let documentURL: URL?
    public let frame: CGRectCodable?
    public let isFullscreen: Bool
    public let isMinimized: Bool

    public init(
        element: AXUIElement,
        bundleID: String,
        creationOrdinal: Int,
        indexInApp: Int,
        title: String,
        documentURL: URL?,
        frame: CGRectCodable?,
        isFullscreen: Bool,
        isMinimized: Bool
    ) {
        self.element = element
        self.bundleID = bundleID
        self.creationOrdinal = creationOrdinal
        self.indexInApp = indexInApp
        self.title = title
        self.documentURL = documentURL
        self.frame = frame
        self.isFullscreen = isFullscreen
        self.isMinimized = isMinimized
    }
}
