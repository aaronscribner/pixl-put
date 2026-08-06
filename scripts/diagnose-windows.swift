#!/usr/bin/env swift
// Compare the CURRENT on-screen window positions to a saved snapshot/master
// and explain every mismatch. Ground truth — no app internals, no guessing.
//
// Usage:
//   swift scripts/diagnose-windows.swift [path-to-.plist]
// Defaults to the newest *.master.plist under the snapshot store.

import Foundation
import CoreGraphics
import AppKit

// MARK: - Locate the saved snapshot

let storeDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/DisplayMaid-Next/snapshots")

let snapshotURL: URL = {
    if CommandLine.arguments.count > 1 { return URL(fileURLWithPath: CommandLine.arguments[1]) }
    let masters = (try? FileManager.default.contentsOfDirectory(at: storeDir, includingPropertiesForKeys: [.contentModificationDateKey]))?
        .filter { $0.lastPathComponent.hasSuffix(".master.plist") } ?? []
    let newest = masters.max { a, b in
        let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return da < db
    }
    return newest ?? storeDir.appendingPathComponent("none.plist")
}()

guard let data = try? Data(contentsOf: snapshotURL),
      let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
      let savedWindows = plist["windows"] as? [[String: Any]] else {
    print("Could not read snapshot at \(snapshotURL.path)"); exit(1)
}
print("Saved layout: \(snapshotURL.lastPathComponent)  (\(savedWindows.count) windows)\n")

// MARK: - Current live windows (all Spaces), keyed by CG window number

let cgList = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
struct Live { let bounds: CGRect; let owner: String; let title: String }
var liveByNumber: [Int: Live] = [:]
for w in cgList {
    guard let num = w[kCGWindowNumber as String] as? Int,
          let b = w[kCGWindowBounds as String] as? [String: CGFloat],
          (w[kCGWindowLayer as String] as? Int) == 0 else { continue }
    let rect = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
    liveByNumber[num] = Live(bounds: rect,
                             owner: (w[kCGWindowOwnerName as String] as? String) ?? "?",
                             title: (w[kCGWindowName as String] as? String) ?? "")
}
print("Live on-screen windows now: \(liveByNumber.count)\n")

// MARK: - Compare

func frame(_ d: Any?) -> CGRect? {
    guard let f = d as? [String: Any] else { return nil }
    func n(_ k: String) -> CGFloat { (f[k] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0 }
    return CGRect(x: n("x"), y: n("y"), width: n("width"), height: n("height"))
}

var correct = 0, misplaced = 0, missingWID = 0, noWID = 0
let tol: CGFloat = 5

for sw in savedWindows {
    let bundle = (sw["bundleID"] as? String) ?? "?"
    let space = (sw["spaceIndex"] as? Int) ?? -1
    guard let saved = frame(sw["frame"]) else { continue }
    let short = "\(bundle) [space \(space)] saved=(\(Int(saved.minX)),\(Int(saved.minY)) \(Int(saved.width))x\(Int(saved.height)))"

    guard let wid = (sw["windowID"] as? NSNumber)?.intValue else {
        noWID += 1
        print("• NO-WINDOWID  \(short)  — saved before window numbers existed; can only match by content")
        continue
    }
    guard let live = liveByNumber[wid] else {
        missingWID += 1
        print("• GONE         \(short)  — window #\(wid) no longer exists (closed, or app relaunched → new number)")
        continue
    }
    let dx = live.bounds.minX - saved.minX, dy = live.bounds.minY - saved.minY
    if abs(dx) <= tol && abs(dy) <= tol {
        correct += 1
    } else {
        misplaced += 1
        print("• MISPLACED    \(short)")
        print("                now=(\(Int(live.bounds.minX)),\(Int(live.bounds.minY)) \(Int(live.bounds.width))x\(Int(live.bounds.height)))  Δ=(\(Int(dx)),\(Int(dy)))  “\(live.title.prefix(40))”")
    }
}

print("\n── Summary ──")
print("correct (within \(Int(tol))px): \(correct)")
print("misplaced:                 \(misplaced)")
print("gone (window # not live):  \(missingWID)")
print("no windowID in save:       \(noWID)")
print("total saved:               \(savedWindows.count)")
