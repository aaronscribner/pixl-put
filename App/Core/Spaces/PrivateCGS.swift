import Foundation
import CoreGraphics

/// **The single isolation point for private CoreGraphics symbols** in the app
/// per project constitution §VI and ADR-0001 (roadmap/arch/decisions/0001-private-cgs-for-spaces.md).
/// No other file in the app may reference any CGS-prefixed symbol.
///
/// Symbols are resolved via `dlsym` against the running process's symbol
/// namespace at first call, then cached. If a symbol is unavailable on the
/// host macOS (because Apple removed it in a future release), the cache
/// records `nil` and the public-API surface (`SpaceResolver`) falls back to
/// the documented degraded behaviour rather than crashing.
enum PrivateCGS {

    typealias CGSConnectionID = UInt32
    typealias CGSManagedDisplay = CFString
    typealias CGSSpaceID = UInt64

    // MARK: - Function-pointer type signatures
    // These match the publicly-known signatures used by Hammerspoon, yabai,
    // and other tools. If a future macOS changes them, the call site here
    // will fail gracefully (returns `nil` / empty array).

    typealias CGSMainConnectionIDFn = @convention(c) () -> CGSConnectionID

    typealias CGSGetActiveSpaceFn = @convention(c) (CGSConnectionID) -> CGSSpaceID

    typealias CGSCopyManagedDisplaySpacesFn = @convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?

    /// `CGSCopySpacesForWindows(connection, mask, [CGWindowID]) -> CFArray<CGSSpaceID>`
    /// Returns the Space IDs each CG window currently belongs to. Mask is
    /// usually `kCGSAllSpacesMask = 7`.
    typealias CGSCopySpacesForWindowsFn = @convention(c) (
        CGSConnectionID, UInt32, CFArray
    ) -> Unmanaged<CFArray>?

    /// `CGSProcessAssignToSpace(connection, pid, CGSSpaceID)`
    ///
    /// The only mechanism that relocates windows belonging to *another*
    /// process across Spaces (ADR-0002). The per-window calls
    /// (`CGSMoveWindowsToManagedSpace`, `CGSAddWindowsToSpaces`) are gated on
    /// CGS connection ownership and silently do nothing for foreign windows —
    /// measured 0/6 on macOS 26.2. This one is not.
    ///
    /// Two properties the caller must design around:
    /// - **Process-scoped.** Every window of `pid` moves. One app's windows
    ///   cannot be split across Spaces.
    /// - **Sticky for the process lifetime.** Windows opened afterwards also
    ///   land on the assigned Space, like Dock → Options → "Assign To". It is
    ///   pid state, not a saved preference: it clears when the app quits, and
    ///   there is no unassign symbol.
    typealias CGSProcessAssignToSpaceFn = @convention(c) (
        CGSConnectionID, pid_t, CGSSpaceID
    ) -> Void

    // MARK: - Resolved function pointers (lazily loaded)

    private static let resolveLock = NSLock()
    private static var resolved: ResolvedSymbols?

    private struct ResolvedSymbols {
        let mainConnectionID: CGSMainConnectionIDFn?
        let getActiveSpace: CGSGetActiveSpaceFn?
        let copyManagedDisplaySpaces: CGSCopyManagedDisplaySpacesFn?
        let copySpacesForWindows: CGSCopySpacesForWindowsFn?
        let processAssignToSpace: CGSProcessAssignToSpaceFn?
    }

    private static func symbols() -> ResolvedSymbols {
        resolveLock.lock()
        defer { resolveLock.unlock() }
        if let resolved = resolved { return resolved }

        let result = ResolvedSymbols(
            mainConnectionID: loadSymbol("CGSMainConnectionID"),
            getActiveSpace: loadSymbol("CGSGetActiveSpace"),
            copyManagedDisplaySpaces: loadSymbol("CGSCopyManagedDisplaySpaces"),
            copySpacesForWindows: loadSymbol("CGSCopySpacesForWindows"),
            processAssignToSpace: loadSymbol("CGSProcessAssignToSpace")
        )
        resolved = result
        return result
    }

    private static func loadSymbol<T>(_ name: String) -> T? {
        guard let handle = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {
            // -2 is RTLD_DEFAULT — search the process's loaded symbol namespace.
            return nil
        }
        return unsafeBitCast(handle, to: T.self)
    }

    // MARK: - Public API

    /// Returns the active Space ID. Returns `nil` if the private symbol is
    /// unavailable on this macOS (the caller should fall back to the
    /// "default Space 0" degraded path per ADR-0001).
    static func activeSpaceID() -> CGSSpaceID? {
        let s = symbols()
        guard let conn = s.mainConnectionID?(),
              let getActive = s.getActiveSpace else {
            return nil
        }
        return getActive(conn)
    }

