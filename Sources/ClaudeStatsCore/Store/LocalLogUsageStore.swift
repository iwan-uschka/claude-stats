import Foundation

/// Real ``UsageStoring`` backed by Claude Code's session JSONL on this Mac
/// (tier 1 of the data layer). Replaces ``MockUsageStore`` in production; the
/// mock stays for previews and for tests of other layers.
///
/// I/O happens once, in the initialiser: the store keeps the parsed events in
/// memory so every protocol method is pure arithmetic and safe to call from the
/// popover's render path. The FSEvents watcher refreshes by building a new
/// store (or by calling ``adding(events:)`` for an incremental update).
public struct LocalLogUsageStore: UsageStoring {
    /// Every token-bearing event known to this store, sorted oldest-first.
    public let events: [UsageEvent]

    /// Non-fatal problems from the last scan — one entry per malformed or
    /// truncated JSONL line. Surfaced for diagnostics; never thrown, because a
    /// half-written final line is the normal state of an active session.
    public let skippedLines: [ClaudeStatsError]

    /// Clock, injected so windows and "today" are testable. Defaults to `Date()`.
    public let nowProvider: @Sendable () -> Date

    /// Calendar used for ``estimatedCostToday()``'s local-midnight boundary.
    /// Injected so tests don't depend on the machine's time zone.
    public let calendar: Calendar

    // MARK: - Init

    /// Build from already-parsed events (used by tests and by incremental refresh).
    public init(
        events: [UsageEvent],
        skippedLines: [ClaudeStatsError] = [],
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        // `adding(events:)` merges two individually-sorted sequences; skip the
        // O(n log n) resort of the whole accumulated history when the
        // concatenation is already in order, which is the common case for an
        // incremental refresh.
        let alreadySorted = zip(events, events.dropFirst()).allSatisfy { $0.timestamp <= $1.timestamp }
        self.events = alreadySorted ? events : events.sorted { $0.timestamp < $1.timestamp }
        self.skippedLines = skippedLines
        self.calendar = calendar
        self.nowProvider = now
    }

    /// Scan `<configDirectory>/projects/**/*.jsonl` and index the result.
    ///
    /// - Throws: ``ClaudeStatsError/configDirectoryNotFound`` when
    ///   `configDirectory` isn't an existing directory.
    public init(
        configDirectory: URL,
        parser: SessionLogParser = SessionLogParser(),
        fileManager: FileManager = .default,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: configDirectory.path, isDirectory: &isDir),
              isDir.boolValue
        else { throw ClaudeStatsError.configDirectoryNotFound }

