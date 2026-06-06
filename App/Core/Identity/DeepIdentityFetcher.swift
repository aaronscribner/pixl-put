import Foundation

/// For each running app PixlPut knows how to script, fetches a list of
/// per-window deep identities in **one** AppleScript call (not one per
/// window). The result is indexed by per-app window ordinal so the capture
/// loop can map AX windows → deep identity in O(1) lookups.
///
/// Per project constitution §VII (Performance), the per-app batch matters:
/// running one AppleScript per window across 100 windows would blow the
/// 500ms capture budget. Batching keeps it to one round-trip per running
/// scripted app.
///
/// Per spec FR-014 + FR-015: Automation permission is per-bundle, lazy,
/// non-reprompting. When `execute()` raises `.automationDenied`, the
/// fetcher records the bundle as denied for this session and returns no
/// identities for it (resolver falls to layer 3 / 4 automatically).
public actor DeepIdentityFetcher {

    private let executor: any AppleScriptExecuting
    private var deniedBundles: Set<String> = []

    public init(executor: any AppleScriptExecuting = AppleScriptExecutor()) {
        self.executor = executor
    }

    /// Reset the per-session denial cache. Called on app launch.
    public func resetSession() {
        deniedBundles.removeAll()
    }

    /// Whether the given bundle has been marked Automation-denied this session.
    public func isDenied(_ bundleID: String) -> Bool {
        deniedBundles.contains(bundleID)
    }

    /// Whether a bundle has a registered AppleScript probe. Public seam
    /// so callers outside `PixlPutCore` (the executable target's
    /// `AXRestorerBackend`) can filter the set of bundles to probe
    /// without reaching into the internal `ScriptRegistry`.
    public nonisolated static func isScripted(bundleID: String) -> Bool {
        ScriptRegistry.script(forBundleID: bundleID) != nil
    }

    /// All bundle IDs PixlPut knows how to probe for deep identity.
    /// Used by the deep-identity wizard to show the user the menu of
    /// per-app integrations they can opt in to.
    public nonisolated static func allScriptedBundleIDs() -> [String] {
        [
            "com.brave.Browser",
            "com.microsoft.edgemac",
            "com.google.Chrome",
            "company.thebrowser.Browser",
            "com.apple.Safari",
            "com.apple.dt.Xcode",
            "com.googlecode.iterm2",
        ]
    }

    /// Probe a bundle and return the outcome — used by the wizard so the
    /// UI can show per-app status (granted / denied / not running / no
    /// windows) without inferring it from a nil result.
    public enum ProbeOutcome: Sendable, Equatable {
        case granted(windowCount: Int)
        case denied
        case appNotRunning
        case noScript
        case error(String)
    }

    public func probe(bundleID: String) async -> ProbeOutcome {
        guard let script = ScriptRegistry.script(forBundleID: bundleID) else {
            return .noScript
        }
        do {
            let result = try executor.execute(script.source)
            let parsed = script.parse(result) ?? [:]
            // Successful execution clears any prior denial cache.
            deniedBundles.remove(bundleID)
            return .granted(windowCount: parsed.count)
        } catch let error as AppleScriptError {
            switch error.kind {
            case .automationDenied:
                deniedBundles.insert(bundleID)
                return .denied
            case .targetAppNotRunning:
                return .appNotRunning
            case .timedOut, .compileFailed, .executionFailed:
                return .error(error.message)
            }
        } catch {
            return .error("\(error)")
        }
    }

    /// Returns identities keyed by per-app window ordinal (0-indexed).
    /// `nil` return = no identities (script unavailable, app not running,
    /// or Automation denied this session).
    public func identitiesForApp(bundleID: String) -> [Int: WindowIdentity]? {
        if deniedBundles.contains(bundleID) { return nil }
        guard let script = ScriptRegistry.script(forBundleID: bundleID) else { return nil }

        do {
            let result = try executor.execute(script.source)
            return script.parse(result)
        } catch let error as AppleScriptError {
            switch error.kind {
            case .automationDenied:
                deniedBundles.insert(bundleID)
                return nil
            case .targetAppNotRunning, .timedOut, .compileFailed, .executionFailed:
                return nil
            }
        } catch {
            return nil
        }
    }
}

/// Maps bundle IDs to AppleScript source + result parsing. Adding a new
/// scripted bundle is a new entry here + (if needed) a new
/// `WindowIdentityProvider` for any identity-construction logic not
/// already covered.
enum ScriptRegistry {

