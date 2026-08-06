#!/usr/bin/env swift
// Ground-truth probe for cross-Space window relocation.
//
// 56f4b1f removed "Restore Spaces" on the claim that CGS Space relocation and
// switching are "unreliable". This script measures that claim instead of
// asserting it: every write is followed by a re-read, so the verdict is what
// the window system actually did, not what the API returned (it returns void).
//
// DEV TOOL. Not linked into the app, not shipped. Requires SIP disabled only
// if the write-side symbols turn out to need it — establishing that is the
// point of the exercise.
//
// Usage:
//   swift scripts/probe-spaces.swift                    # topology + symbol report
//   swift scripts/probe-spaces.swift --windows          # ...plus every window and its Space
//   swift scripts/probe-spaces.swift --switch <spaceID>
//   swift scripts/probe-spaces.swift --move <windowID> <spaceID>
//   swift scripts/probe-spaces.swift --trial <windowID> [reps]   # success rate over a round trip
//
// Find a <windowID> with --windows. The trial always tries to put the window
// back where it started; if it dies mid-run the "origin" line tells you where.

import Foundation
import CoreGraphics
import AppKit

// MARK: - Private symbol resolution

typealias CGSConnectionID = UInt32
typealias CGSSpaceID = UInt64

func sym<T>(_ name: String) -> T? {
    // -2 == RTLD_DEFAULT: search the process's already-loaded symbol namespace.
    guard let handle = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
    return unsafeBitCast(handle, to: T.self)
}

let CGSMainConnectionID: (@convention(c) () -> CGSConnectionID)? = sym("CGSMainConnectionID")
let CGSGetActiveSpace: (@convention(c) (CGSConnectionID) -> CGSSpaceID)? = sym("CGSGetActiveSpace")
let CGSCopyManagedDisplaySpaces: (@convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?)? = sym("CGSCopyManagedDisplaySpaces")
let CGSCopySpacesForWindows: (@convention(c) (CGSConnectionID, UInt32, CFArray) -> Unmanaged<CFArray>?)? = sym("CGSCopySpacesForWindows")
let CGSMoveWindowsToManagedSpace: (@convention(c) (CGSConnectionID, CFArray, CGSSpaceID) -> Void)? = sym("CGSMoveWindowsToManagedSpace")
let CGSManagedDisplaySetCurrentSpace: (@convention(c) (CGSConnectionID, CFString, CGSSpaceID) -> Void)? = sym("CGSManagedDisplaySetCurrentSpace")

let symbolTable: [(String, Bool, String)] = [
    ("CGSMainConnectionID", CGSMainConnectionID != nil, "read"),
    ("CGSGetActiveSpace", CGSGetActiveSpace != nil, "read"),
    ("CGSCopyManagedDisplaySpaces", CGSCopyManagedDisplaySpaces != nil, "read"),
    ("CGSCopySpacesForWindows", CGSCopySpacesForWindows != nil, "read"),
    ("CGSMoveWindowsToManagedSpace", CGSMoveWindowsToManagedSpace != nil, "WRITE"),
    ("CGSManagedDisplaySetCurrentSpace", CGSManagedDisplaySetCurrentSpace != nil, "WRITE"),
]

guard let conn = CGSMainConnectionID?() else {
    print("FATAL: CGSMainConnectionID unavailable — no CGS access at all on this macOS.")
    exit(1)
}

// MARK: - Topology reads

struct DisplaySpaces {
    let identifier: String       // CFString key CGSManagedDisplaySetCurrentSpace wants
    let currentSpaceID: CGSSpaceID?
    let spaceIDs: [CGSSpaceID]
    let spaceTypes: [CGSSpaceID: Int]   // 0 = user Space, 4 = fullscreen
}

