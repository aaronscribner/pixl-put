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

    /// `CGSMoveWindowsToManagedSpace(connection, [CGWindowID], CGSSpaceID)`
    /// Relocates the given CG windows onto the target Space. This is the
    /// ONLY mechanism that moves a window between Spaces — AX and the public
    /// CG API cannot (see research.md R-7). Write-side SLS/CGS symbols carry
    /// a higher "removed in a future macOS" risk than the read-side ones, so
    /// the call degrades to a no-op (returns `false`) when unavailable.
    typealias CGSMoveWindowsToManagedSpaceFn = @convention(c) (
        CGSConnectionID, CFArray, CGSSpaceID
    ) -> Void

    // MARK: - Resolved function pointers (lazily loaded)

    private static let resolveLock = NSLock()
    private static var resolved: ResolvedSymbols?

    private struct ResolvedSymbols {
        let mainConnectionID: CGSMainConnectionIDFn?
        let getActiveSpace: CGSGetActiveSpaceFn?
        let copyManagedDisplaySpaces: CGSCopyManagedDisplaySpacesFn?
        let copySpacesForWindows: CGSCopySpacesForWindowsFn?
        let moveWindowsToManagedSpace: CGSMoveWindowsToManagedSpaceFn?
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
            moveWindowsToManagedSpace: loadSymbol("CGSMoveWindowsToManagedSpace")
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

    /// Relocate CG windows onto `spaceID`. Returns `false` (no-op) when the
    /// write-side symbol is unavailable on this macOS — the caller degrades
    /// to frame-only restoration.
    @discardableResult
    static func moveWindows(_ windowIDs: [CGWindowID], toSpace spaceID: CGSSpaceID) -> Bool {
        guard !windowIDs.isEmpty else { return false }
        let s = symbols()
        guard let conn = s.mainConnectionID?(),
              let moveFn = s.moveWindowsToManagedSpace else {
            return false
        }
        let cfWindowIDs = windowIDs.map { NSNumber(value: $0) } as CFArray
        moveFn(conn, cfWindowIDs, spaceID)
        return true
    }

    /// Whether `CGSMoveWindowsToManagedSpace` resolved — required to relocate
    /// windows across Spaces (the "Restore Spaces" command). Independent from
    /// `isAvailable` so the caller can degrade to frame-only restoration.
    static var canMoveWindows: Bool {
        let s = symbols()
        return s.mainConnectionID != nil && s.moveWindowsToManagedSpace != nil
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
