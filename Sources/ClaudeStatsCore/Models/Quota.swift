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

/// Which of the two rate-limit windows something refers to.
///
/// Introduced for the promo notices, which name the bar they belong under —
/// but ``title`` is the single source of the row labels the popover has always
/// shown, so a notice and its bar can never disagree about what the row is
/// called.
public enum QuotaWindowKind: String, Sendable, Hashable, Codable, CaseIterable {
    case fiveHour = "five_hour"
    case sevenDay = "seven_day"

    /// Parses the `bar` field of a `tengu_rate_limit_promo_notices` entry.
    ///
    /// Accepts both the snake_case spelling seen on disk and the camelCase one
    /// used elsewhere in the same payloads. Anything else returns `nil`, which
    /// **drops the notice entirely** rather than guessing: "+50% weekly limits"
    /// is only true of one of the two bars, so an unrecognised `bar` has no
    /// safe place to render.
    public init?(promoBarValue: String) {
        switch promoBarValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "five_hour", "fivehour": self = .fiveHour
        case "seven_day", "sevenday": self = .sevenDay
        default: return nil
        }
    }

    /// The popover's row label for this window.
    public var title: String {
        switch self {
        case .fiveHour: return "5-hour window"
        case .sevenDay: return "7-day window"
        }
    }
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
}
