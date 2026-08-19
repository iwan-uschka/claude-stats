import Foundation

/// Pure formatting helpers shared by the menu bar glyph and the popover.
///
/// These live in Core rather than the app target on purpose: the app target is
/// an executable, which SwiftPM can't link into a test target, so any logic that
/// deserves unit tests has to sit here.
public enum DisplayFormat {
    // MARK: - Durations

    /// Coarse "time left" string for a reset countdown: `4d 6h`, `2h 14m`,
    /// `43m`, `12s`. Only ever shows the two largest units, and drops the
    /// smaller one when it rounds to zero (`4d`, `2h`).
    ///
    /// The smallest displayed unit is rounded to nearest rather than truncated:
    /// a window resetting in 2h 13m 59s reads `2h 14m`, not `2h 13m`. Rounding
    /// can carry into the next unit, so the bracket is chosen *after* rounding
    /// (3,599s → `1h`, never `60m`).
    ///
    /// Non-positive intervals collapse to `0s` — callers that want a different
    /// "already reset" wording should check for that case themselves (or use
    /// ``resetCountdown(_:)``).
    public static func duration(_ interval: TimeInterval) -> String {
        guard interval > 0, interval.isFinite else { return "0s" }

        let total: Int
        if interval >= 86_400 {
            // Days are the leading unit, so hours are the smallest shown.
            total = Int((interval / 3_600).rounded()) * 3_600
        } else if interval >= 60 {
            total = Int((interval / 60).rounded()) * 60
        } else {
            // Sub-minute: seconds are exact, so truncate instead of rounding up
            // to a minute the user hasn't reached yet.
            total = Int(interval.rounded(.down))
        }

        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60

        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if minutes > 0 {
            return "\(minutes)m"
        }
        return "\(seconds)s"
    }

    /// Countdown phrase for a quota window: `resets in 2h 14m`, or
    /// `reset pending` once the deadline has passed / is unknown.
    public static func resetCountdown(_ interval: TimeInterval?) -> String {
        guard let interval, interval > 0 else { return "reset pending" }
        return "resets in \(duration(interval))"
    }

    /// Freshness suffix for the confidence tag: `40s ago`, `5m ago`, `2h ago`,
    /// `3d ago`, or `just now` for anything under a second (including clock
    /// skew that makes the age negative).
    public static func age(_ interval: TimeInterval) -> String {
        guard interval >= 1, interval.isFinite else { return "just now" }

        let total = Int(interval.rounded(.down))
        if total < 60 { return "\(total)s ago" }
        if total < 3_600 { return "\(total / 60)m ago" }
        if total < 86_400 { return "\(total / 3_600)h ago" }
        return "\(total / 86_400)d ago"
    }

    /// The popover's confidence/freshness line: `source: official · 40s ago`.
    public static func sourceTag(confidence: QuotaConfidence, age: TimeInterval) -> String {
        "source: \(confidence.displayLabel) · \(self.age(age))"
    }

    // MARK: - Plan

    /// Value half of the popover's plan line: `Max20 (auto-detected)` for a
    /// known tier, `Custom (~220k tok/5h)` when the tier was estimated from
    /// local history, `detecting…` before detection has produced anything.
    public static func planDescription(_ tier: PlanTier?) -> String {
        guard let tier else { return "detecting…" }
        if tier.isKnownTier {
            return "\(tier.displayName) (auto-detected)"
        }
        return "\(tier.displayName) (~\(tokens(tier.fiveHourTokenBudget)) tok/5h)"
    }

    // MARK: - Numbers

    /// Compact token count: `2.1M`, `640k`, `12.4k`, `840`. One decimal place,
    /// with a trailing `.0` trimmed so round numbers stay short.
    public static func tokens(_ count: Int) -> String {
        let magnitude = abs(count)
        let sign = count < 0 ? "-" : ""

        if magnitude >= 1_000_000 {
            return sign + scaled(Double(magnitude) / 1_000_000) + "M"
        }
        if magnitude >= 1_000 {
            return sign + scaled(Double(magnitude) / 1_000) + "k"
        }
        return "\(count)"
    }

    /// Tokens-per-hour burn rate, e.g. `12.4k tok/hr`.
    public static func burnRate(_ tokensPerHour: Double) -> String {
        "\(tokens(Int(tokensPerHour.rounded()))) tok/hr"
    }

    // MARK: - Token splits

    /// The four-way breakdown behind a token total, for a tooltip:
    /// `in 9.9k · out 4.7M · cache write 36.3M · cache read 453M`.
    public static func tokenSplit(_ usage: TokenUsage) -> String {
        "in \(tokens(usage.inputTokens))"
            + " · out \(tokens(usage.outputTokens))"
            + " · cache write \(tokens(usage.cacheCreationInputTokens))"
            + " · cache read \(tokens(usage.cacheReadInputTokens))"
    }

    /// Share of the total that cache reads have to exceed before a raw token
    /// total is misleading enough to caption. Half is the point where the
    /// headline number says more about replayed context than about new work.
    public static let cacheReadNoteThreshold = 0.5

    /// One-line footnote for a token total that cache reads dominate:
    /// `453M of 496M is cache reads — billed at 1/10 the input rate`. `nil`
    /// when cache reads are at or below ``cacheReadNoteThreshold`` of the
    /// total, where the raw number needs no qualifying.
    public static func cacheReadNote(_ usage: TokenUsage) -> String? {
        let total = usage.totalTokens
        guard total > 0 else { return nil }
        let share = Double(usage.cacheReadInputTokens) / Double(total)
        guard share > cacheReadNoteThreshold else { return nil }
        return "\(tokens(usage.cacheReadInputTokens)) of \(tokens(total)) is cache reads"
            + " — billed at \(cacheReadRateDescription) the input rate"
    }

    /// Derived from ``ModelPricing/cacheReadMultiplier`` so the caption can't
    /// drift from the pricing the cost column actually uses.
    private static var cacheReadRateDescription: String {
        "1/\(Int((1 / ModelPricing.cacheReadMultiplier).rounded()))"
    }

    /// USD with two decimals: `$4.82`.
    public static func cost(_ usd: Double) -> String {
        String(format: "$%.2f", usd)
    }

    /// Whole-percent label for a 0...1 fraction: `62%`.
    public static func percent(fraction: Double) -> String {
        "\(Int((clamped01(fraction) * 100).rounded()))%"
    }

    /// Whole-percent label for an already-percent value, clamped to 0...100.
    public static func percent(percentValue: Double) -> String {
        percent(fraction: percentValue / 100)
    }

    private static func scaled(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return "\(Int(rounded))"
        }
        return String(format: "%.1f", rounded)
    }

    // MARK: - Bar geometry

    /// Clamps any value (including `nan`/`inf`) into 0...1 so it is safe to
    /// multiply a bar length by.
    public static func clamped01(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    /// Fraction of `total` that `value` represents, clamped to 0...1.
    /// A zero or negative `total` yields 0 rather than a division blow-up.
    public static func barFraction(value: Int, total: Int) -> Double {
        guard total > 0, value > 0 else { return 0 }
        return clamped01(Double(value) / Double(total))
    }

    /// Fraction of the largest row, for comparable per-row bars in a breakdown
    /// table. Returns 0 for every row when all rows are zero.
    public static func barFraction(value: Int, peak: Int) -> Double {
        barFraction(value: value, total: peak)
    }
}