    /// Returns the list of managed Spaces per display, keyed by the
    /// display's CG-display-UUID string. Returns an empty dictionary when
    /// the private symbol is unavailable.
    static func managedDisplaySpaces() -> [String: [CGSSpaceID]] {
        let s = symbols()
        guard let conn = s.mainConnectionID?(),
              let copyFn = s.copyManagedDisplaySpaces,
              let result = copyFn(conn) else {
            return [:]
        }
        let array = result.takeRetainedValue() as Array
        var spacesByDisplay: [String: [CGSSpaceID]] = [:]
        for entry in array {
            guard let dict = entry as? [String: Any],
                  let displayUUID = dict["Display Identifier"] as? String,
                  let spaces = dict["Spaces"] as? [[String: Any]] else {
                continue
            }
            let spaceIDs = spaces.compactMap { $0["id64"] as? UInt64 }
            spacesByDisplay[displayUUID] = spaceIDs
        }
        return spacesByDisplay
    }

    /// Given a list of CG window IDs, return the set of Space IDs each
    /// belongs to. Mask `7` = all spaces (current + other displays + other
    /// Spaces). Returns an empty dict in degraded mode.
    ///
    /// NOT a per-window map for more than one window: every Space goes to the
    /// first window (see below). For a map, call `spaces(forWindow:)` per
    /// window — `NativeWindowQuery.spaceMap` does, after the bulk form dropped
    /// 169 of 170 windows from a live restore on 2026-09-13.
    static func spacesForWindows(_ windowIDs: [CGWindowID]) -> [CGWindowID: [CGSSpaceID]] {
        guard !windowIDs.isEmpty else { return [:] }
        let s = symbols()
        guard let conn = s.mainConnectionID?(),
              let copyFn = s.copySpacesForWindows else {
            return [:]
        }
        let cfWindowIDs = windowIDs.map { NSNumber(value: $0) } as CFArray
        guard let result = copyFn(conn, 7, cfWindowIDs) else { return [:] }
        let spaceArray = result.takeRetainedValue() as Array
        // `CGSCopySpacesForWindows` returns the UNION of Space IDs across all
        // windows in one flat array. To attribute each Space to a specific
        // window, we call it per-window instead — the cost is one CGS call
        // per off-Space window, which is bounded by snapshot size.
        // For the bulk-call case here, we approximate by attributing all
        // returned Spaces to the FIRST window — the per-window enrichment
        // below uses the single-window form anyway. This bulk form just
        // tells the caller whether the symbol is functional.
        guard let firstWindow = windowIDs.first else { return [:] }
        let spaceIDs = spaceArray.compactMap { ($0 as? NSNumber)?.uint64Value }
        return [firstWindow: spaceIDs]
    }

    /// Returns the Space IDs the given single window currently belongs to.
    /// Lighter wrapper for the common "what Space is THIS window on" query.
    static func spaces(forWindow windowID: CGWindowID) -> [CGSSpaceID] {
        spacesForWindows([windowID])[windowID] ?? []
    }

    /// The one Space a window belongs to, or `nil` when it reports zero Spaces
    /// (mid-teardown) **or more than one** (a sticky "all Desktops" window).
    ///
    /// The multi-Space case is the important one. Taking `.first` of a sticky
    /// window's list looks like an answer but is really just the lowest Space
    /// ID in the set, so sticky windows all "vote" for the first Space. In a
    /// capture with only a handful of windows they form a majority and drag the
    /// whole capture onto Space index 0 — measured 2026-08-12, three separate
    /// Desktops filed as Space 0. A window on every Space carries no
    /// information about which Space is active, so it must not vote at all.
    static func unambiguousSpace(forWindow windowID: CGWindowID) -> CGSSpaceID? {
        let all = spaces(forWindow: windowID)
        return all.count == 1 ? all.first : nil
    }

    /// The active Space's per-display index, taken from the managed-display
    /// structure's own `"Current Space"` entry.
    ///
    /// Preferred over `CGSGetActiveSpace` because it is read from the *same*
    /// array that defines what an index means, so the value and the ordering
    /// cannot disagree. `CGSGetActiveSpace` is a separate, connection-scoped
    /// query; during a Space-switch transition the two have been observed
    /// reporting different Spaces.
    static func currentSpaceIndex(displayUUID: String? = nil) -> Int? {
        let s = symbols()
        guard let conn = s.mainConnectionID?(),
              let copyFn = s.copyManagedDisplaySpaces,
              let result = copyFn(conn) else {
            return nil
        }
        let array = result.takeRetainedValue() as Array
        var candidates: [(uuid: String, index: Int)] = []
        for entry in array {
            guard let dict = entry as? [String: Any],
                  let uuid = dict["Display Identifier"] as? String,
                  let spaces = dict["Spaces"] as? [[String: Any]],
                  let current = (dict["Current Space"] as? [String: Any])?["id64"] as? UInt64
            else { continue }
            let ids = spaces.compactMap { $0["id64"] as? UInt64 }
            guard let index = ids.firstIndex(of: current) else { continue }
            candidates.append((uuid, index))
        }
        if let uuid = displayUUID, let match = candidates.first(where: { $0.uuid == uuid }) {
            return match.index
        }
        // Same rule as `spaceID(atIndex:displayUUID:)`: without a usable display
        // hint an index only means something when there is one managed set.
        return candidates.count == 1 ? candidates[0].index : nil
    }

