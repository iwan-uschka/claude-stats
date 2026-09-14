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

    /// Countdown for a quota window: `2h 14m`, or `reset pending` once the
    /// deadline has passed / is unknown. Bare duration, no "resets in" — the
    /// column sits to the right of a bar labelled `5-hour`/`7-day`, so the time
    /// alone reads as the time until it resets.
    public static func resetCountdown(_ interval: TimeInterval?) -> String {
        guard let interval, interval > 0 else { return "reset pending" }
        return duration(interval)
    }

    /// The quota title row's source tag: `nil` for a statusline capture,
    /// `cached` for Claude Code's own cached copy. No age and no "stale"
    /// suffix — the reading's freshness is not shown; an over-threshold
    /// reading surfaces as the terracotta staleness warning line instead. Every
    /// reading is Anthropic's own number, so "official" said nothing and is
    /// left out; only the coarser backup source is named — see
    /// ``QuotaConfidence/tagLabel``.
    public static func sourceTag(confidence: QuotaConfidence) -> String? {
        confidence.tagLabel
    }

    // MARK: - Numbers

    /// Compact token count: `2.1G`, `2.1M`, `640k`, `840`. One decimal place,
    /// with a trailing `.0` trimmed so round numbers stay short.
    ///
    /// `G` and `T`, not `B` and `Tn`: the ladder starts at `k` and `M`, which
    /// are SI prefixes, so the next two are giga and tera. It carries as far as
    /// tera because a ladder that stops rolls over instead — 2 billion tokens
    /// read `2000M` until `G` was added, and a cache-read-heavy corpus reaches
    /// billions in a way it never reaches trillions.
    public static func tokens(_ count: Int) -> String {
        let magnitude = abs(count)
        let sign = count < 0 ? "-" : ""

        if magnitude >= 1_000_000_000_000 {
            return sign + scaled(Double(magnitude) / 1_000_000_000_000) + "T"
        }
        if magnitude >= 1_000_000_000 {
            return sign + scaled(Double(magnitude) / 1_000_000_000) + "G"
        }
        if magnitude >= 1_000_000 {
            return sign + scaled(Double(magnitude) / 1_000_000) + "M"
        }
        if magnitude >= 1_000 {
            return sign + scaled(Double(magnitude) / 1_000) + "k"
        }
        return "\(count)"
    }

    // MARK: - Axis labels

    /// One SI unit for a whole axis, decided by its largest value.
    ///
    /// ``tokens(_:)`` scales every number on its own, which is right for a row
    /// — `640k` beside `2.1G` are two different readings. On an axis it is
    /// wrong: `1.5G / 1G / 500M / 0` makes the reader convert `500M` into
    /// `0.5G` to see that the steps are even. One unit for the column, and the
    /// steps read themselves: `1.5G / 1.0G / 0.5G / 0`.
    ///
    /// Zero is left unlabelled. Both charts start their scale there, so the
    /// bottom line is zero by construction and the label only spends width —
    /// in the narrowest column the popover has — restating where the axis
    /// obviously begins.
    public static func tokenAxisLabels(_ values: [Int]) -> [String] {
        let units: [(scale: Double, symbol: String)] = [
            (1_000_000_000_000, "T"), (1_000_000_000, "G"), (1_000_000, "M"), (1_000, "k"), (1, "")
        ]
        return axisLabels(values.map(Double.init), units: units, prefix: "")
    }

    /// The same rule for spend: one unit across the axis, and a decimal count
    /// the whole column shares.
    ///
    /// In bare dollars money keeps two decimals or none — `$2.50`, never
    /// `$2.5`, and `$0.50` rather than `$.5`. That floor is a dollars-only
    /// rule: in the `k` unit the column takes as few decimals as render every
    /// value exactly, capped at two, so round thousands read `$1k`/`$2k`
    /// rather than `$1.00k`. Zero is unlabelled here too.
    public static func costAxisLabels(_ values: [Double]) -> [String] {
        let units: [(scale: Double, symbol: String)] = [(1_000, "k"), (1, "")]
        return axisLabels(values, units: units, prefix: "$", wholeDollarDecimals: 2)
    }

    /// Labels for `values` in the unit the largest of them takes, each with the
    /// same number of decimals — as few as render every value exactly.
    ///
    /// - Parameter wholeDollarDecimals: decimals to use when the chosen unit is
    ///   the bare one and any value needs a fraction at all. Money wants two
    ///   there; token counts want as few as possible.
    private static func axisLabels(
        _ values: [Double],
        units: [(scale: Double, symbol: String)],
        prefix: String,
        wholeDollarDecimals: Int? = nil
    ) -> [String] {
        let magnitude = values.map(abs).max() ?? 0
        let unit = units.first { magnitude >= $0.scale } ?? (1, "")
        let scaled = values.map { $0 / unit.scale }

        // The fewest decimals that leave every value exact — a half-step axis
        // needs one, a quarter-step two, and round numbers none.
        func isExact(at decimals: Int) -> Bool {
            let factor = pow(10, Double(decimals))
            return scaled.allSatisfy { abs(($0 * factor).rounded() - $0 * factor) < 0.0001 }
        }
        var decimals = 0
        while decimals < 2, !isExact(at: decimals) { decimals += 1 }
        if decimals > 0, unit.symbol.isEmpty, let floor = wholeDollarDecimals {
            decimals = max(decimals, floor)
        }

        return zip(values, scaled).map { value, scaledValue in
            // Empty, not `0` — the caller draws no label for it at all, and an
            // empty string keeps the labels lined up with the values they came
            // from so a chart can index one by the other. Non-finite values
            // get the same empty label rather than a `"nan"`/`"inf"` string.
            guard value != 0, value.isFinite else { return "" }
            return prefix + String(format: "%.\(decimals)f", scaledValue) + unit.symbol
        }
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
    /// `91% cache reads — billed at 1/10 the input rate`. `nil` when cache
    /// reads are at or below ``cacheReadNoteThreshold`` of the total, where the
    /// raw number needs no qualifying.
    ///
    /// A share of the total rather than the two raw counts: the point of the
    /// line is how much of the headline number is replayed context, and one
    /// percentage says that without restating a number already on screen.
    /// Rounded to a whole percent — tenths would imply a precision the caption
    /// is not making a claim about — but never down onto the threshold itself,
    /// which is the one share this line is never shown for.
    public static func cacheReadNote(_ usage: TokenUsage) -> String? {
        let total = usage.totalTokens
        guard total > 0 else { return nil }
        let share = Double(usage.cacheReadInputTokens) / Double(total)
        guard share > cacheReadNoteThreshold else { return nil }
        // A share a hair over the threshold still rounds down to the threshold
        // itself (151/300 → `50%`), which reads as the one value the guard
        // rules out. Floor the printed percent just above it.
        let percent = max(Int((share * 100).rounded()), Int(cacheReadNoteThreshold * 100) + 1)
        return "\(percent)% cache reads"
            + " — billed at \(cacheReadRateDescription) the input rate"
    }

    /// Derived from ``ModelPricing/cacheReadMultiplier`` so the caption can't
    /// drift from the pricing the cost column actually uses.
    private static var cacheReadRateDescription: String {
        "1/\(Int((1 / ModelPricing.cacheReadMultiplier).rounded()))"
    }

    /// USD with two decimals: `$4.82`.
    ///
    /// Hardcoded on purpose, unlike ``money(_:locale:)``: this is a *local*
    /// estimate computed from Anthropic's published per-token USD prices, so
    /// there is no currency field to read — the number is dollars by
    /// construction.
    public static func cost(_ usd: Double) -> String {
        String(format: "$%.2f", usd)
    }

    /// USD sized for a chart axis label: `$0`, `$1.50`, `$48`, `$1.2k`.
    ///
    /// Not ``cost(_:)``. Axis ticks land on round numbers, and two forced
    /// decimals turns every one of them into `$50.00` — a third of the label
    /// spent on zeroes, on the one label the plot has to give up width for. The
    /// precision that is dropped is precision the axis was never making a claim
    /// about; the exact figure is the row under the chart.
    ///
    /// Decimals appear only below `$10`, where a tick of `$2` and a tick of
    /// `$2.50` are different readings of the same day.
    ///
    /// `nil` for anything a cost axis cannot mean — non-finite, or past a
    /// trillion dollars. Chart frameworks probe a formatter with values of
    /// their own choosing, and `%f` on `Double.greatestFiniteMagnitude` is a
    /// 300-digit label rather than a crash, which is worse: it renders.
    public static func compactCost(_ usd: Double) -> String? {
        guard usd.isFinite, abs(usd) < 1e12 else { return nil }
        let magnitude = abs(usd)
        let sign = usd < 0 ? "-" : ""
        if magnitude >= 1_000 {
            return "\(sign)$\(trimmingTrailingZeros(magnitude / 1_000, decimals: 1))k"
        }
        if magnitude >= 10 {
            return "\(sign)$\(Int(magnitude.rounded()))"
        }
        return "\(sign)$\(trimmingTrailingZeros(magnitude, decimals: 2))"
    }

    /// `1.50` → `1.5`, `2.00` → `2`. Keeps an axis from labelling a round tick
    /// with decimals it does not need.
    private static func trimmingTrailingZeros(_ value: Double, decimals: Int) -> String {
        var text = String(format: "%.\(decimals)f", value)
        guard text.contains(".") else { return text }
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    // MARK: - Money
    //
    // Everything here is driven by the payload's own `currency` and `exponent`.
    // No symbol and no `/100` may be hardcoded: the org's currency is whatever
    // Anthropic bills it in, and a zero-decimal currency (JPY reports
    // `exponent: 0`) would come out 100× too small.

    /// One money amount in the given locale's conventions: `€33.00`, `¥3,300`.
    ///
    /// The fraction digits come from ``MoneyAmount/exponent``, not from the
    /// locale's idea of the currency, so the string can never claim more
    /// precision than the payload reported.
    public static func money(_ amount: MoneyAmount, locale: Locale = .current) -> String {
        let digits = min(max(amount.exponent, 0), 6)
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        formatter.currencyCode = amount.currency
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        if let formatted = formatter.string(from: amount.decimalValue as NSDecimalNumber) {
            return formatted
        }
        // Unreachable for any currency code `NumberFormatter` accepts, which is
        // any three-letter string — but a formatter failure must still print the
        // number rather than dropping the row's only value.
        return "\(amount.currency) \(amount.decimalValue)"
    }

    /// The credits row's value column: `€0.00 of €33.00`.
    ///
    /// Deliberately money, not a percentage — the percentage is already the
    /// bar, and "0%" of an unstated budget says nothing about how much is left.
    public static func moneySpend(
        used: MoneyAmount,
        limit: MoneyAmount,
        locale: Locale = .current
    ) -> String {
        "\(money(used, locale: locale)) of \(money(limit, locale: locale))"
    }

    /// Percent label for a 0...1 fraction: `62%`.
    ///
    /// Whole numbers below 99%, where a percentage point either way doesn't
    /// change what the user should do. From 99% up, one decimal place
    /// (`99.4%`) — that band is where "almost done" and "done" diverge, and
    /// rounding to a whole number erases the difference.
    public static func percent(fraction: Double) -> String {
        let value = clamped01(fraction) * 100
        if value >= 99 && value < 100 {
            return "\(scaled(value))%"
        }
        return "\(Int(value.rounded()))%"
    }

    /// Percent label for an already-percent value, clamped to 0...100 — same
    /// formatting as ``percent(fraction:)`` (one decimal place from 99% up).
    public static func percent(percentValue: Double) -> String {
        percent(fraction: percentValue / 100)
    }

    /// Placeholder shown in the percent column of a window nothing reported.
    ///
    /// An em dash, not `0%`: a window absent from every payload has no reading,
    /// and a number there would be a claim no source made.
    public static let unknownWindowPercent = "—"

    /// Placeholder shown in the countdown column of a window nothing reported.
    ///
    /// Not "reset pending" — that says the window exists and its reset is due.
    /// This says we have no reading at all, which is the normal state between a
    /// rollover and the session's next API call.
    public static let unknownWindowCountdown = "no reading"

    /// Percent column for a possibly-absent quota window: the percentage, or
    /// ``unknownWindowPercent`` when no source reported the window.
    public static func windowPercent(_ window: QuotaWindow?) -> String {
        guard let window else { return unknownWindowPercent }
        return percent(percentValue: window.percentUsed)
    }

    /// Countdown column for a possibly-absent quota window.
    ///
    /// Three outcomes, in order: no window at all →
    /// ``unknownWindowCountdown``; a window whose reset is unknown or already
    /// past → `reset pending`, or the empty string when the caller says this
    /// row's missing `resets_at` means "not reported" rather than "pending"
    /// (see ``QuotaScopedLimit``); otherwise the countdown itself.
    public static func windowCountdown(
        _ window: QuotaWindow?,
        from now: Date,
        showsPendingResetPlaceholder: Bool = true
    ) -> String {
        guard let window else { return unknownWindowCountdown }
        let remaining = window.timeUntilReset(from: now)
        if remaining == nil && !showsPendingResetPlaceholder { return "" }
        return resetCountdown(remaining)
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

}
