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