    /// Desktop UUIDs of the one managed Space set, in Space order.
    ///
    /// `nil` when there is not exactly one managed set (ADR-0003: an index then
    /// doesn't say which set it belongs to) or when any Space reports an empty
    /// or duplicate UUID, so a caller keying storage by UUID can never merge two
    /// Desktops into one file. Measured 2026-09-14: every Desktop, including the
    /// first, reports a UUID matching yabai's.
    static func managedSpaceUUIDs() -> [String]? {
        let s = symbols()
        guard let conn = s.mainConnectionID?(),
              let copyFn = s.copyManagedDisplaySpaces,
              let result = copyFn(conn) else {
            return nil
        }
        let array = result.takeRetainedValue() as Array
        guard array.count == 1,
              let dict = array.first as? [String: Any],
              let spaces = dict["Spaces"] as? [[String: Any]] else {
            return nil
        }
        let uuids = spaces.compactMap { $0["uuid"] as? String }
        guard !uuids.isEmpty,
              uuids.count == spaces.count,
              !uuids.contains(where: \.isEmpty),
              Set(uuids).count == uuids.count else {
            return nil
        }
        return uuids
    }

    /// The ordered Space IDs of every managed display, keyed by display UUID.
    /// Index into the array is the per-display Space index used on disk.
    static func orderedSpaceIDs(forDisplayUUID uuid: String) -> [CGSSpaceID] {
        managedDisplaySpaces()[uuid] ?? []
    }

    /// Whether the host presents exactly one managed Space set — the only
    /// configuration this project supports (ADR-0003).
    ///
    /// True for a single display, and for the target hardware: a Samsung
    /// Odyssey G9 in dual-4K, which macOS exposes as two logical displays but
    /// which — with `com.apple.spaces spans-displays = 1` — CGS reports as one
    /// managed display named `"Main"` whose Spaces span the whole panel.
    ///
    /// When this is false, a bare Space *index* is ambiguous: every managed
    /// display's set has an index 0, and nothing in the index identifies which
    /// set was meant.
    static var isSingleManagedSpaceSet: Bool {
        managedDisplaySpaces().count == 1
    }

    /// The Space ID at `index`, or `nil` when the answer would be a guess.
    ///
    /// `displayUUID` — a CGS `"Display Identifier"`, **not** a PixPut
    /// `DisplayFingerprint.id` — resolves the index directly when supplied.
    /// Without it, the index is only meaningful if exactly one managed Space
    /// set exists (ADR-0003).
    ///
    /// This deliberately refuses rather than picking a display when the
    /// configuration is unsupported. The previous behaviour iterated an
    /// unordered dictionary and returned the first set containing the index,
    /// which is a coin flip across process launches — and a wrong answer here
    /// scatters an app's windows onto a Space the user never chose.
    ///
    /// An **unrecognised** `displayUUID` is ignored rather than refused: with
    /// one managed set there is only one meaning an index can have, so the
    /// lone set still answers. That keeps a stale or wrong-namespace hint
    /// (e.g. a `DisplayFingerprint.id`) from breaking restore on the supported
    /// hardware, while a genuinely ambiguous host still refuses.
    static func spaceID(atIndex index: Int, displayUUID: String?) -> CGSSpaceID? {
        guard index >= 0 else { return nil }
        let byDisplay = managedDisplaySpaces()

        if let uuid = displayUUID, let spaces = byDisplay[uuid] {
            return index < spaces.count ? spaces[index] : nil
        }
        // No usable display hint: only unambiguous when there is one set to mean.
        guard byDisplay.count == 1, let spaces = byDisplay.values.first else { return nil }
        return index < spaces.count ? spaces[index] : nil
    }

    /// Assign every window of `pid` to `spaceID`. Returns `false` when the
    /// symbol is unavailable — the caller degrades to frame-only restore.
    /// The call itself returns void and reports nothing, so callers that need
    /// certainty must verify via `spaces(forWindow:)`.
    @discardableResult
    static func assignProcess(pid: pid_t, toSpaceID spaceID: CGSSpaceID) -> Bool {
        let s = symbols()
        guard let conn = s.mainConnectionID?(), let assign = s.processAssignToSpace else {
            return false
        }
        assign(conn, pid, spaceID)
        return true
    }

    /// Whether cross-Space relocation is possible on this host.
    static var canRelocateAcrossSpaces: Bool {
        symbols().processAssignToSpace != nil && symbols().mainConnectionID != nil
    }

    /// Available iff the core private symbols resolved. Used by the
    /// menu-bar status surface ("Spaces preserved: yes/no").
    static var isAvailable: Bool {
        let s = symbols()
        return s.mainConnectionID != nil
            && s.getActiveSpace != nil
            && s.copyManagedDisplaySpaces != nil
    }

    /// Whether `CGSCopySpacesForWindows` resolved — required for cross-Space
    /// window enumeration. Independent from `isAvailable` so the caller
    /// can degrade gracefully if only this symbol is missing.
    static var isCrossSpaceAware: Bool {
        symbols().copySpacesForWindows != nil
    }
}