func managedDisplaySpaces() -> [DisplaySpaces] {
    guard let fn = CGSCopyManagedDisplaySpaces,
          let result = fn(conn) else { return [] }
    let raw = (result.takeRetainedValue() as? [[String: Any]]) ?? []
    return raw.compactMap { entry in
        guard let ident = entry["Display Identifier"] as? String else { return nil }
        let spaces = (entry["Spaces"] as? [[String: Any]]) ?? []
        var types: [CGSSpaceID: Int] = [:]
        var ids: [CGSSpaceID] = []
        for s in spaces {
            guard let id = (s["id64"] as? NSNumber)?.uint64Value else { continue }
            ids.append(id)
            types[id] = (s["type"] as? NSNumber)?.intValue ?? 0
        }
        let current = ((entry["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value
        return DisplaySpaces(identifier: ident, currentSpaceID: current, spaceIDs: ids, spaceTypes: types)
    }
}

func activeSpaceID() -> CGSSpaceID? { CGSGetActiveSpace?(conn) }

/// Space IDs a single window belongs to. Called per-window deliberately: the
/// bulk form unions results across all windows passed in and cannot attribute
/// a Space back to a specific window.
func spaces(forWindow wid: CGWindowID) -> [CGSSpaceID] {
    guard let fn = CGSCopySpacesForWindows else { return [] }
    let arg = [NSNumber(value: wid)] as CFArray
    guard let result = fn(conn, 7, arg) else { return [] }   // mask 7 == all Spaces
    let nums = (result.takeRetainedValue() as? [NSNumber]) ?? []
    return nums.map { $0.uint64Value }
}

struct WindowInfo {
    let id: CGWindowID
    let owner: String
    let title: String
    let bounds: CGRect
}

func onScreenWindows() -> [WindowInfo] {
    let list = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    return list.compactMap { w in
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              let num = w[kCGWindowNumber as String] as? CGWindowID,
              let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        return WindowInfo(
            id: num,
            owner: (w[kCGWindowOwnerName as String] as? String) ?? "?",
            title: (w[kCGWindowName as String] as? String) ?? "",
            bounds: CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        )
    }
}

// MARK: - Verified writes
//
// Both CGS write calls return void. The only way to know whether anything
// happened is to poll the corresponding read until it agrees or we give up.

@discardableResult
func pollUntil(timeout: TimeInterval = 2.0, interval: TimeInterval = 0.05, _ condition: () -> Bool) -> TimeInterval? {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        if condition() { return Date().timeIntervalSince(start) }
        Thread.sleep(forTimeInterval: interval)
    }
    return condition() ? Date().timeIntervalSince(start) : nil
}

/// Outcome of a verified relocation attempt. `alreadyThere` exists because a
/// window that never left its Space makes the *return* leg of a round trip
/// trivially "succeed" — counting that as a win reports 50% when the true
/// score is 0%.
enum MoveOutcome {
    case alreadyThere
    case landed(TimeInterval)
    case failed

    var countsAsAttempt: Bool { if case .alreadyThere = self { return false }; return true }
    var succeeded: Bool { if case .landed = self { return true }; return false }
    var describe: String {
        switch self {
        case .alreadyThere: return "no-op (already there)"
        case .landed(let t): return "landed in \(ms(t))"
        case .failed: return "FAILED"
        }
    }
}

/// Move `wid` to `target` and verify by re-reading — the call itself returns void,
/// so the read is the only source of truth.
func moveWindow(_ wid: CGWindowID, to target: CGSSpaceID) -> MoveOutcome {
    guard let fn = CGSMoveWindowsToManagedSpace else { return .failed }
    if spaces(forWindow: wid).contains(target) { return .alreadyThere }
    fn(conn, [NSNumber(value: wid)] as CFArray, target)
    if let t = pollUntil(timeout: 1.5, { spaces(forWindow: wid).contains(target) }) { return .landed(t) }
    return .failed
}

/// Switch `display` to `target` and verify via CGSGetActiveSpace.
func switchSpace(display: String, to target: CGSSpaceID) -> TimeInterval? {
    guard let fn = CGSManagedDisplaySetCurrentSpace else { return nil }
    fn(conn, display as CFString, target)
    return pollUntil { activeSpaceID() == target }
}

// MARK: - Output helpers

func ms(_ t: TimeInterval?) -> String { t.map { String(format: "%.0fms", $0 * 1000) } ?? "—" }

func printTopology() {
    let displays = managedDisplaySpaces()
    let active = activeSpaceID()
    print("Active Space: \(active.map(String.init) ?? "unknown")")
    print("Displays: \(displays.count)\n")
    for d in displays {
        print("  Display \(d.identifier)")
        for id in d.spaceIDs {
            let kind = d.spaceTypes[id] == 4 ? "fullscreen" : "user"
            var marks: [String] = []
            if id == d.currentSpaceID { marks.append("current-on-display") }
            if id == active { marks.append("ACTIVE") }
            let suffix = marks.isEmpty ? "" : "  <- \(marks.joined(separator: ", "))"
            print("    space \(id)  [\(kind)]\(suffix)")
        }
        print("")
    }
}

func printSymbols() {
    print("Private symbol availability (macOS \(ProcessInfo.processInfo.operatingSystemVersionString))\n")
    for (name, ok, kind) in symbolTable {
        print("  [\(ok ? "ok " : "MISSING")] \(kind.padding(toLength: 5, withPad: " ", startingAt: 0)) \(name)")
    }
    print("")
}

// MARK: - Commands

let args = Array(CommandLine.arguments.dropFirst())

func requireWriteSymbols() {
    guard CGSMoveWindowsToManagedSpace != nil, CGSManagedDisplaySetCurrentSpace != nil else {
        print("Write-side symbols unavailable — nothing to test. Run with no args for the report.")
        exit(1)
    }
}

/// The experiment that settles "unreliable": bounce a window between its own
/// Space and every other user Space on the same display, `reps` times, and
/// report how often the move actually landed.
func runTrial(_ wid: CGWindowID, reps: Int) {
    requireWriteSymbols()

    let origin = spaces(forWindow: wid)
    guard let home = origin.first else {
        print("Window \(wid) reports no Space — is the ID right? (use --windows)")
        exit(1)
    }
    guard let display = managedDisplaySpaces().first(where: { $0.spaceIDs.contains(home) }) else {
        print("Window \(wid) is on Space \(home), which no display claims. Aborting.")
        exit(1)
    }
    // Fullscreen Spaces host exactly one window and reject relocation; skip them.
    let targets = display.spaceIDs.filter { $0 != home && display.spaceTypes[$0] != 4 }
    guard !targets.isEmpty else {
        print("Display \(display.identifier) has no second user Space. Create one in Mission Control and re-run.")
        exit(1)
    }

    print("Window \(wid) — origin Space \(home) on display \(display.identifier)")
    print("Targets: \(targets.map(String.init).joined(separator: ", "))")
    print("Reps: \(reps)\n")

    var moveOK = 0, moveTotal = 0
    var latencies: [TimeInterval] = []

    func record(_ outcome: MoveOutcome, _ from: CGSSpaceID, _ to: CGSSpaceID, rep: Int) {
        if outcome.countsAsAttempt { moveTotal += 1 }
        if case .landed(let t) = outcome { moveOK += 1; latencies.append(t) }
        print("  rep \(rep)  \(from) -> \(to)   \(outcome.describe)")
    }

    for rep in 1...reps {
        for target in targets {
            let out = moveWindow(wid, to: target)
            record(out, home, target, rep: rep)
            // Only attempt the return leg if the window actually left. Otherwise
            // the return is a no-op that would inflate the success rate.
            guard out.succeeded else {
                print("  rep \(rep)  \(target) -> \(home)   skipped (never left \(home))")
                continue
            }
            record(moveWindow(wid, to: home), target, home, rep: rep)
        }
    }

    // Always try to leave the window where we found it.
    if !spaces(forWindow: wid).contains(home) {
        print("\n  window not on origin Space — restoring")
        _ = moveWindow(wid, to: home)
    }
    if moveTotal == 0 {
        print("\nNo relocation ever took effect — run --ownership \(wid) to see whether")
        print("this is the connection-ownership limit rather than a transient failure.")
    }

    let pct = moveTotal == 0 ? 0 : Double(moveOK) / Double(moveTotal) * 100
    print(String(format: "\nRelocation: %d/%d verified (%.1f%%)", moveOK, moveTotal, pct))
    if !latencies.isEmpty {
        let sorted = latencies.sorted()
        print("  settle median \(ms(sorted[sorted.count / 2]))  max \(ms(sorted.last))")
    }
    if spaces(forWindow: wid).contains(home) {
        print("  window returned to origin Space \(home)")
    } else {
        print("  WARNING: window left on Space \(spaces(forWindow: wid).map(String.init).joined(separator: ",")) — origin was \(home)")
    }
}

switch args.first {
case nil:
    printSymbols()
    printTopology()
    print("Add --windows to list windows, --trial <windowID> to measure relocation reliability.")

case "--windows":
    printSymbols()
    printTopology()
    let wins = onScreenWindows()
    print("Windows (\(wins.count)) — blank titles mean this terminal lacks Screen Recording permission\n")
    for w in wins.sorted(by: { $0.owner < $1.owner }) {
        let sp = spaces(forWindow: w.id).map(String.init).joined(separator: ",")
        let title = w.title.isEmpty ? "" : "  “\(w.title.prefix(48))”"
        print("  id \(String(w.id).padding(toLength: 7, withPad: " ", startingAt: 0)) space \(sp.padding(toLength: 8, withPad: " ", startingAt: 0)) \(w.owner)\(title)")
    }

case "--check":
    // Two independent readings of "where is this window": the CGS Space query,
    // and whether the window server currently lists it as on-screen. The second
    // does not go through CGSCopySpacesForWindows, so it can catch a stale read.
    guard args.count >= 2, let wid = CGWindowID(args[1]) else {
        print("Usage: --check <windowID>"); exit(1)
    }
    let onscreen = ((CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? [])
        .contains { ($0[kCGWindowNumber as String] as? CGWindowID) == wid }
    let sp = spaces(forWindow: wid).map(String.init).joined(separator: ",")
    print("window \(wid): CGS-space [\(sp)]  onscreen-now \(onscreen)  active-space \(activeSpaceID().map(String.init) ?? "?")")

case "--switch":
    requireWriteSymbols()
    guard args.count >= 2, let target = CGSSpaceID(args[1]) else {
        print("Usage: --switch <spaceID>"); exit(1)
    }
    guard let display = managedDisplaySpaces().first(where: { $0.spaceIDs.contains(target) }) else {
        print("No display owns Space \(target)."); exit(1)
    }
    let before = activeSpaceID()
    let settled = switchSpace(display: display.identifier, to: target)
    print("switch \(before.map(String.init) ?? "?") -> \(target) on \(display.identifier): \(settled == nil ? "FAILED (active Space unchanged)" : "verified in \(ms(settled))")")

case "--move":
    requireWriteSymbols()
    guard args.count >= 3, let wid = CGWindowID(args[1]), let target = CGSSpaceID(args[2]) else {
        print("Usage: --move <windowID> <spaceID>"); exit(1)
    }
    let before = spaces(forWindow: wid)
    let outcome = moveWindow(wid, to: target)
    print("before:  \(before.map(String.init).joined(separator: ","))")
    print("after:   \(spaces(forWindow: wid).map(String.init).joined(separator: ","))")
    print("verdict: \(outcome.describe)")

case "--ownership":
    // The decisive experiment. Relocates a window this process owns, then the
    // same call against a window owned by another process. A pass/fail split
    // means the limit is per-connection privilege — which no amount of SIP
    // disabling changes, because SIP is not what enforces it.
    requireWriteSymbols()
    guard let target = managedDisplaySpaces()
        .first(where: { $0.spaceIDs.contains(activeSpaceID() ?? 0) })
        .flatMap({ d in d.spaceIDs.first { $0 != activeSpaceID() && d.spaceTypes[$0] != 4 } })
    else {
        print("Need a second user Space on the active display."); exit(1)
    }
    print("target Space: \(target)\n")

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let win = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 320, height: 200),
                       styleMask: [.titled, .closable], backing: .buffered, defer: false)
    win.title = "PixPut ownership probe"
    win.makeKeyAndOrderFront(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    let ownID = CGWindowID(win.windowNumber)
    print("OWN window \(ownID) on \(spaces(forWindow: ownID))")
    print("  -> \(moveWindow(ownID, to: target).describe)   now on \(spaces(forWindow: ownID))")
    win.orderOut(nil)

    if args.count >= 2, let foreign = CGWindowID(args[1]) {
        let origin = spaces(forWindow: foreign)
        guard let home = origin.first else {
            print("\nFOREIGN window \(foreign) reports no Space — stale ID, pick another via --windows")
            exit(1)
        }
        print("\nFOREIGN window \(foreign) on \(origin)")
        print("  -> \(moveWindow(foreign, to: target).describe)   now on \(spaces(forWindow: foreign))")
        if !spaces(forWindow: foreign).contains(home) { _ = moveWindow(foreign, to: home) }
    } else {
        print("\nPass a foreign window ID (see --windows) for the other half of the comparison.")
    }

case "--trial":
    guard args.count >= 2, let wid = CGWindowID(args[1]) else {
        print("Usage: --trial <windowID> [reps]"); exit(1)
    }
    runTrial(wid, reps: args.count >= 3 ? (Int(args[2]) ?? 5) : 5)

default:
    print("Unknown option \(args[0]). Run with no arguments for usage.")
    exit(1)
}
