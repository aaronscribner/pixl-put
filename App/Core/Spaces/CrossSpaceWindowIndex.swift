import Foundation
import CoreGraphics

/// A live window together with the Space it currently occupies.
/// `LiveWindow` deliberately has no Space field — AX, which produces most of
/// them, only ever sees the active Space — so the cross-Space view carries
/// it alongside.
public struct CrossSpaceWindow: Equatable, Sendable {
    public let live: LiveWindow
    /// PixPut's 0-based per-display Space index.
    public let spaceIndex: Int

    public init(live: LiveWindow, spaceIndex: Int) {
        self.live = live
        self.spaceIndex = spaceIndex
    }
}

/// Builds the every-Space window list the cross-Space restore plans against.
///
/// Sources, in order of authority:
/// 1. yabai's window query — the only enumeration that covers every Space.
///    Supplies window id, pid, title, frame, and Space.
/// 2. AX live windows for the active Space, keyed by window id. Where AX has
///    seen a window its identity and creation ordinal are used verbatim, so
///    the active Space resolves exactly as capture did.
/// 3. AppleScript documents-by-title for the rest: the active tab URL for
///    browsers — the same value AX would have reported as the window's
///    document had the Space been active.
///
/// Apps that restore their own windows (`ExcludedApps`) are left out.
/// 4. The shared identity resolver over (title, document), so VS Code's
///    workspace title and every other title rule apply unchanged.
///
/// Pure: every input is data, so the join is unit-testable without yabai,
/// AX, or AppleScript.
public enum CrossSpaceWindowIndex {

    /// Same floor `SnapshotEngine.capture` applies: smaller windows are
    /// palettes and transients, never a placement worth restoring.
    static let minimumSide: Double = 100

    public static func build(
        yabaiWindows: [YabaiWindow],
        bundleIDByPID: [pid_t: String],
        axLiveByWindowID: [CGWindowID: LiveWindow] = [:],
        documentsByTitle: [String: [String: URL]] = [:],
        displayBoundsByID: [String: CGRectCodable],
        resolver: WindowIdentityResolver = .defaultV1()
    ) -> [CrossSpaceWindow] {
        let candidates = yabaiWindows.filter { w in
            w.isStandardPlacement
                && !(w.isMinimized ?? false)
                && !(w.isHidden ?? false)
                && w.frame.w >= minimumSide && w.frame.h >= minimumSide
                && bundleIDByPID[w.pid].map { !ExcludedApps.contains($0) } ?? false
        }

        // Creation ordinals for windows AX has not seen: CG window numbers
        // are handed out in creation order, so rank within the app by id.
        var ordinalByWindowID: [CGWindowID: Int] = [:]
        let byBundle = Dictionary(grouping: candidates) { bundleIDByPID[$0.pid]! }
        for (_, windows) in byBundle {
            for (ordinal, w) in windows.sorted(by: { $0.id < $1.id }).enumerated() {
                ordinalByWindowID[w.id] = ordinal
            }
        }

        var out: [CrossSpaceWindow] = []
        out.reserveCapacity(candidates.count)
        for w in candidates {
            let bundleID = bundleIDByPID[w.pid]!
            let frame = w.frame.rect
            let displayID = displayBoundsByID
                .max(by: { intersectionArea($0.value, frame) < intersectionArea($1.value, frame) })?
                .key ?? (displayBoundsByID.keys.sorted().first ?? "")

            let live: LiveWindow
            if let ax = axLiveByWindowID[w.id] {
                live = ax
            } else {
                let document = documentsByTitle[bundleID].flatMap {
                    DeepIdentityFetcher.documentURL(forWindowTitle: w.title, bundleID: bundleID, in: $0)
                }
                let ordinal = ordinalByWindowID[w.id] ?? 0
                let identity = resolver.resolve(WindowSignal(
                    bundleID: bundleID,
                    title: w.title,
                    documentURL: document,
                    appProviderIdentity: nil,
                    creationOrdinal: ordinal
                ))
                live = LiveWindow(
                    bundleID: bundleID,
                    identity: identity,
                    ordinalInApp: ordinal,
                    currentFrame: frame,
                    currentDisplayFingerprintID: displayID,
                    windowID: w.id,
                    isFullscreen: w.isNativeFullscreen ?? false
                )
            }
            out.append(CrossSpaceWindow(live: live, spaceIndex: w.pixputSpaceIndex))
        }
        return out.sorted { ($0.live.bundleID, $0.live.windowID ?? 0) < ($1.live.bundleID, $1.live.windowID ?? 0) }
    }

    private static func intersectionArea(_ a: CGRectCodable, _ b: CGRectCodable) -> CGFloat {
        let i = a.cgRect.intersection(b.cgRect)
        if i.isNull || i.isEmpty { return 0 }
        return i.width * i.height
    }
}