    struct Script {
        let source: String
        let parse: @Sendable (NSAppleEventDescriptor) -> [Int: WindowIdentity]?
    }

    static func script(forBundleID bundleID: String) -> Script? {
        switch bundleID {
        case "com.brave.Browser":
            return chromiumBrowser(appName: "Brave Browser")
        case "com.microsoft.edgemac":
            return chromiumBrowser(appName: "Microsoft Edge")
        case "com.google.Chrome":
            return chromiumBrowser(appName: "Google Chrome")
        case "company.thebrowser.Browser":
            return chromiumBrowser(appName: "Arc")
        case "com.apple.Safari":
            return safari()
        case "com.apple.dt.Xcode":
            return xcode()
        case "com.googlecode.iterm2":
            return iTerm2()
        default:
            return nil
        }
    }

    // MARK: - Chromium-family (Brave / Edge / Chrome / Arc)

    private static func chromiumBrowser(appName: String) -> Script {
        // Returns a list (windows) of lists (tab URLs).
        // `URL of tabs` is the same across Brave / Edge / Chrome / Arc.
        let source = """
        tell application "\(appName)"
            set winURLs to {}
            repeat with w in windows
                set urls to {}
                repeat with t in tabs of w
                    set end of urls to URL of t
                end repeat
                set end of winURLs to urls
            end repeat
            return winURLs
        end tell
        """
        return Script(source: source, parse: parseTabSets)
    }

    private static let parseTabSets: @Sendable (NSAppleEventDescriptor) -> [Int: WindowIdentity]? = { descriptor in
        guard let perWindow = AppleScriptResult.nestedStringList(descriptor) else { return nil }
        let provider = BrowserTabSetProvider()
        var out: [Int: WindowIdentity] = [:]
        for (idx, urls) in perWindow.enumerated() {
            let parsedURLs = urls.compactMap { URL(string: $0) }
            if let id = provider.identity(from: parsedURLs) {
                out[idx] = id
            }
        }
        return out
    }

    // MARK: - Safari

    private static func safari() -> Script {
        // Safari uses `URL of current tab` per window (one URL/window in v1;
        // Safari's tab API exists but its `URL` per tab is asymmetric vs Chromium).
        let source = """
        tell application "Safari"
            set winURLs to {}
            repeat with w in windows
                try
                    set u to URL of current tab of w
                    set end of winURLs to {u}
                on error
                    set end of winURLs to {}
                end try
            end repeat
            return winURLs
        end tell
        """
        return Script(source: source, parse: parseTabSets)
    }

    // MARK: - Xcode

    private static func xcode() -> Script {
        // Returns workspace document path per window (or "" when none).
        let source = """
        tell application "Xcode"
            set paths to {}
            repeat with w in windows
                try
                    set p to path of document of w
                    set end of paths to p
                on error
                    set end of paths to ""
                end try
            end repeat
            return paths
        end tell
        """
        return Script(source: source, parse: parseEditorWorkspaces)
    }

    private static let parseEditorWorkspaces: @Sendable (NSAppleEventDescriptor) -> [Int: WindowIdentity]? = { descriptor in
        guard let paths = AppleScriptResult.stringList(descriptor) else { return nil }
        var out: [Int: WindowIdentity] = [:]
        for (idx, path) in paths.enumerated() {
            guard !path.isEmpty else { continue }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            out[idx] = .editorWorkspace(url)
        }
        return out
    }

    // MARK: - iTerm2

    private static func iTerm2() -> Script {
        // Returns current-session path per window.
        let source = """
        tell application "iTerm2"
            set paths to {}
            repeat with w in windows
                try
                    set p to path of current session of w
                    set end of paths to p
                on error
                    set end of paths to ""
                end try
            end repeat
            return paths
        end tell
        """
        return Script(source: source, parse: parseTerminalCWDs)
    }

    private static let parseTerminalCWDs: @Sendable (NSAppleEventDescriptor) -> [Int: WindowIdentity]? = { descriptor in
        guard let paths = AppleScriptResult.stringList(descriptor) else { return nil }
        var out: [Int: WindowIdentity] = [:]
        for (idx, path) in paths.enumerated() {
            guard !path.isEmpty else { continue }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            out[idx] = .terminalCWD(url)
        }
        return out
    }
}