        let result = parser.parseAllSessions(inConfigDirectory: configDirectory)
        self.init(
            events: result.events,
            skippedLines: result.skippedLines,
            calendar: calendar,
            now: now
        )
    }

    /// Scan the config directory resolved by ``ClaudeConfigDirectory``
    /// (`$CLAUDE_CONFIG_DIR`, else `~/.claude`).
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        parser: SessionLogParser = SessionLogParser(),
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        let directory = try ClaudeConfigDirectory.resolve(environment: environment)
        try self.init(
            configDirectory: directory,
            parser: parser,
            calendar: calendar,
            now: now
        )
    }

    /// Copy of this store with extra events folded in — the incremental-refresh
    /// path for when the watcher reports a single changed session file.
    public func adding(events newEvents: [UsageEvent], skippedLines newSkipped: [ClaudeStatsError] = []) -> LocalLogUsageStore {
        LocalLogUsageStore(
            events: events + newEvents,
            skippedLines: skippedLines + newSkipped,
            calendar: calendar,
            now: nowProvider
        )
    }

    // MARK: - UsageStoring

    /// Tokens per known ``Entrypoint`` inside `window`, ending at "now".
    ///
    /// Events whose `entrypoint` this version doesn't recognise are omitted —
    /// the breakdown's rows are a fixed, known set — but they still count in
    /// ``modelUsage(last24h:)``, ``burnRatePerHour()`` and
    /// ``estimatedCostToday()``, so no spend goes missing from the totals.
    public func entrypointBreakdown(for window: TimeWindow) throws -> EntrypointBreakdown {
        let now = nowProvider()
        var totals: [Entrypoint: Int] = [:]
        for event in events(in: window.startDate(endingAt: now), to: now) {
            guard let entrypoint = event.entrypoint else { continue }
            totals[entrypoint, default: 0] += event.usage.totalTokens
        }
        return EntrypointBreakdown(window: window, tokensByEntrypoint: totals)
    }

    /// Tokens and estimated cost grouped by ``ModelFamily``.
    ///
    /// Rows come back in ``ModelFamily/displayOrder``, followed by any
    /// unrecognised model IDs (grouped by raw ID, `family == nil`, cost `0`)
    /// sorted by ID. A family's `modelID` is the most recent raw ID seen for it,
    /// so the row reflects the version actually in use.
    public func modelUsage(last24h: Bool) throws -> [ModelUsage] {
        let now = nowProvider()
        let scoped: ArraySlice<UsageEvent> = last24h
            ? events(in: TimeWindow.twentyFourHour.startDate(endingAt: now), to: now)
            : events[...]

        var byFamily: [ModelFamily: (modelID: String, usage: TokenUsage, cost: Double)] = [:]
        var byUnknownID: [String: (usage: TokenUsage, cost: Double)] = [:]

        for event in scoped {
            let usage = event.usage
            guard !usage.isEmpty else { continue }  // `<synthetic>` lines report all-zero usage
            let cost = event.estimatedCostUSD
            if let family = event.modelFamily {
                let existing = byFamily[family]
                byFamily[family] = (
                    // `scoped` is oldest-first, so the last write wins → newest ID.
                    modelID: event.modelID ?? existing?.modelID ?? family.rawValue,
                    usage: (existing?.usage ?? .zero) + usage,
                    cost: (existing?.cost ?? 0) + cost
                )
            } else {
                let key = event.modelID ?? "unknown"
                let existing = byUnknownID[key]
                byUnknownID[key] = (
                    usage: (existing?.usage ?? .zero) + usage,
                    cost: (existing?.cost ?? 0) + cost
                )
            }
        }

        var rows: [ModelUsage] = ModelFamily.displayOrder.compactMap { family in
            guard let entry = byFamily[family] else { return nil }
            return ModelUsage(
                modelID: entry.modelID,
                family: family,
                tokens: entry.usage.totalTokens,
                estimatedCostUSD: entry.cost
            )
        }
        rows += byUnknownID.keys.sorted().map { id in
            let entry = byUnknownID[id]!
            return ModelUsage(
                modelID: id,
                family: nil,
                tokens: entry.usage.totalTokens,
                estimatedCostUSD: entry.cost
            )
        }
        return rows
    }

    /// Tokens consumed in the trailing hour. The window is exactly one hour, so
    /// this is a token count and a per-hour rate at the same time.
    public func burnRatePerHour() throws -> Double {
        let now = nowProvider()
        let tokens = events(in: now.addingTimeInterval(-3600), to: now)
            .reduce(0) { $0 + $1.usage.totalTokens }
        return Double(tokens)
    }

    /// Estimated spend since local midnight, per ``calendar``. Events on models
    /// with no pricing entry contribute `0`.
    public func estimatedCostToday() throws -> Double {
        let now = nowProvider()
        let midnight = calendar.startOfDay(for: now)
        return events(in: midnight, to: now).reduce(0) { $0 + $1.estimatedCostUSD }
    }

    /// Plan tier inferred from local history: the 90th percentile of
    /// quota-weighted tokens per 5-hour window over the last 8 days, snapped to
    /// the nearest published threshold by
    /// ``PlanTier/nearestKnownTier(forFiveHourTokens:tolerance:)``.
    ///
    /// Windows are 5-hour buckets anchored at "now" and walked backwards; empty
    /// buckets are excluded so idle days don't drag the percentile down.
    /// Tokens are quota-weighted (``TokenUsage/quotaWeightedTokens``) because the
    /// published thresholds are far below raw cached-token volumes. With no
    /// history at all the result is `.custom(tokens: 0)`.
    public func detectedPlanTier() throws -> PlanTier {
        let p90 = fiveHourWindowP90()
        return PlanTier.nearestKnownTier(forFiveHourTokens: p90)
    }

    // MARK: - Derived values

    /// Number of days of local history the plan-tier heuristic looks at.
    public static let planDetectionHistoryDays = 8

    /// The percentile used by the plan-tier heuristic.
    public static let planDetectionPercentile = 0.9

    /// 90th percentile of quota-weighted tokens per 5-hour window over the last
    /// 8 days, exposed so the UI can show the raw estimate next to the snapped tier.
    public func fiveHourWindowP90() -> Int {
        let now = nowProvider()
        let bucketLength = TimeWindow.fiveHour.duration
        let historyLength = Double(LocalLogUsageStore.planDetectionHistoryDays) * 86_400
        let start = now.addingTimeInterval(-historyLength)

        var buckets: [Int: Int] = [:]
        for event in events(in: start, to: now) {
            let index = Int(now.timeIntervalSince(event.timestamp) / bucketLength)
            buckets[index, default: 0] += event.usage.quotaWeightedTokens
        }

        // Bucket 0 (the most recent) only ever collects a fraction of a real
        // 5-hour window unless "now" lands exactly on a boundary, which would
        // skew the percentile downward right after a burst of recent usage.
        // Excluded whenever other history exists to fall back on; kept when
        // it's the only data available (e.g. right after a fresh install).
        var totals = buckets.filter { $0.key != 0 }.values.filter { $0 > 0 }.sorted()
        if totals.isEmpty {
            totals = buckets.values.filter { $0 > 0 }.sorted()
        }
        guard !totals.isEmpty else { return 0 }
        // Nearest-rank percentile: smallest value with at least 90% of samples at or below it.
        let rank = Int((LocalLogUsageStore.planDetectionPercentile * Double(totals.count)).rounded(.up))
        return totals[min(max(rank - 1, 0), totals.count - 1)]
    }

    /// Events with `start <= timestamp <= end`. `events` is sorted, so this is a
    /// contiguous slice.
    public func events(in start: Date, to end: Date) -> ArraySlice<UsageEvent> {
        guard start <= end else { return [] }
        let lower = events.partitioningIndex { $0.timestamp >= start }
        let upper = events.partitioningIndex { $0.timestamp > end }
        return events[lower..<upper]
    }
}

private extension Array {
    /// First index where `belongsInSecondPartition` becomes true, assuming the
    /// array is already partitioned by it (binary search).
    func partitioningIndex(where belongsInSecondPartition: (Element) -> Bool) -> Int {
        var low = startIndex
        var high = endIndex
        while low < high {
            let mid = low + (high - low) / 2
            if belongsInSecondPartition(self[mid]) {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low
    }
}
