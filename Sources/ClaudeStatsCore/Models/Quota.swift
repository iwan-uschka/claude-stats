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

    /// A window is live until its reset has passed, and one with no
    /// `resets_at` at all can't be shown to have expired. Every quota reader
    /// drops a window that isn't — its percentage describes a window that no
    /// longer exists — so the rule lives here, where they can't drift apart.
    public func isLive(asOf now: Date) -> Bool {
        resetsAt.map { $0 >= now } ?? true
    }
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
    ///
    /// Deliberately terse — no "window" suffix. The label column is shared
    /// with rows labelled from the payload (`Sonnet weekly`, `Usage credits`),
    /// and every point the two fixed labels give up goes to the bars, which
    /// are the thing the row is actually read for.
    public var title: String {
        switch self {
        case .fiveHour: return "5-hour"
        case .sevenDay: return "7-day"
        }
    }

    /// The same window spelled out, for tooltips and accessibility text.
    ///
    /// Nothing is competing for width there, and "5-hour" on its own reads as
    /// a fragment when it is announced rather than seen in a column.
    public var spokenTitle: String { "\(title) window" }
}

/// How trustworthy a ``QuotaSnapshot`` is.
///
/// Both cases carry Anthropic's own numbers — neither is an estimate. They
/// differ only in how directly the reading reached us, which is a freshness
/// distinction, not an accuracy one.
public enum QuotaConfidence: String, Sendable, Codable {
    /// Fresh capture from Claude Code's `statusLine` hook: the payload as it
    /// was handed to a status line render, seconds old.
    case official = "official"

    /// Claude Code's own cached copy of the same numbers, read out of its
    /// private state file (`cachedUsageUtilization` in `~/.claude.json`).
    ///
    /// Coarser than ``official`` — Claude Code refreshes that blob on its own
    /// schedule (observed 15 minutes old mid-session), so a reading can be
    /// several minutes behind reality even while the file itself is rewritten
    /// constantly for unrelated keys.
    case cachedOfficial = "official (cached)"

    /// Full label, shown in Settings where there is room to spell it out.
    public var displayLabel: String { rawValue }

    /// What the popover's source tag shows: nothing for a statusline capture
    /// (both sources carry Anthropic's own numbers, so "official"
    /// distinguished nothing), `cached` for the backup — the one fact worth a
    /// word, because that reading can be an hour behind.
    public var tagLabel: String? {
        switch self {
        case .official: nil
        case .cachedOfficial: "cached"
        }
    }
}

/// One scoped weekly sub-limit, as reported by a `weekly_scoped` entry in
/// `cachedUsageUtilization.utilization.limits[]`.
///
/// Entirely generic: the row is labelled from whatever
/// `scope.model.display_name` says, so a model Claude Code starts reporting
/// tomorrow needs no code change here.
///
/// ## What ``percentUsed`` is a share of is unknown
///
/// The payload gives a bare `percent` with no denominator, and every entry
/// observed so far read 0. Nothing in this app — row label, tooltip, glyph —
/// may claim the number is a share of a model-specific sub-cap *or* of the
/// account's weekly total: neither has been verified. It is reported as
/// Claude Code's own number, nothing more.
public struct QuotaScopedLimit: Sendable, Hashable, Codable, Identifiable {
    /// Display name of the scope, from `scope.model.display_name` (falling back
    /// to `scope.surface`) — e.g. `"Fable"`.
    public let label: String
    /// Percentage as reported, 0...100. See the type note: the denominator is
    /// undocumented.
    public let percentUsed: Double
    /// When the scoped window rolls over, when the payload says so — routinely
    /// `null` for an inactive entry.
    public let resetsAt: Date?
    /// The payload's `is_active`; stored, not yet used for styling.
    public let isActive: Bool
    /// The payload's `severity` (`"normal"`, `"critical"`, …); stored for
    /// fidelity, not yet styled.
    public let severity: String?

    public init(
        label: String,
        percentUsed: Double,
        resetsAt: Date? = nil,
        isActive: Bool = false,
        severity: String? = nil
    ) {
        self.label = label
        self.percentUsed = percentUsed
        self.resetsAt = resetsAt
        self.isActive = isActive
        self.severity = severity
    }

    /// The label is the identity: one row per scope. The payload itself can
    /// repeat one (two surfaces reporting the same model name, say) —
    /// `QuotaJSON.scopedLimits(in:)` is what actually enforces uniqueness,
    /// by dropping duplicates before this type ever sees them.
    public var id: String { label }

    /// Adapter for the bar UI, which is written against ``QuotaWindow``.
    public var window: QuotaWindow {
        QuotaWindow(percentUsed: percentUsed, resetsAt: resetsAt)
    }
}

