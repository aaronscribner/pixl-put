import AppKit
import Foundation
import CoreGraphics

/// PixPut's own every-Space window enumeration — the read half of what it
/// used to shell out to `yabai -m query --windows` for.
///
/// Why this exists at all. yabai is only needed for the *privileged* half of
/// cross-Space work: moving one window to another Space, and setting a frame
/// on a Space that is not active. Both mutate a window owned by another
/// process, and the window server refuses that from any connection but the
/// owner's — measured 2026-09-12: `SLSMoveWindowsToManagedSpace` silently
/// no-ops, `SLSSpaceAddWindowsAndRemoveFromSpaces` errors, and
/// `SLSSetWindowTags` reports success while changing nothing. yabai gets
/// around it by running the call inside Dock, which does own them.
///
/// *Reading* needs none of that. `CGWindowListCopyWindowInfo` already returns
/// every window on every Space, and `CGSCopySpacesForWindows` says which
/// Space each one is on. So the query is pure CoreGraphics plus one private
/// read-only call PixPut already binds, which means the restore plan can be
/// built with yabai absent, stopped, or broken — and it stays correct in the
/// spanning-display configuration (ADR-0003) that yabai itself mis-handles.
///
/// The result deliberately reuses `YabaiWindow` so this is a drop-in for
/// `YabaiRelocationBackend.queryWindows()`.
public enum NativeWindowQuery {

    /// Map CoreGraphics rows and their Space IDs onto the query shape.
    ///
    /// Pure — every input is data, so the ordering and index arithmetic are
    /// unit-testable without a window server.
    ///
    /// - Parameters:
    ///   - descriptors: every window CoreGraphics reports, on any Space.
    ///   - spaceIDsByWindow: Space IDs per window. More than one means the
    ///     window is on every Space ("sticky"), which is not a restorable
    ///     placement; none means the window belongs to no Space at all.
    ///   - orderedSpaceIDs: the managed Space IDs in display order. Position
    ///     in this array, plus one, is the 1-based index yabai reported and
    ///     that `YabaiWindow.pixputSpaceIndex` subtracts back off.
    ///   - appNameByPID: process display names, for diagnostics only.
    ///   - titlesByWindowID: titles from a richer source than CoreGraphics,
    ///     which reports a title only with Screen Recording consent. Where a
    ///     window is absent here its CoreGraphics title is used.
    public static func build(
        descriptors: [CGWindowDescriptor],
        spaceIDsByWindow: [CGWindowID: [UInt64]],
        orderedSpaceIDs: [UInt64],
        appNameByPID: [pid_t: String] = [:],
        titlesByWindowID: [CGWindowID: String] = [:]
    ) -> [YabaiWindow] {
        // Space ID → 1-based index, matching yabai's global numbering.
        var indexBySpaceID: [UInt64: Int] = [:]
        for (offset, sid) in orderedSpaceIDs.enumerated() {
            indexBySpaceID[sid] = offset + 1
        }

        var out: [YabaiWindow] = []
        out.reserveCapacity(descriptors.count)

        for d in descriptors {
            let spaceIDs = spaceIDsByWindow[d.windowID] ?? []

            // A window on every Space follows the user rather than occupying
            // a placement. Emit it flagged so `isStandardPlacement` drops it,
            // rather than silently omitting a window the caller can see.
            let isSticky = spaceIDs.count > 1

            // Resolve the Space. A sticky window is reported against its
            // first known Space purely so the row has one; the sticky flag is
            // what callers act on.
            guard let sid = spaceIDs.first, let index = indexBySpaceID[sid] else {
                // No Space, or a Space outside the managed set (for example a
                // full-screen or Exposé-owned Space). Not restorable.
                continue
            }

            out.append(
                YabaiWindow(
                    id: d.windowID,
                    pid: d.ownerPID,
                    app: appNameByPID[d.ownerPID] ?? d.bundleID,
                    title: titlesByWindowID[d.windowID] ?? d.title,
                    frame: YabaiWindow.Frame(
                        x: d.bounds.x, y: d.bounds.y, w: d.bounds.width, h: d.bounds.height
                    ),
                    space: index,
                    display: nil,
                    role: "AXWindow",
                    subrole: "AXStandardWindow",
                    isVisible: d.isOnScreen,
                    // CoreGraphics cannot distinguish a minimized window from
                    // one merely on another Space: neither is on screen. Left
                    // unset rather than guessed; the caller's size and
                    // identity filters already reject collapsed windows.
                    isMinimized: false,
                    isHidden: false,
                    isSticky: isSticky,
                    isNativeFullscreen: false
                )
            )
        }

        // Stable order: by Space, then by window id (creation order), so a
        // plan built twice over an unchanged desktop is identical.
        return out.sorted { ($0.space, $0.id) < ($1.space, $1.id) }
    }

    /// The live query. Returns `nil` only when the Space set is ambiguous —
    /// more than one managed display — which ADR-0003 refuses to guess at.
    public static func windows(titlesByWindowID: [CGWindowID: String] = [:]) -> [YabaiWindow]? {
        let managed = PrivateCGS.managedDisplaySpaces()
        // ADR-0003: a bare Space index only has meaning with one managed set.
        guard managed.count == 1, let ordered = managed.values.first else { return nil }

        let descriptors = CGWindowEnumerator.enumerateAllWindows()
        guard !descriptors.isEmpty else { return [] }

        let spaceIDs = PrivateCGS.spacesForWindows(descriptors.map { $0.windowID })
        let appNames: [pid_t: String] = Dictionary(
            NSWorkspace.shared.runningApplications.compactMap { app -> (pid_t, String)? in
                app.localizedName.map { (app.processIdentifier, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )

        return build(
            descriptors: descriptors,
            spaceIDsByWindow: spaceIDs,
            orderedSpaceIDs: ordered,
            appNameByPID: appNames,
            titlesByWindowID: titlesByWindowID
        )
    }
}
