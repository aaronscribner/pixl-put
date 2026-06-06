import Foundation
import AppKit

/// Runs AppleScript source strings and surfaces `errAEEventNotPermitted`
/// (the macOS Automation-permission-denied error) as a typed case so
/// callers can implement the lazy per-bundle fallback required by spec
/// FR-014 / FR-015.
///
/// Wrapped behind a protocol so unit tests can inject a fake executor —
/// no real AppleScript fires in tests.
public protocol AppleScriptExecuting: Sendable {
    func execute(_ source: String) throws -> NSAppleEventDescriptor
}

public struct AppleScriptError: Error, Equatable {
    public enum Kind: Equatable {
        case automationDenied(bundleID: String?)
        case targetAppNotRunning
        case compileFailed
        case executionFailed(code: Int)
        case timedOut
    }
    public let kind: Kind
    public let message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}

public struct AppleScriptExecutor: AppleScriptExecuting {

    public init() {}

    public func execute(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else {
            throw AppleScriptError(kind: .compileFailed, message: "NSAppleScript(source:) returned nil")
        }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)

        if let errorInfo = errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "(unknown)"
            let appName = (errorInfo[NSAppleScript.errorAppName] as? String)

            switch code {
            case -1743:
                // errAEEventNotPermitted — user denied Automation for the target bundle,
                // OR the bundle isn't listed in the app's Apple-Events usage description.
                throw AppleScriptError(kind: .automationDenied(bundleID: appName), message: message)
            case -600, -609, -1708:
                // -600 procNotFound, -609 connectionInvalid, -1708 errAEEventNotHandled.
                throw AppleScriptError(kind: .targetAppNotRunning, message: message)
            case -1712:
                // errAETimeout
                throw AppleScriptError(kind: .timedOut, message: message)
            default:
                throw AppleScriptError(kind: .executionFailed(code: code), message: message)
            }
        }

        return result
    }
}

/// Parses common AppleScript result shapes. AppleScript returns lists
/// via `NSAppleEventDescriptor` with `numberOfItems` and 1-based indexing.
public enum AppleScriptResult {

    /// Top-level list of strings: each item must be a string.
    public static func stringList(_ descriptor: NSAppleEventDescriptor) -> [String]? {
        guard descriptor.descriptorType == typeAEList else {
            if let s = descriptor.stringValue { return [s] }
            return nil
        }
        // `numberOfItems` may be 0 for an empty list — `1...0` is an
        // invalid range that traps. Use stride which handles N == 0.
        let n = descriptor.numberOfItems
        guard n > 0 else { return [] }
        var out: [String] = []
        out.reserveCapacity(n)
        for i in 1...n {
            guard let item = descriptor.atIndex(i),
                  let s = item.stringValue else {
                continue
            }
            out.append(s)
        }
        return out
    }

    /// Top-level list of lists of strings: each inner item must be a string list.
    public static func nestedStringList(_ descriptor: NSAppleEventDescriptor) -> [[String]]? {
        guard descriptor.descriptorType == typeAEList else { return nil }
        let n = descriptor.numberOfItems
        guard n > 0 else { return [] }
        var out: [[String]] = []
        out.reserveCapacity(n)
        for i in 1...n {
            guard let inner = descriptor.atIndex(i),
                  let strings = stringList(inner) else {
                out.append([])
                continue
            }
            out.append(strings)
        }
        return out
    }
}
