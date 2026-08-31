import Foundation

/// A money amount exactly as the spend payload states it: an integer in minor
/// units plus the currency and how many of its digits are fractional.
///
/// Kept in minor units rather than a `Double` of major units on purpose — the
/// payload is integral (`amount_minor: 3300`), and dividing by a hardcoded 100
/// would be wrong for a zero-decimal currency (JPY reports `exponent: 0`, where
/// `3300` means ¥3,300, not ¥33). Formatting reads ``exponent`` and
/// ``currency`` — see ``DisplayFormat/money(_:locale:)``; nothing in this app
/// may hardcode a symbol or a divisor.
public struct MoneyAmount: Sendable, Hashable, Codable {
    /// The amount in minor units — cents for a 2-decimal currency.
    public let amountMinor: Int
    /// ISO 4217 code, e.g. `"EUR"`. Uppercased at parse time.
    public let currency: String
    /// Number of fractional digits: `2` means ``amountMinor`` is cents, `0`
    /// means it is whole units.
    public let exponent: Int

    public init(amountMinor: Int, currency: String, exponent: Int = 2) {
        self.amountMinor = amountMinor
        self.currency = currency
        self.exponent = exponent
    }

    /// The amount in major units, exact (``Decimal``, not `Double` — this is
    /// money, and a binary float can't represent 33.00 exactly).
    public var decimalValue: Decimal {
        Decimal(amountMinor) / pow(Decimal(10), max(exponent, 0))
    }
}

/// Organisation "usage credits": the extra, money-metered spend Claude Code
/// reports alongside the rate-limit windows, from
/// `cachedUsageUtilization.utilization.spend` (cross-checked against the
/// sibling `extra_usage` object).
///
/// ## Transient by design
///
/// Unlike the two account-wide windows, this can appear and disappear at any
/// time — the whole `spend` object turned up in the payload between 2026-08-27
/// and 2026-08-28, and an admin toggling credits off makes it meaningless again
/// from one poll to the next. **Absence is the normal state, never an error**:
/// every unmet condition in the parser yields `nil` (see
/// ``QuotaJSON/usageCredits(in:)``), and the popover simply has no credits row.
///
/// ## The limit is monthly
///
/// `extra_usage.monthly_limit` is the same number as `spend.limit`, which is
/// where the monthly framing in the row's tooltip comes from. There is no
/// `resets_at` for it, hence ``window``'s `nil` — the countdown column stays
/// empty rather than showing a made-up rollover.
public struct UsageCredits: Sendable, Hashable, Codable {
    /// Spent so far this month.
    public let used: MoneyAmount
    /// The monthly cap. Same currency as ``used`` — the parser refuses the
    /// reading outright when they disagree.
    public let limit: MoneyAmount
    /// The payload's own `spend.percent`, 0...100. Not recomputed from
    /// ``used``/``limit``: Claude Code's number is what the CLI shows.
    public let percentUsed: Double
    /// The payload's `severity` (`"normal"`, `"critical"`, …); stored for
    /// fidelity, not yet styled — same treatment as
    /// ``QuotaScopedLimit/severity``.
    public let severity: String?
    /// `extra_usage.spend_limit_reached` — the cap is hit and extra usage is
    /// paused until the next month.
    public let limitReached: Bool

    public init(
        used: MoneyAmount,
        limit: MoneyAmount,
        percentUsed: Double,
        severity: String? = nil,
        limitReached: Bool = false
    ) {
        self.used = used
        self.limit = limit
        self.percentUsed = percentUsed
        self.severity = severity
        self.limitReached = limitReached
    }

    /// Adapter for the bar UI, which is written against ``QuotaWindow``.
    /// `resetsAt` is always `nil`: the payload reports no rollover timestamp for
    /// the monthly spend cap.
    public var window: QuotaWindow {
        QuotaWindow(percentUsed: percentUsed, resetsAt: nil)
    }
}

/// One source's answer about usage credits: the credits themselves when they
/// are on, or — when they are not — whatever reason the payload gave.
///
/// A pair rather than a bare `UsageCredits?` so the reason survives the trip to
/// the UI. `extra_usage.disabled_reason` is the only thing the payload ever says
/// about *why* there is no credits row, and it is worth a tooltip; it is never
/// an error, because "no credits" is the normal state.
public struct UsageCreditsReading: Sendable, Hashable, Codable {
    public let credits: UsageCredits?
    /// `spend.disabled_reason` / `extra_usage.disabled_reason`, when set.
    /// Only meaningful while ``credits`` is `nil`.
    public let disabledReason: String?

    public init(credits: UsageCredits?, disabledReason: String? = nil) {
        self.credits = credits
        self.disabledReason = disabledReason
    }

    /// No credits, and the payload didn't say why.
    public static let unavailable = UsageCreditsReading(credits: nil, disabledReason: nil)
}