/// A point-in-time reading of both rate-limit windows.
///
/// Either window can be `nil`, and that is a reading in its own right: **no
/// source made a claim about that window**. Claude Code drops a window from its
/// payloads entirely once the window's `resets_at` has passed, so between a
/// rollover and the next API call nothing on disk says anything about it.
/// Mapping that absence to a zeroed window would ship a confident 0% — the
/// defect ``StatuslineCacheReader`` was split per session to fix — so the
/// absence is carried all the way to the UI, which renders it as no reading
/// (`—` / "no reading" in the popover, an empty menu bar bar whose VoiceOver
/// text says "unknown") rather than as 0%.
public struct QuotaSnapshot: Sendable, Hashable, Codable {
    /// The 5-hour window, or `nil` when no source currently reports one.
    public var fiveHour: QuotaWindow?
    /// The 7-day window, or `nil` when no source currently reports one.
    public var sevenDay: QuotaWindow?
    public var confidence: QuotaConfidence
    public var capturedAt: Date
    /// Per-model weekly sub-limits, highest percentage first. Empty for any
    /// source that doesn't report them (the statusline payload carries no
    /// `limits[]`), which is why it defaults — every existing call site builds a
    /// snapshot without one.
    public var scopedWeekly: [QuotaScopedLimit]
    /// Organisation usage credits, when the source reports them at all.
    ///
    /// `nil` is the normal state, not a failure — see ``UsageCredits``. Only
    /// ``CachedUtilizationReader``'s payload carries them; the statusline hook's
    /// has no `spend` object, so a snapshot from that source always leaves this
    /// `nil` (``FreshestQuotaProvider`` grafts the other source's reading on,
    /// same as it does for ``scopedWeekly``).
    public var usageCredits: UsageCredits?
    /// Why there are no ``usageCredits``, when the payload said so
    /// (`disabled_reason`). Decoration for a tooltip; never an error, and
    /// meaningless while ``usageCredits`` is non-`nil`.
    public var usageCreditsDisabledReason: String?
    /// Which Anthropic account this reading describes, when anything on disk
    /// said so.
    ///
    /// `nil` means **unknown account**, not "the only account": a cache file
    /// written before the helper script learned to stamp one, or a state file
    /// with no `oauthAccount`. An unknown reading is never merged with a known
    /// one — see ``QuotaAccount`` and ``StatuslineCacheReader``.
    public var account: QuotaAccount?

    public init(
        fiveHour: QuotaWindow?,
        sevenDay: QuotaWindow?,
        confidence: QuotaConfidence,
        capturedAt: Date,
        scopedWeekly: [QuotaScopedLimit] = [],
        usageCredits: UsageCredits? = nil,
        usageCreditsDisabledReason: String? = nil,
        account: QuotaAccount? = nil
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.confidence = confidence
        self.capturedAt = capturedAt
        self.scopedWeekly = scopedWeekly
        self.usageCredits = usageCredits
        self.usageCreditsDisabledReason = usageCreditsDisabledReason
        self.account = account
    }

    /// Applies one source's usage-credits reading, credits and reason together.
    ///
    /// The two fields are one answer — assigning the credits without the reason
    /// (or vice versa) leaves the snapshot claiming a reason for credits it
    /// has — so ``FreshestQuotaProvider``'s graft goes through here rather than
    /// touching either property directly.
    public mutating func apply(_ reading: UsageCreditsReading) {
        usageCredits = reading.credits
        usageCreditsDisabledReason = reading.disabledReason
    }

    /// Hand-written so a payload encoded before ``scopedWeekly``,
    /// ``usageCredits`` or ``account`` existed still decodes: Swift's synthesized
    /// `init(from:)` ignores property defaults and would fail on the missing
    /// keys. The two windows are decoded the same forgiving way — a missing
    /// window key decodes as `nil`, which is exactly what it means.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try container.decodeIfPresent(QuotaWindow.self, forKey: .fiveHour)
        sevenDay = try container.decodeIfPresent(QuotaWindow.self, forKey: .sevenDay)
        confidence = try container.decode(QuotaConfidence.self, forKey: .confidence)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        scopedWeekly = try container.decodeIfPresent([QuotaScopedLimit].self, forKey: .scopedWeekly) ?? []
        usageCredits = try container.decodeIfPresent(UsageCredits.self, forKey: .usageCredits)
        usageCreditsDisabledReason = try container.decodeIfPresent(
            String.self, forKey: .usageCreditsDisabledReason
        )
        account = try container.decodeIfPresent(QuotaAccount.self, forKey: .account)
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
