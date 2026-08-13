import Foundation
import CoreGraphics
import AppKit

/// Resolves the Space (Mission Control workspace) a window is on, or the
/// currently active Space. Public seam for the rest of the app — `Restorer`,
/// `SnapshotEngine`, and the menu bar status surface go through here, never
/// through `PrivateCGS` directly.
///
/// Degraded mode (per ADR-0001): when the private CGS symbols aren't
/// available on the host macOS, `spaceIndex(forDisplayUUID:)` returns `0`
/// and `isSpaceAware` is `false`. The caller surfaces this through the
/// menu bar so the user knows Spaces aren't being preserved.
public struct SpaceResolver: Sendable {

    public init() {}

    /// `true` when the private CGS symbols resolved successfully at first
    /// call. `false` means we're in degraded mode (no Space awareness).
    public var isSpaceAware: Bool { PrivateCGS.isAvailable }

    /// `true` when the cross-Space window enumeration symbol resolved —
    /// required for Phase B (capture windows on inactive Spaces).
    public var isCrossSpaceAware: Bool { PrivateCGS.isCrossSpaceAware }

    /// `true` when windows of other apps can be relocated across Spaces
    /// (ADR-0002). Gates the Restore Spaces command in the menu bar.
    public var canRelocateAcrossSpaces: Bool { PrivateCGS.canRelocateAcrossSpaces }

    /// `true` when the host presents exactly one managed Space set — the only
    /// display/Spaces configuration this project supports (ADR-0003).
    ///
    /// False means "displays have separate Spaces" is on with more than one
    /// display, where a stored Space index doesn't say which display it
    /// belongs to. Space relocation refuses rather than guessing.
    public var hasSupportedSpaceConfiguration: Bool { PrivateCGS.isSingleManagedSpaceSet }

    /// The active Space's per-display index. Returns 0 in degraded mode.
    ///
    /// Reads the managed-display structure's own `"Current Space"` first, so the
    /// value and the index ordering come from one snapshot of one API and cannot
    /// disagree. `CGSGetActiveSpace` is the fallback: it is a separate,
    /// connection-scoped query that has been seen reporting a different Space
    /// than the managed display during a switch transition.
    public func activeSpaceIndex() -> Int {
        if let index = PrivateCGS.currentSpaceIndex() { return index }
        guard let id = PrivateCGS.activeSpaceID() else { return 0 }
        return mapToPerDisplayIndex(spaceID: id, displayUUID: nil) ?? 0
    }

    /// The Space index of a window that belongs to exactly one Space, or `nil`
    /// for sticky "all Desktops" windows and windows mid-teardown.
    ///
    /// Distinct from `spaceIndexIfKnown(forWindowID:)`, which takes the first of
    /// however many Spaces a window reports. That is fine for "roughly where is
    /// this window", and wrong for voting: see
    /// `PrivateCGS.unambiguousSpace(forWindow:)`.
    public func unambiguousSpaceIndex(forWindowID windowID: CGWindowID) -> Int? {
        guard let id = PrivateCGS.unambiguousSpace(forWindow: windowID) else { return nil }
        return mapToPerDisplayIndex(spaceID: id, displayUUID: nil)
    }

    /// Per-display per-space index (the value stored in `WindowEntry.spaceIndex`).
    /// Returns 0 if Spaces aren't available or the lookup fails.
    public func spaceIndex(forDisplayUUID displayUUID: String) -> Int {
        let spacesByDisplay = PrivateCGS.managedDisplaySpaces()
        guard let activeID = PrivateCGS.activeSpaceID(),
              let spacesOnDisplay = spacesByDisplay[displayUUID],
              let idx = spacesOnDisplay.firstIndex(of: activeID) else {
            return 0
        }
        return idx
    }

    /// Phase B: per-Window Space index. Given a CG window ID, returns the
    /// (per-display) Space index the window currently sits on. Falls back
    /// to 0 in degraded mode — the caller treats that as "active Space"
    /// which is the safe default for the wake-restore code path.
    public func spaceIndex(forWindowID windowID: CGWindowID) -> Int {
        spaceIndexIfKnown(forWindowID: windowID) ?? 0
    }

