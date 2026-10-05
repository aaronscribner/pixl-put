import Foundation

/// Fresh-boot detection and the boot-storm settle rule for restore-after-restart.
///
/// After a reboot macOS relaunches every app over several minutes (measured
/// 2026-09-10: load average above 300 for the first ten minutes, apps still
/// creating windows three minutes after login). A restore that runs once at
/// launch acts on whatever happens to exist at that instant. Two pure rules
/// keep this testable: whether this launch counts as "just booted", and
/// whether the window population has stopped changing.
public enum BootDetection {

    /// Uptime below this at launch means the app was started by login items
    /// after a reboot rather than relaunched by the user mid-session.
    public static let freshBootThreshold: TimeInterval = 15 * 60

    public static func isFreshBoot(uptime: TimeInterval,
                                   threshold: TimeInterval = freshBootThreshold) -> Bool {
        uptime >= 0 && uptime < threshold
    }

    /// When this boot began (`kern.boottime`), or `nil` if the kernel won't
    /// say. Unlike `ProcessInfo.systemUptime`, it does not drift across sleep.
    ///
    /// Window IDs are only unique within one boot: the window server numbers
    /// from scratch after a restart, and apps relaunching in the same order
    /// get the same low numbers back. A saved window ID from an earlier boot
    /// can therefore name a different window of the same app now, so it is
    /// only trusted for entries captured after this time.
    public static let currentBootTime: Date? = {
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctl(&mib, 2, &bootTime, &size, nil, 0) == 0, bootTime.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(bootTime.tv_sec)
                    + TimeInterval(bootTime.tv_usec) / 1_000_000)
    }()

    /// Whether a window ID recorded at `capturedAt` can still name the same
    /// window. `bootTime == nil` (unknown) trusts it, as before this rule.
    public static func windowIDIsCurrent(capturedAt: Date, bootTime: Date?) -> Bool {
        guard let bootTime else { return true }
        return capturedAt >= bootTime
    }
}

/// Tracks a sequence of window-count samples and reports when the count has
/// held steady for a required number of consecutive samples.
public struct SettleTracker: Sendable, Equatable {
    /// Consecutive equal samples required to call the population settled.
    public let requiredStableSamples: Int
    private var samples: [Int] = []

    public init(requiredStableSamples: Int) {
        precondition(requiredStableSamples >= 1)
        self.requiredStableSamples = requiredStableSamples
    }

    public mutating func record(_ count: Int) {
        samples.append(count)
    }

    public var latest: Int? { samples.last }

    /// True once the last `requiredStableSamples` samples are all equal.
    public var isSettled: Bool {
        guard samples.count >= requiredStableSamples else { return false }
        let tail = samples.suffix(requiredStableSamples)
        return Set(tail).count == 1
    }
}
