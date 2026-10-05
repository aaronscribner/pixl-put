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

    /// Space IDs per window, one lookup per window.
    ///
    /// `CGSCopySpacesForWindows` given several windows returns the union of
    /// their Spaces with no way to tell whose is whose, and
    /// `PrivateCGS.spacesForWindows` pins that union on the first window. Built
    /// from it, this query kept one window of 170 — measured 2026-09-13 — so
    /// the cross-Space restore planned against nothing and reported nothing to
    /// move. Asked per window, 67 resolved to exactly one Space, and all 8
    /// VS Code windows agreed with yabai.
    static func spaceMap(
        for windowIDs: [CGWindowID],
        lookup: (CGWindowID) -> [UInt64]
    ) -> [CGWindowID: [UInt64]] {
        var out: [CGWindowID: [UInt64]] = [:]
        out.reserveCapacity(windowIDs.count)
        for id in windowIDs {
            out[id] = lookup(id)
        }
        return out
    }

    /// Whether the native list is usable, judged against yabai's tracked set.
    /// Covering under half the windows yabai tracks means the query itself is
    /// broken — 0 of 64 on 2026-09-13 — and planning against it restores
    /// nothing while reporting nothing to do. With no yabai answer there is
    /// nothing to judge against, so any non-empty list is used.
    public static func nativeCoversTracked(kept: Int, trackedCount: Int?) -> Bool {
        guard let trackedCount, trackedCount > 0 else { return kept > 0 }
        return kept * 2 >= trackedCount
    }

    /// Window titles from yabai's query, for `windows(titlesByWindowID:)`.
    /// Empty titles are left out so CoreGraphics' own value still applies;
    /// no query (yabai did not answer) gives no titles.
    public static func titles(from windows: [YabaiWindow]?) -> [CGWindowID: String] {
        var out: [CGWindowID: String] = [:]
        for w in windows ?? [] where !w.title.isEmpty {
            out[w.id] = w.title
        }
        return out
    }

    /// Keep only the windows yabai tracks. yabai tracks exactly the windows
    /// that are real to Accessibility, and it can move no other, so outside
    /// that set a row is a placeholder or popup taking an ordinal from a real
    /// window. `nil` (yabai did not answer) or an empty set keeps every row:
    /// an unfiltered plan beats restoring nothing.
    public static func restricted(
        _ windows: [YabaiWindow],
        toTrackedIDs trackedIDs: Set<CGWindowID>?
    ) -> (kept: [YabaiWindow], dropped: Int) {
        guard let trackedIDs, !trackedIDs.isEmpty else { return (windows, 0) }
        let kept = windows.filter { trackedIDs.contains($0.id) }
        return (kept, windows.count - kept.count)
    }

    /// The live query. Returns `nil` only when the Space set is ambiguous —
    /// more than one managed display — which ADR-0003 refuses to guess at.
    public static func windows(titlesByWindowID: [CGWindowID: String] = [:]) -> [YabaiWindow]? {
        let managed = PrivateCGS.managedDisplaySpaces()
        // ADR-0003: a bare Space index only has meaning with one managed set.
        guard managed.count == 1, let ordered = managed.values.first else { return nil }

        let descriptors = CGWindowEnumerator.enumerateAllWindows()
        guard !descriptors.isEmpty else { return [] }

        let spaceIDs = spaceMap(for: descriptors.map(\.windowID), lookup: PrivateCGS.spaces(forWindow:))
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
