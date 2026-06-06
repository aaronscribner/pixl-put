import Foundation
import AppKit
import ApplicationServices
import PixlPutCore

/// Drives the permission state machine on launch:
///   1. Accessibility permission check (hard requirement).
///   2. Automation permission per-bundle (lazy — only when first needed).
///
/// Per project constitution §V (Graceful permission degradation), the app
/// must work as well as the permissions allow, surface what's missing in
/// context, and never silently fail.
public final class PermissionsBootstrap: @unchecked Sendable {

    public enum State: Equatable {
        case accessibilityGranted
        case accessibilityMissingNeedsOnboarding
    }

    public init() {}

    public func currentState() -> State {
        AXIsProcessTrusted() ? .accessibilityGranted : .accessibilityMissingNeedsOnboarding
    }

    /// Prompt the user to grant Accessibility permission. Opens the
    /// system dialog (first time) or System Settings (subsequent times).
    /// Returns the new state immediately after the call — the actual
    /// trust check is repeated by `currentState()` periodically since
    /// AX may be granted out-of-band.
    public func requestAccessibility() -> State {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: kCFBooleanTrue!] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        return currentState()
    }

    /// Open Accessibility settings directly — used by the onboarding view
    /// when the system prompt has already been shown once and the user
    /// dismissed it.
    public func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Periodic poll — the system doesn't deliver a notification when AX
    /// is granted, so the menu bar polls via this method every few seconds.
    public func refreshAndNotify(_ onChange: (State) -> Void) {
        let state = currentState()
        onChange(state)
    }
}
