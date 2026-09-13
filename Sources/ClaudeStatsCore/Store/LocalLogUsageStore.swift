import Foundation

/// Per-model lifetime totals for events that have aged out of the store's
/// per-event retention window (see ``SessionCorpusIndex``).
///
/// ``LocalLogUsageStore/modelUsage(last24h:)`` with `last24h == false` needs
/// data older than the longest rolling window, and needs only these sums — so
/// old events are folded down to this instead of being kept whole. The same
/// fold also writes ``DailyUsageCell`` totals for the charts, which need the
/// same events split by day; neither structure reads the other.
public struct HistoricalModelUsage: Sendable, Hashable {
    /// Summed token counts of every folded event for this model ID.
    public var usage: TokenUsage

    /// Summed ``UsageEvent/estimatedCostUSD`` of the folded events.
    public var estimatedCostUSD: Double

    /// Timestamp of the newest folded event — lets `modelUsage` keep its
    /// "newest raw ID wins per family" rule across the fold boundary.
    public var latestTimestamp: Date

    public init(usage: TokenUsage = .zero, estimatedCostUSD: Double = 0, latestTimestamp: Date = .distantPast) {
        self.usage = usage
        self.estimatedCostUSD = estimatedCostUSD
        self.latestTimestamp = latestTimestamp
    }

    /// Fold one event into the totals.
    public mutating func fold(_ event: UsageEvent) {
        usage = usage + event.usage
        estimatedCostUSD += event.estimatedCostUSD
        latestTimestamp = max(latestTimestamp, event.timestamp)
    }

    /// Combine two totals for the same model ID.
    public mutating func merge(_ other: HistoricalModelUsage) {
        usage = usage + other.usage
        estimatedCostUSD += other.estimatedCostUSD
        latestTimestamp = max(latestTimestamp, other.latestTimestamp)
    }
}

/// Real ``UsageStoring`` backed by Claude Code's session JSONL on this Mac
/// (tier 1 of the data layer). Replaces ``MockUsageStore`` in production; the
/// mock stays for previews and for tests of other layers.
///
/// I/O happens once, in the initialiser: the store keeps the parsed events in
/// memory so every protocol method is pure arithmetic and safe to call from the
/// popover's render path. The FSEvents watcher refreshes by building a new
/// store via ``SessionCorpusIndex/rebuild()``; ``adding(events:)`` is a
/// standalone merge helper that does *not* maintain the index's retention
/// window, so it must not be used on an index-built store.
public struct LocalLogUsageStore: UsageStoring {
    /// Every token-bearing event known to this store, sorted oldest-first.
    ///
    /// When the store is built by ``SessionCorpusIndex`` this only spans the
    /// retention window; older history lives in ``historicalByModel`` and
    /// ``historicalDailyCells``.
    public let events: [UsageEvent]

    /// Per-model totals for events older than the retention window, keyed by
    /// raw model ID (`nil` for events that carried none). Empty when the store
    /// was built from a full parse. Consulted only by
    /// ``modelUsage(last24h:)`` with `last24h == false` — every rolling-window
    /// query is answerable from ``events`` alone, and the charts' longer reach
    /// back is served by ``historicalDailyCells`` instead.
    public let historicalByModel: [String?: HistoricalModelUsage]

    /// Daily token/cost cells for events older than the retention window, the
    /// history half of ``dailyUsage(days:)``. Empty when the store was built
    /// from a full parse, where every event is still in ``events``.
    ///
    /// Deliberately a second accumulation next to ``historicalByModel`` rather
    /// than a replacement for it: that one keeps a `latestTimestamp` per model
    /// for `modelUsage`'s "newest raw ID wins" rule, which summing daily cells
    /// could only approximate to the day. Both are filled in the same fold, so
    /// neither costs an extra pass.
    public let historicalDailyCells: [DailyUsageCell: DailyUsageTotals]

