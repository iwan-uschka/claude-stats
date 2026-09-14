import Foundation

/// One cell of the daily history: what one source spent on one model during one
/// local calendar day.
///
/// Keyed by the raw `modelID` rather than by ``ModelFamily`` on purpose. These
/// are filled by ``SessionCorpusIndex``'s retention fold, which runs long before
/// anything knows which families the popover will draw, and a model ID this
/// version doesn't recognise still has to count towards the day's total.
/// ``DailyUsageHistory`` maps IDs to families at query time, where an unknown
/// one becomes the `nil` family rather than disappearing.
public struct DailyUsageCell: Sendable, Hashable {
    /// Local midnight of the day the event fell in, per the calendar of
    /// whichever store or index built the cell.
    public var day: Date

    /// Raw `message.model`, `nil` when the line carried none.
    public var modelID: String?

    /// Mapped `entrypoint`, `nil` when absent or unrecognised.
    public var entrypoint: Entrypoint?

    public init(day: Date, modelID: String?, entrypoint: Entrypoint?) {
        self.day = day
        self.modelID = modelID
        self.entrypoint = entrypoint
    }
}

/// Tokens and estimated cost summed over some set of events.
///
/// ``HistoricalModelUsage`` carries the same two sums plus a `latestTimestamp`
/// it needs for `modelUsage`'s "newest raw ID wins per family" rule. A daily
/// cell has no such tie to break — the day *is* the ordering — so it gets the
/// smaller type rather than an extra field nothing reads.
public struct DailyUsageTotals: Sendable, Hashable {
    public var usage: TokenUsage
    public var estimatedCostUSD: Double

    public init(usage: TokenUsage = .zero, estimatedCostUSD: Double = 0) {
        self.usage = usage
        self.estimatedCostUSD = estimatedCostUSD
    }

    /// Add one event's tokens and cost.
    ///
    /// Callers are expected to have skipped events with empty usage — see
    /// ``DailyUsageTotals/countsTowardsDailyHistory(_:)``.
    public mutating func add(_ event: UsageEvent) {
        usage = usage + event.usage
        estimatedCostUSD += event.estimatedCostUSD
    }

    /// Combine two totals for the same cell or the same day.
    public mutating func merge(_ other: DailyUsageTotals) {
        usage = usage + other.usage
        estimatedCostUSD += other.estimatedCostUSD
    }

    /// Whether an event should open a daily cell at all.
    ///
    /// Claude Code's `<synthetic>` assistant messages carry an all-zero `usage`.
    /// Counting them would be harmless arithmetic but not harmless for the
    /// chart's x-axis: the window starts at the oldest day that has a cell, so a
    /// day whose only lines were synthetic would stretch the axis back over a
    /// stretch of nothing.
    public static func countsTowardsDailyHistory(_ event: UsageEvent) -> Bool {
        !event.usage.isEmpty
    }
}

/// Maps timestamps to local day boundaries, reusing the last answer while
/// consecutive timestamps stay inside the same day.
///
/// `Calendar.startOfDay(for:)` costs about 2.4 µs — nothing once, but the
/// retention fold asks per event, and a cold parse of a large corpus folds
/// hundreds of thousands of them. Measured 2026-09-14 on this machine: 200k
/// direct calls took 0.47 s, the same run through this resolver 0.019 s.
///
/// Events arrive in parse order, which is chronological in practice, so the
/// miss rate is about one per day of history. A miss is only slower to detect,
/// never wrong: the guard compares against the real day bounds, so an
/// out-of-order straggler recomputes rather than being filed under its
/// neighbour's day.
struct LocalDayResolver {
    private let calendar: Calendar
    private var start = Date.distantPast
    private var end = Date.distantPast

    init(calendar: Calendar) {
        self.calendar = calendar
    }

    /// Local midnight of the day `timestamp` falls in.
    mutating func day(for timestamp: Date) -> Date {
        if timestamp < start || timestamp >= end {
            start = calendar.startOfDay(for: timestamp)
            // A day that can't be advanced (never, for a real calendar) leaves
            // `end == start`, so every later call simply misses and recomputes.
            end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        }
        return start
    }
}

/// One day of one charted series.
///
/// Series are dense: a day inside the window with no usage is a zero point, not
/// a missing one. A line chart asked to skip it would draw a straight segment
/// from the day before to the day after and claim usage that never happened.
public struct DailyUsagePoint: Sendable, Hashable, Identifiable {
    public let day: Date
    public let usage: TokenUsage
    public let estimatedCostUSD: Double

    public init(day: Date, usage: TokenUsage = .zero, estimatedCostUSD: Double = 0) {
        self.day = day
        self.usage = usage
        self.estimatedCostUSD = estimatedCostUSD
    }

    public var id: Date { day }

    /// Every token the day's requests touched — the number the popover's
    /// tables put in their `Tokens` column.
    public var totalTokens: Int { usage.totalTokens }
}

/// Daily token history over a bounded window, split the two ways the popover
/// charts it.
public struct DailyUsageHistory: Sendable, Hashable {
    /// Local midnights, oldest first, one per day with no gaps.
    ///
    /// Shorter than the requested window when the corpus is younger than it: a
    /// Mac with nine days of logs charts nine days, rather than three weeks of
    /// zeroes that would read as "you stopped working". Empty when there is no
    /// usage in the window at all, which is the caller's cue to draw an empty
    /// state instead of a chart.
    public let days: [Date]

    /// Every event in the window, whatever its source or model.
    public let total: [DailyUsagePoint]

    /// Per source, dense over ``Entrypoint/allCases`` — a source that did
    /// nothing in the window is present with all-zero points, because "VS Code:
    /// 0" is a reading the popover shows rather than a row it drops.
    ///
    /// Plus the `nil` key when events this version doesn't recognise the
    /// `entrypoint` of contributed, exactly as ``byModelFamily`` handles an
    /// unrecognised model ID — present only when it has something in it, so an
    /// "Other" band never appears over nothing. Nothing is dropped, so these
    /// series *do* sum to ``total``.
    public let bySource: [Entrypoint?: [DailyUsagePoint]]

    /// Per model family, carrying only families that appear in the window, plus
    /// the `nil` key when unrecognised model IDs contributed.
    ///
    /// Like ``bySource`` nothing is dropped here, so these series sum to
    /// ``total`` and a stacked chart of them is honest.
    public let byModelFamily: [ModelFamily?: [DailyUsagePoint]]

    public init(
        days: [Date],
        total: [DailyUsagePoint],
        bySource: [Entrypoint?: [DailyUsagePoint]],
        byModelFamily: [ModelFamily?: [DailyUsagePoint]]
    ) {
        self.days = days
        self.total = total
        self.bySource = bySource
        self.byModelFamily = byModelFamily
    }

    public var isEmpty: Bool { days.isEmpty }

    public static let empty = DailyUsageHistory(days: [], total: [], bySource: [:], byModelFamily: [:])
}

public extension Sequence where Element == DailyUsagePoint {
    /// Tokens and estimated cost over the whole series — what a table under a
    /// 30-day chart reads out for one band.
    ///
    /// ``DailyUsageTotals`` rather than a new pair type: it already *is*
    /// "tokens plus estimated cost", it is what the cells these points are
    /// built from carry, and a second value with the same two fields would only
    /// need converting at the boundary between them.
    func summed() -> DailyUsageTotals {
        reduce(into: DailyUsageTotals()) { total, point in
            total.merge(DailyUsageTotals(usage: point.usage, estimatedCostUSD: point.estimatedCostUSD))
        }
    }
}
