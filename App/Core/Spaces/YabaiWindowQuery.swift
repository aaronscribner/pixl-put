import Foundation
import CoreGraphics

/// Decoded rows of `yabai -m query --windows` and `--spaces`.
///
/// Field names follow yabai's JSON verbatim. Everything beyond the join keys
/// is optional so a yabai release that drops or renames a secondary field
/// degrades a filter, not the whole query.
public struct YabaiWindow: Decodable, Equatable, Sendable {
    public struct Frame: Decodable, Equatable, Sendable {
        public let x: Double
        public let y: Double
        public let w: Double
        public let h: Double
        public init(x: Double, y: Double, w: Double, h: Double) {
            self.x = x; self.y = y; self.w = w; self.h = h
        }
        public var rect: CGRectCodable { CGRectCodable(x: x, y: y, width: w, height: h) }
    }

    /// CoreGraphics window number — the same value as `LiveWindow.windowID`.
    public let id: CGWindowID
    public let pid: pid_t
    public let app: String
    public let title: String
    public let frame: Frame
    /// yabai's global, 1-based Space index.
    public let space: Int
    public let display: Int?
    public let role: String?
    public let subrole: String?
    public let isVisible: Bool?
    public let isMinimized: Bool?
    public let isHidden: Bool?
    public let isSticky: Bool?
    public let isNativeFullscreen: Bool?

    enum CodingKeys: String, CodingKey {
        case id, pid, app, title, frame, space, display, role, subrole
        case isVisible = "is-visible"
        case isMinimized = "is-minimized"
        case isHidden = "is-hidden"
        case isSticky = "is-sticky"
        case isNativeFullscreen = "is-native-fullscreen"
    }

    public init(
        id: CGWindowID, pid: pid_t, app: String, title: String, frame: Frame, space: Int,
        display: Int? = nil, role: String? = "AXWindow", subrole: String? = "AXStandardWindow",
        isVisible: Bool? = true, isMinimized: Bool? = false, isHidden: Bool? = false,
        isSticky: Bool? = false, isNativeFullscreen: Bool? = false
    ) {
        self.id = id; self.pid = pid; self.app = app; self.title = title; self.frame = frame
        self.space = space; self.display = display; self.role = role; self.subrole = subrole
        self.isVisible = isVisible; self.isMinimized = isMinimized; self.isHidden = isHidden
        self.isSticky = isSticky; self.isNativeFullscreen = isNativeFullscreen
    }

    /// A window PixPut would capture: a standard, non-sticky window that
    /// belongs to some Space. Dialogs, panels, and "all Desktops" windows
    /// are not restorable placements and are excluded.
    public var isStandardPlacement: Bool {
        (role ?? "AXWindow") == "AXWindow"
            && (subrole ?? "AXStandardWindow") == "AXStandardWindow"
            && !(isSticky ?? false)
            && space >= 1
    }

    /// PixPut's 0-based per-display Space index (ADR-0003: one managed set,
    /// so yabai's global index minus one).
    public var pixputSpaceIndex: Int { space - 1 }
}

public struct YabaiSpace: Decodable, Equatable, Sendable {
    public let id: UInt64?
    public let index: Int
    public let display: Int?
    public let type: String?
    public let hasFocus: Bool?
    public let isVisible: Bool?

    enum CodingKeys: String, CodingKey {
        case id, index, display, type
        case hasFocus = "has-focus"
        case isVisible = "is-visible"
    }
}

public enum YabaiJSON {
    public static func windows(from data: Data) throws -> [YabaiWindow] {
        try JSONDecoder().decode([YabaiWindow].self, from: data)
    }
    public static func spaces(from data: Data) throws -> [YabaiSpace] {
        try JSONDecoder().decode([YabaiSpace].self, from: data)
    }
}
