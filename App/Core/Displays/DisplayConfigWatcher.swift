import Foundation
import CoreGraphics

/// Watches the macOS display configuration. Emits `.didChange` whenever
/// the connected display set changes (lid open/close, monitor attach/detach,
/// resolution change, primary display change).
///
/// Wraps `CGDisplayRegisterReconfigurationCallback`. Registers on `start()`
/// and unregisters on `stop()` / deinit. Thread-safe; events are forwarded
/// on the supplied queue (defaults to main, so SwiftUI / AppKit observers
/// can update without dispatch shenanigans).
public final class DisplayConfigWatcher: @unchecked Sendable {

    public typealias Listener = @Sendable () -> Void

    private let lock = NSLock()
    private var listeners: [UUID: Listener] = [:]
    private var registered = false
    private let deliverQueue: DispatchQueue

    public init(deliverOn: DispatchQueue = .main) {
        self.deliverQueue = deliverOn
    }

    deinit {
        _ = stopInternal()
    }

    /// Begin watching. Idempotent.
    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard !registered else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = CGDisplayRegisterReconfigurationCallback(Self.callback, context)
        guard status == .success else { return }
        registered = true
    }

    /// Stop watching. Idempotent.
    @discardableResult
    public func stop() -> Bool {
        stopInternal()
    }

    private func stopInternal() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard registered else { return false }
        let context = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(Self.callback, context)
        registered = false
        return true
    }

    /// Subscribe to configuration changes. Returns a token; call
    /// `unsubscribe(_:)` to remove the listener.
    @discardableResult
    public func subscribe(_ listener: @escaping Listener) -> UUID {
        lock.lock(); defer { lock.unlock() }
        let id = UUID()
        listeners[id] = listener
        return id
    }

    public func unsubscribe(_ token: UUID) {
        lock.lock(); defer { lock.unlock() }
        listeners.removeValue(forKey: token)
    }

    private static let callback: CGDisplayReconfigurationCallBack = { _, flags, context in
        guard let context = context else { return }
        // macOS invokes this twice per change: BEFORE with
        // `beginConfigurationFlag`, and AFTER with whatever change flags
        // apply. The canonical filter is "skip the begin call, act on
        // everything else". An earlier revision instead required specific
        // change flags (add/remove/setMode/…), which silently dropped
        // after-callbacks carrying NO flags — exactly what a
        // mode-preserving DisplayPort link renegotiation (Odyssey G9
        // backlight sleep/wake) delivers. Downstream debouncing absorbs
        // the extra per-display callbacks this now lets through.
        guard !flags.contains(.beginConfigurationFlag) else { return }

        let watcher = Unmanaged<DisplayConfigWatcher>.fromOpaque(context).takeUnretainedValue()
        watcher.lock.lock()
        let snapshot = Array(watcher.listeners.values)
        let q = watcher.deliverQueue
        watcher.lock.unlock()
        q.async {
            for listener in snapshot { listener() }
        }
    }
}

/// Current-display enumeration. Walks every online display and returns the
/// fingerprints + bounds tuple needed for `displayConfigurationID`
/// computation and `SnapshotEngine` capture.
public struct DisplayEnumerator: Sendable {

    public init() {}

    public func enumerate() -> [DisplaySnapshot] {
        var displayCount: UInt32 = 0
        var status = CGGetOnlineDisplayList(0, nil, &displayCount)
        guard status == .success, displayCount > 0 else { return [] }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        status = CGGetOnlineDisplayList(displayCount, &displays, &displayCount)
        guard status == .success else { return [] }

        let mainID = CGMainDisplayID()
        var snapshots: [DisplaySnapshot] = []
        for id in displays {
            let bounds = CGDisplayBounds(id)
            let vendor = CGDisplayVendorNumber(id)
            let product = CGDisplayModelNumber(id)
            // CoreGraphics doesn't expose a separate "model number" distinct
            // from "product number" — both `CGDisplayModelNumber` calls
            // return identical bits. We reuse the same value here rather
            // than calling twice; the redundancy was a leftover from the
            // data-model design phase. Uniqueness comes from
            // vendor+product+serial+(optional UUID).
            let model = product
            let serial = CGDisplaySerialNumber(id)
            // CGDisplayCreateUUIDFromDisplayID is deprecated and not reliably
            // exposed via the public CoreGraphics import on modern SDKs.
            // For two physically-identical displays with the same EDID and
            // no serial reported by the panel, their per-display fingerprints
            // collide and PixlPut cannot tell them apart at restore time.
            // This is a known limitation — Story 4 acceptance #1 (config ID)
            // still works; per-window display-affinity in that case
            // degrades to ordinal-of-display.
            let uuid: String? = nil
            let scale: Double
            if let mode = CGDisplayCopyDisplayMode(id) {
                let pixelW = Double(mode.pixelWidth)
                let pointW = Double(mode.width)
                scale = pointW > 0 ? pixelW / pointW : 1.0
            } else {
                scale = 1.0
            }
            let fp = DisplayFingerprint(
                vendorID: vendor,
                productID: product,
                modelNumber: model,
                serialNumber: serial,
                displayUUID: uuid
            )
            snapshots.append(DisplaySnapshot(
                fingerprint: fp,
                bounds: CGRectCodable(bounds),
                isPrimary: id == mainID,
                scaleFactor: scale
            ))
        }
        return snapshots
    }

    /// Compute the configuration ID for the current display set.
    public func configurationID() -> String {
        let displays = enumerate()
        return DisplayConfigurationID.compute(from: displays.map(\.fingerprint))
    }
}