    /// Like `spaceIndex(forWindowID:)` but honest about ignorance: `nil`
    /// when CGS is degraded or the window reports no Space (sticky
    /// all-Spaces windows, windows mid-teardown). The all-Spaces capture
    /// pass uses this — recording an unknown as "Space 0" would pile every
    /// unqueryable window onto the first Space.
    public func spaceIndexIfKnown(forWindowID windowID: CGWindowID) -> Int? {
        let spaceIDs = PrivateCGS.spaces(forWindow: windowID)
        guard let first = spaceIDs.first else { return nil }
        return mapToPerDisplayIndex(spaceID: first, displayUUID: nil)
    }

    /// Map a CGS Space ID to a per-display index when we know the display.
    private func mapToPerDisplayIndex(spaceID: PrivateCGS.CGSSpaceID, displayUUID: String?) -> Int? {
        let spacesByDisplay = PrivateCGS.managedDisplaySpaces()
        if let uuid = displayUUID, let spaces = spacesByDisplay[uuid] {
            return spaces.firstIndex(of: spaceID)
        }
        // No display hint — find the first display that contains this Space.
        for (_, spaces) in spacesByDisplay {
            if let idx = spaces.firstIndex(of: spaceID) { return idx }
        }
        return nil
    }
}

// MARK: - Cross-Space window enumeration (Phase B)

/// A window discovered via `CGWindowListCopyWindowInfo` — includes windows
/// on inactive Spaces that AX won't enumerate. Carries the minimum needed
/// for snapshot identity-resolution: bundle ID, title, bounds, owner PID,
/// CG window ID. Frame coordinates are in screen space.
public struct CGWindowDescriptor: Sendable, Equatable {
    public let windowID: CGWindowID
    public let ownerPID: pid_t
    public let bundleID: String   // resolved from PID
    public let title: String
    public let bounds: CGRectCodable
    public let isOnScreen: Bool

    public init(
        windowID: CGWindowID,
        ownerPID: pid_t,
        bundleID: String,
        title: String,
        bounds: CGRectCodable,
        isOnScreen: Bool
    ) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.bundleID = bundleID
        self.title = title
        self.bounds = bounds
        self.isOnScreen = isOnScreen
    }
}

/// Enumerates ALL windows currently rendered by the window server, including
/// those on inactive Spaces. Uses `CGWindowListCopyWindowInfo` which is a
/// public CoreGraphics API and doesn't require Accessibility (only Screen
/// Recording — which we DON'T currently request because we only need
/// geometry, not pixels; CG includes geometry without Screen Recording
/// consent for non-pixel queries).
public enum CGWindowEnumerator {

    public static func enumerateAllWindows() -> [CGWindowDescriptor] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        // Map PID → bundle ID once; runningApplications is cheap but PID-keyed.
        let pidToBundle: [pid_t: String] = Dictionary(
            uniqueKeysWithValues: NSWorkspace.shared.runningApplications.compactMap {
                guard let b = $0.bundleIdentifier else { return nil }
                return ($0.processIdentifier, b)
            }
        )
        var out: [CGWindowDescriptor] = []
        out.reserveCapacity(raw.count)
        for dict in raw {
            guard
                let wid = dict[kCGWindowNumber as String] as? NSNumber,
                let pidNum = dict[kCGWindowOwnerPID as String] as? NSNumber,
                let layer = dict[kCGWindowLayer as String] as? NSNumber,
                let boundsDict = dict[kCGWindowBounds as String] as? [String: Any]
            else { continue }
            // Only "normal" windows (layer 0). Layer != 0 includes menus,
            // status bars, dock — not user app windows.
            guard layer.intValue == 0 else { continue }
            let pid = pid_t(pidNum.int32Value)
            guard let bundleID = pidToBundle[pid] else { continue }
            let title = (dict[kCGWindowName as String] as? String) ?? ""
            let isOnScreen = (dict[kCGWindowIsOnscreen as String] as? Bool) ?? false
            guard
                let x = boundsDict["X"] as? Double,
                let y = boundsDict["Y"] as? Double,
                let w = boundsDict["Width"] as? Double,
                let h = boundsDict["Height"] as? Double
            else { continue }
            // Tiny / zero-size windows are usually invisible helper windows
            // (palettes, transient overlays). Skip them — moving them is
            // either a no-op or actively wrong.
            guard w >= 20, h >= 20 else { continue }
            out.append(CGWindowDescriptor(
                windowID: CGWindowID(wid.uint32Value),
                ownerPID: pid,
                bundleID: bundleID,
                title: title,
                bounds: CGRectCodable(x: x, y: y, width: w, height: h),
                isOnScreen: isOnScreen
            ))
        }
        return out
    }
}
