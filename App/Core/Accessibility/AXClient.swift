import Foundation
import ApplicationServices
import AppKit
import CoreGraphics

/// All Accessibility-API calls funnel through here. Every call runs on a
/// single serial dispatch queue (project constitution §VII operational
/// requirement) to prevent the AX deadlocks that occur when AX calls are
/// interleaved across threads.
///
/// The public API is async — callers await results without managing the
/// queue themselves. Cancellation propagates via `Task.cancel()`.
public actor AXClient {

    /// AX permission state — refreshed on every call so a runtime revoke
    /// (spec edge case "Accessibility permission revoked at runtime") is
    /// surfaced as a typed error rather than a silent failure.
    public enum AXError: Error, Equatable {
        case permissionDenied
        case windowGone
        case attributeUnavailable(String)
        case operationCancelled
    }

    private let queue: DispatchQueue

    public init() {
        self.queue = DispatchQueue(label: "co.cerebraljuice.pixlput.ax", qos: .utility)
    }

    /// Checks whether the app currently has Accessibility permission.
    /// Does NOT prompt — that's `PermissionsBootstrap`'s job.
    public nonisolated func hasPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompt the user for Accessibility permission (once per session
    /// typically — controlled by `PermissionsBootstrap`).
    public nonisolated func requestPermission() -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: kCFBooleanTrue!] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Enumerate every visible window across every running app. Excludes
    /// hidden / closed / Dock / Window-Server-only windows.
    public func enumerateWindows() async throws -> [AXWindow] {
        guard hasPermission() else { throw AXError.permissionDenied }
        try Task.checkCancellation()

        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                var windows: [AXWindow] = []
                var ordinalByBundle: [String: Int] = [:]

                for runningApp in NSWorkspace.shared.runningApplications {
                    guard let bundleID = runningApp.bundleIdentifier else { continue }
                    // Skip system services / faceless agents.
                    if runningApp.activationPolicy == .prohibited { continue }
                    let pid = runningApp.processIdentifier
                    let appElem = AXUIElementCreateApplication(pid)
                    var windowsRef: CFTypeRef?
                    let status = AXUIElementCopyAttributeValue(
                        appElem,
                        kAXWindowsAttribute as CFString,
                        &windowsRef
                    )
                    guard status == .success,
                          let axWindows = windowsRef as? [AXUIElement] else {
                        continue
                    }
                    for (idx, axWindow) in axWindows.enumerated() {
                        // All attribute reads run here, on the AX queue.
                        let title = AXClient.readString(axWindow, kAXTitleAttribute) ?? ""
                        let documentURL = AXClient.readDocumentURL(axWindow)
                        let frame = AXClient.readFrame(of: axWindow)
                        let isFullscreen = AXClient.readBool(axWindow, "AXFullScreen") ?? false
                        let isMinimized = AXClient.readBool(axWindow, kAXMinimizedAttribute) ?? false

                        // Skip windows without a frame — off-screen / hidden / not real windows.
                        guard let frame = frame else { continue }

                        let ordinal = (ordinalByBundle[bundleID] ?? 0)
                        ordinalByBundle[bundleID] = ordinal + 1
                        windows.append(AXWindow(
                            element: axWindow,
                            bundleID: bundleID,
                            creationOrdinal: ordinal,
                            indexInApp: idx,
                            title: title,
                            documentURL: documentURL,
                            frame: frame,
                            isFullscreen: isFullscreen,
                            isMinimized: isMinimized
                        ))
                    }
                }
                continuation.resume(returning: windows)
            }
        }
    }

    // MARK: - AX-queue-only read helpers

    static func readString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let s = ref as? String else { return nil }
        return s
    }

    static func readBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let b = ref as? Bool else { return nil }
        return b
    }

    static func readDocumentURL(_ element: AXUIElement) -> URL? {
        guard let s = readString(element, kAXDocumentAttribute),
              let url = URL(string: s) else { return nil }
        return url
    }

    /// Move a window to the given frame. Returns `true` if the window
    /// actually ended up at the requested frame (within `tolerance`).
    /// Returns `false` if `.cannotComplete` came back (user is dragging
    /// the window — FR-012), or if every attempt finished with the window
    /// still off-target (typically because the external display's virtual
    /// coordinate region isn't back yet at wake — macOS silently clamps).
    ///
    /// On wake, the AX setter for `kAXPositionAttribute` will return
    /// `.success` even when the position is silently clamped — the window
    /// reports as moved but actually stays on the main display. We
    /// re-read the frame, compare to the target, and retry up to 3 times
    /// with a small delay before giving up. Without this, a snapshot
    /// restore on wake reports `moved=N` but visually leaves windows on
    /// the main screen.
    public func move(_ window: AXWindow, to frame: CGRectCodable) async throws -> Bool {
        guard hasPermission() else { throw AXError.permissionDenied }
        try Task.checkCancellation()

        let tolerance: CGFloat = 2.0
        let maxAttempts = 3
        let interAttemptDelayNanos: UInt64 = 150_000_000  // 150 ms

        for attempt in 0..<maxAttempts {
            let result: AttemptResult = try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    var position = CGPoint(x: frame.x, y: frame.y)
                    var size = CGSize(width: frame.width, height: frame.height)
                    guard let posValue = AXValueCreate(.cgPoint, &position),
                          let sizeValue = AXValueCreate(.cgSize, &size) else {
                        continuation.resume(throwing: AXError.attributeUnavailable("AXValueCreate"))
                        return
                    }
                    let posStatus = AXUIElementSetAttributeValue(
                        window.element,
                        kAXPositionAttribute as CFString,
                        posValue
                    )
                    guard posStatus == .success || posStatus == .cannotComplete else {
                        continuation.resume(throwing: AXError.attributeUnavailable("position: \(posStatus.rawValue)"))
                        return
                    }
                    let sizeStatus = AXUIElementSetAttributeValue(
                        window.element,
                        kAXSizeAttribute as CFString,
                        sizeValue
                    )
                    guard sizeStatus == .success || sizeStatus == .cannotComplete else {
                        continuation.resume(throwing: AXError.attributeUnavailable("size: \(sizeStatus.rawValue)"))
                        return
                    }
                    if posStatus == .cannotComplete || sizeStatus == .cannotComplete {
                        // User is manipulating — give up, FR-012.
                        continuation.resume(returning: .cancelledByUser)
                        return
                    }
                    let actual = AXClient.readFrame(of: window.element)
                    continuation.resume(returning: .completed(actual: actual))
                }
            }

            switch result {
            case .cancelledByUser:
                return false
            case .completed(let actual):
                if let actual,
                   abs(actual.x - frame.x) <= tolerance,
                   abs(actual.y - frame.y) <= tolerance,
                   abs(actual.width - frame.width) <= tolerance,
                   abs(actual.height - frame.height) <= tolerance {
                    return true
                }
                // Off-target — likely clamped by macOS while displays
                // are still settling. Sleep briefly and retry.
                if attempt < maxAttempts - 1 {
                    try? await Task.sleep(nanoseconds: interAttemptDelayNanos)
                }
            }
        }
        return false
    }

    private enum AttemptResult {
        case cancelledByUser
        case completed(actual: CGRectCodable?)
    }

    /// Private AX symbol bridging an `AXUIElement` to its CoreGraphics window
    /// number. This is the only reliable AX→CGWindowID mapping and is what
    /// every macOS window manager uses; relocating a window across Spaces
    /// (`CGSMoveWindowsToManagedSpace`) needs the CGWindowID. Resolved via
    /// `dlsym` so the call degrades to `nil` if a future macOS removes it.
    private static let getWindowFn: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> Int32)? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else {
            return nil
        }
        return unsafeBitCast(sym, to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> Int32).self)
    }()

    /// The CoreGraphics window number for an AX window, or `nil` if the
    /// private symbol is unavailable or the lookup fails. Runs on the AX
    /// queue per constitution §VII.
    public func windowID(of window: AXWindow) async -> CGWindowID? {
        guard let fn = Self.getWindowFn else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async {
                var wid = CGWindowID(0)
                let status = fn(window.element, &wid)
                continuation.resume(returning: status == 0 && wid != 0 ? wid : nil)
            }
        }
    }

    /// Set a window's fullscreen state. Returns whether the operation completed.
    public func setFullscreen(_ window: AXWindow, _ value: Bool) async throws -> Bool {
        guard hasPermission() else { throw AXError.permissionDenied }
        try Task.checkCancellation()

        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let status = AXUIElementSetAttributeValue(
                    window.element,
                    "AXFullScreen" as CFString,
                    value as CFTypeRef
                )
                continuation.resume(returning: status == .success)
            }
        }
    }

    /// Read the current frame of a window. Used by Restorer's
    /// already-at-frame check.
    public func frame(of window: AXWindow) async throws -> CGRectCodable {
        guard hasPermission() else { throw AXError.permissionDenied }
        try Task.checkCancellation()

        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let frame = AXClient.readFrame(of: window.element)
                guard let frame else {
                    continuation.resume(throwing: AXError.attributeUnavailable("frame"))
                    return
                }
                continuation.resume(returning: frame)
            }
        }
    }

    static func readFrame(of element: AXUIElement) -> CGRectCodable? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posValue = posRef, let sizeValue = sizeRef else {
            return nil
        }
        // Safety: AXValueRef ABI-compatible with CFTypeRef in this path.
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRectCodable(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }
}