    /// Non-fatal problems from the last scan. When the store is built by
    /// ``SessionCorpusIndex`` this is a *sample* (at most
    /// ``SessionCorpusIndex/skippedSampleLimit`` per file), not a complete
    /// list — the exact total lives on
    /// ``SessionCorpusIndex/skippedLineCount``. A full parse carries one entry
    /// per malformed or truncated JSONL line. Never thrown, because a
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
        historicalByModel: [String?: HistoricalModelUsage] = [:],
        historicalDailyCells: [DailyUsageCell: DailyUsageTotals] = [:],
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.historicalByModel = historicalByModel
        self.historicalDailyCells = historicalDailyCells
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
            historicalByModel: historicalByModel,
            historicalDailyCells: historicalDailyCells,
            calendar: calendar,
            now: nowProvider
        )
    }

    // MARK: - UsageStoring

    /// Tokens per known ``Entrypoint`` inside `window`, ending at "now".
    ///
    /// Events whose `entrypoint` this version doesn't recognise are omitted —
    /// the breakdown's rows are a fixed, known set — but they still count in
    /// ``modelUsage(last24h:)`` and ``estimatedCostToday()``, so no spend goes
    /// missing from the totals.
    public func entrypointBreakdown(for window: TimeWindow) throws -> EntrypointBreakdown {
        let now = nowProvider()
        var totals: [Entrypoint: TokenUsage] = [:]
        for event in events(in: window.startDate(endingAt: now), to: now) {
            guard let entrypoint = event.entrypoint else { continue }
            totals[entrypoint] = totals[entrypoint, default: .zero] + event.usage
        }
        return EntrypointBreakdown(window: window, usageByEntrypoint: totals)
    }

    /// Sums every window in one walk of the widest one instead of one walk per
    /// window: `events(in:to:)` binary-searches to the widest window's start,
    /// then each event is folded into every narrower window it also falls in.
    /// ``TimeWindow``'s three cases are nested suffixes of "now", so this
    /// covers all of them without re-scanning from the start for each.
    public func entrypointBreakdowns(for windows: [TimeWindow]) throws -> [TimeWindow: EntrypointBreakdown] {
        guard let widest = windows.max(by: { $0.duration < $1.duration }) else { return [:] }
        let now = nowProvider()
        var totals: [TimeWindow: [Entrypoint: TokenUsage]] = [:]
        for event in events(in: widest.startDate(endingAt: now), to: now) {
            guard let entrypoint = event.entrypoint else { continue }
            for window in windows where event.timestamp >= window.startDate(endingAt: now) {
                let running = totals[window, default: [:]][entrypoint] ?? .zero
                totals[window, default: [:]][entrypoint] = running + event.usage
            }
        }
        return Dictionary(uniqueKeysWithValues: windows.map {
            ($0, EntrypointBreakdown(window: $0, usageByEntrypoint: totals[$0] ?? [:]))
        })
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

        func accumulate(modelID: String?, usage: TokenUsage, cost: Double) {
            guard !usage.isEmpty else { return }  // `<synthetic>` lines report all-zero usage
            if let family = modelID.flatMap(ModelFamily.inferred(fromModelID:)) {
                let existing = byFamily[family]
                byFamily[family] = (
                    // Accumulation order is oldest-first, so the last write wins → newest ID.
                    modelID: modelID ?? existing?.modelID ?? family.rawValue,
                    usage: (existing?.usage ?? .zero) + usage,
                    cost: (existing?.cost ?? 0) + cost
                )
            } else {
                let key = modelID ?? "unknown"
                let existing = byUnknownID[key]
                byUnknownID[key] = (
                    usage: (existing?.usage ?? .zero) + usage,
                    cost: (existing?.cost ?? 0) + cost
                )
            }
        }

        if !last24h {
            // Folded history predates every retained event, so feeding it first
            // (oldest fold first) keeps the "newest ID wins" ordering intact.
            for (modelID, total) in historicalByModel.sorted(by: {
                ($0.value.latestTimestamp, $0.key ?? "") < ($1.value.latestTimestamp, $1.key ?? "")
            }) {
                accumulate(modelID: modelID, usage: total.usage, cost: total.estimatedCostUSD)
            }
        }
        for event in scoped {
            accumulate(modelID: event.modelID, usage: event.usage, cost: event.estimatedCostUSD)
        }

        var rows: [ModelUsage] = ModelFamily.displayOrder.compactMap { family in
            guard let entry = byFamily[family] else { return nil }
            return ModelUsage(
                modelID: entry.modelID,
                family: family,
                usage: entry.usage,
                estimatedCostUSD: entry.cost
            )
        }
        rows += byUnknownID.keys.sorted().map { id in
            let entry = byUnknownID[id]!
            return ModelUsage(
                modelID: id,
                family: nil,
                usage: entry.usage,
                estimatedCostUSD: entry.cost
            )
        }
        return rows
    }

    /// Estimated spend since local midnight, per ``calendar``. Events on models
    /// with no pricing entry contribute `0`.
    public func estimatedCostToday() throws -> Double {
        let now = nowProvider()
        let midnight = calendar.startOfDay(for: now)
        return events(in: midnight, to: now).reduce(0) { $0 + $1.estimatedCostUSD }
    }

    /// Daily token and cost history for the last `days` local days, ending with
    /// today.
    ///
    /// Answered from two halves that never overlap, exactly as
    /// ``modelUsage(last24h:)`` answers all-time usage: events still inside the
    /// retention window come from ``events``, everything older from the
    /// ``historicalDailyCells`` the fold left behind. A full-parse store has an
    /// empty second half and reads entirely from the first.
    ///
    /// Days are walked with ``calendar`` rather than by adding 86 400 seconds,
    /// so the day after a DST transition is still one day long.
    public func dailyUsage(days: Int) throws -> DailyUsageHistory {
        guard days > 0 else { return .empty }
        let now = nowProvider()
        let today = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(byAdding: .day, value: -(days - 1), to: today) else {
            return .empty
        }

        var cells: [DailyUsageCell: DailyUsageTotals] = [:]
        for (cell, totals) in historicalDailyCells where cell.day >= windowStart {
            cells[cell, default: DailyUsageTotals()].merge(totals)
        }
        var days = LocalDayResolver(calendar: calendar)
        for event in events(in: windowStart, to: now) where DailyUsageTotals.countsTowardsDailyHistory(event) {
            let cell = DailyUsageCell(
                day: days.day(for: event.timestamp),
                modelID: event.modelID,
                entrypoint: event.entrypoint
            )
            cells[cell, default: DailyUsageTotals()].add(event)
        }

        // The axis starts at the oldest day that actually has usage, not at the
        // requested window start — see ``DailyUsageHistory/days``.
        guard let firstDay = cells.keys.map(\.day).min() else { return .empty }
        var axis: [Date] = []
        var cursor = firstDay
        while cursor <= today {
            axis.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        var totalByDay: [Date: DailyUsageTotals] = [:]
        var sourceByDay: [Entrypoint: [Date: DailyUsageTotals]] = [:]
        var familyByDay: [ModelFamily?: [Date: DailyUsageTotals]] = [:]
        for (cell, totals) in cells {
            totalByDay[cell.day, default: DailyUsageTotals()].merge(totals)
            if let entrypoint = cell.entrypoint {
                sourceByDay[entrypoint, default: [:]][cell.day, default: DailyUsageTotals()].merge(totals)
            }
            let family = cell.modelID.flatMap(ModelFamily.inferred(fromModelID:))
            familyByDay[family, default: [:]][cell.day, default: DailyUsageTotals()].merge(totals)
        }

        func series(_ byDay: [Date: DailyUsageTotals]) -> [DailyUsagePoint] {
            axis.map { day in
                let totals = byDay[day] ?? DailyUsageTotals()
                return DailyUsagePoint(day: day, usage: totals.usage, estimatedCostUSD: totals.estimatedCostUSD)
            }
        }

        return DailyUsageHistory(
            days: axis,
            total: series(totalByDay),
            // Dense over every known source, including ones that did nothing.
            bySource: Dictionary(uniqueKeysWithValues: Entrypoint.allCases.map { ($0, series(sourceByDay[$0] ?? [:])) }),
            byModelFamily: familyByDay.mapValues(series)
        )
    }

    // MARK: - Derived values

    /// How many days of local history the store is expected to be able to
    /// answer per-event questions about. Sets the floor for
    /// ``SessionCorpusIndex/defaultRetention``, so a query reaching further
    /// back than this has to raise it first.
    public static let localHistoryDays = 8

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
