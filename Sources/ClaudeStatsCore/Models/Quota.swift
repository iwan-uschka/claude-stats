import Foundation

/// One rate-limit window (5-hour or 7-day) as reported by a quota source.
public struct QuotaWindow: Sendable, Hashable, Codable {
    /// Percentage of the window consumed, 0...100. Values outside that range are
    /// preserved as reported — use ``fractionUsed`` for a clamped 0...1 value
    /// suitable for driving the bar UI.
    public var percentUsed: Double

    /// When the window rolls over, if the source reported it.
    public var resetsAt: Date?

    public init(percentUsed: Double, resetsAt: Date? = nil) {
        self.percentUsed = percentUsed
        self.resetsAt = resetsAt
    }

    /// `percentUsed` clamped into 0...1 for bar rendering.
    public var fractionUsed: Double {
        min(max(percentUsed / 100, 0), 1)
    }

    /// Seconds until reset, or `nil` when unknown / already elapsed.
    public func timeUntilReset(from now: Date = Date()) -> TimeInterval? {
        guard let resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        return remaining > 0 ? remaining : nil
    }

    /// Zeroed window, for placeholders and "no data yet" states.
    public static let empty = QuotaWindow(percentUsed: 0, resetsAt: nil)
}

/// How trustworthy a ``QuotaSnapshot`` is. Only one source is wired up
/// (Claude Code's `statusLine` hook), so this currently has a single case.
public enum QuotaConfidence: String, Sendable, Codable {
    /// Fresh capture from Claude Code's `statusLine` hook.
    case official = "official"

    /// Label shown in the popover's freshness tag.
    public var displayLabel: String { rawValue }
}

/// A point-in-time reading of both rate-limit windows.
public struct QuotaSnapshot: Sendable, Hashable, Codable {
    public var fiveHour: QuotaWindow
    public var sevenDay: QuotaWindow
    public var confidence: QuotaConfidence
    public var capturedAt: Date

    public init(
        fiveHour: QuotaWindow,
        sevenDay: QuotaWindow,
        confidence: QuotaConfidence,
        capturedAt: Date
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.confidence = confidence
        self.capturedAt = capturedAt
    }

    /// Default staleness threshold for a cached statusline capture (~10 min).
    public static let defaultStalenessThreshold: TimeInterval = 10 * 60

    /// Age of the snapshot in seconds.
    public func age(asOf now: Date = Date()) -> TimeInterval {
        now.timeIntervalSince(capturedAt)
    }

    public func isStale(
        asOf now: Date = Date(),
        threshold: TimeInterval = QuotaSnapshot.defaultStalenessThreshold
    ) -> Bool {
        age(asOf: now) > threshold
    }

    /// Placeholder snapshot: both windows empty, for "no data yet" states.
    public static func placeholder(capturedAt: Date = Date()) -> QuotaSnapshot {
        QuotaSnapshot(
            fiveHour: .empty,
            sevenDay: .empty,
            confidence: .official,
            capturedAt: capturedAt
        )
    }
}
