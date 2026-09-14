import XCTest
@testable import ClaudeStatsCore

/// Coverage for ``LocalLogUsageStore/dailyUsage(days:)`` — the daily history
/// behind the popover's 30-day charts.
///
/// Events are built by hand rather than parsed from fixtures: every assertion
/// here is about which *day* an event lands in, so the timestamps have to be
/// written where the test can see them. The clock is frozen and the calendar
/// injected, so nothing depends on the machine's time zone.
final class DailyUsageTests: XCTestCase {

    /// Midday, so a ±few-hour shift for a time-zone test stays inside the day.
    static let referenceNow = SessionLogParser.parseTimestamp("2026-07-15T12:00:00.000Z")!

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    // MARK: - Helpers

    private func date(_ iso: String) throws -> Date {
        try XCTUnwrap(SessionLogParser.parseTimestamp(iso), "unparseable timestamp \(iso)")
    }

    /// One event, with a token count that is easy to read back out of a sum.
    private func event(
        _ iso: String,
        tokens: Int,
        model: String? = "claude-sonnet-5",
        entrypoint: Entrypoint? = .cli
    ) throws -> UsageEvent {
        UsageEvent(
            timestamp: try date(iso),
            entrypoint: entrypoint,
            modelID: model,
            usage: TokenUsage(inputTokens: tokens)
        )
    }

    private func makeStore(
        events: [UsageEvent],
        historicalDailyCells: [DailyUsageCell: DailyUsageTotals] = [:],
        calendar: Calendar = DailyUsageTests.utcCalendar,
        now: Date = DailyUsageTests.referenceNow
    ) -> LocalLogUsageStore {
        LocalLogUsageStore(
            events: events,
            historicalDailyCells: historicalDailyCells,
            calendar: calendar,
            now: { now }
        )
    }

    /// Tokens per day of a series, in axis order — what a chart would plot.
    private func tokens(_ series: [DailyUsagePoint]?) -> [Int] {
        (series ?? []).map(\.totalTokens)
    }

    // MARK: - Bucketing

    func testBucketsEventsByLocalDay() throws {
        let store = makeStore(events: [
            try event("2026-07-13T01:00:00.000Z", tokens: 10),
            try event("2026-07-13T23:59:59.000Z", tokens: 5),
            try event("2026-07-14T00:00:00.000Z", tokens: 200),
            try event("2026-07-15T11:00:00.000Z", tokens: 3_000),
        ])

        let history = try store.dailyUsage(days: 30)

        XCTAssertEqual(history.days.count, 3)
        XCTAssertEqual(history.days.first, try date("2026-07-13T00:00:00.000Z"))
        XCTAssertEqual(history.days.last, try date("2026-07-15T00:00:00.000Z"))
        XCTAssertEqual(tokens(history.total), [15, 200, 3_000])
    }

    func testDayBoundaryFollowsTheInjectedCalendarsTimeZone() throws {
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))

        // 22:30 UTC on the 14th is 00:30 on the 15th in Berlin (UTC+2 in July),
        // so it belongs to the newest day, not the one before it.
        let store = makeStore(
            events: [
                try event("2026-07-14T12:00:00.000Z", tokens: 7),
                try event("2026-07-14T22:30:00.000Z", tokens: 11),
            ],
            calendar: berlin
        )

        let history = try store.dailyUsage(days: 30)
        XCTAssertEqual(history.days.count, 2)
        XCTAssertEqual(tokens(history.total), [7, 11])
    }

    func testIdleDaysInsideTheWindowAreZeroPointsNotGaps() throws {
        let store = makeStore(events: [
            try event("2026-07-12T09:00:00.000Z", tokens: 100),
            try event("2026-07-15T09:00:00.000Z", tokens: 400),
        ])

        let history = try store.dailyUsage(days: 30)

        // A line chart handed a 2-point series would draw straight across the
        // two idle days and claim usage that never happened.
        XCTAssertEqual(history.days.count, 4)
        XCTAssertEqual(tokens(history.total), [100, 0, 0, 400])
    }

    // MARK: - Window

    func testAxisStartsAtOldestDayWithUsageRatherThanPaddingTheWindow() throws {
        let store = makeStore(events: [
            try event("2026-07-14T09:00:00.000Z", tokens: 100),
            try event("2026-07-15T09:00:00.000Z", tokens: 100),
        ])

        // A Mac with two days of logs charts two days, not 28 leading zeroes.
        XCTAssertEqual(try store.dailyUsage(days: 30).days.count, 2)
    }

    func testDaysOlderThanTheWindowAreExcluded() throws {
        let store = makeStore(events: [
            try event("2026-07-10T09:00:00.000Z", tokens: 999),
            try event("2026-07-14T09:00:00.000Z", tokens: 100),
            try event("2026-07-15T09:00:00.000Z", tokens: 200),
        ])

        // `days: 3` is today plus the two days before it — the 10th is out.
        let history = try store.dailyUsage(days: 3)
        XCTAssertEqual(history.days.count, 2)
        XCTAssertEqual(tokens(history.total), [100, 200])
    }

    func testEmptyWindowAndEmptyCorpusYieldTheEmptyHistory() throws {
        let store = makeStore(events: [try event("2026-07-15T09:00:00.000Z", tokens: 100)])

        XCTAssertTrue(try store.dailyUsage(days: 0).isEmpty)
        XCTAssertTrue(try store.dailyUsage(days: -1).isEmpty)
        XCTAssertTrue(try makeStore(events: []).dailyUsage(days: 30).isEmpty)
    }

    // MARK: - Series

    func testSourceSeriesAreDenseOverEveryKnownEntrypoint() throws {
        let store = makeStore(events: [
            try event("2026-07-14T09:00:00.000Z", tokens: 100, entrypoint: .cli),
            try event("2026-07-15T09:00:00.000Z", tokens: 300, entrypoint: .sdkAgent),
        ])

        let history = try store.dailyUsage(days: 30)

        // VS Code did nothing, and still gets a series — the popover shows it
        // as a `0` row rather than dropping it.
        XCTAssertEqual(Set(history.bySource.keys), Set(Entrypoint.allCases))
        XCTAssertEqual(tokens(history.bySource[.cli]), [100, 0])
        XCTAssertEqual(tokens(history.bySource[.vscode]), [0, 0])
        XCTAssertEqual(tokens(history.bySource[.sdkAgent]), [0, 300])
        // No "Other" band over nothing: every event here carries an entrypoint
        // this version knows, so the bucket is absent rather than all-zero.
        XCTAssertNil(history.bySource[Entrypoint?.none])
    }

    func testUnrecognisedEntrypointsGetTheirOwnOtherSeries() throws {
        let store = makeStore(events: [
            try event("2026-07-14T09:00:00.000Z", tokens: 100, entrypoint: .cli),
            try event("2026-07-15T10:00:00.000Z", tokens: 900, entrypoint: nil),
        ])

        let history = try store.dailyUsage(days: 30)

        // The `nil` key is the same bucket `byModelFamily` gives an
        // unrecognised model ID: the tokens are real, only the label is
        // missing, and dropping them made a stacked chart of the sources fall
        // short of the total drawn beside it.
        XCTAssertEqual(tokens(history.bySource[Entrypoint?.none]), [0, 900])
        XCTAssertEqual(tokens(history.bySource[.cli]), [100, 0])
        XCTAssertEqual(Set(history.bySource.keys), Set(Entrypoint.allCases.map { $0 } + [nil]))
    }

    func testEverySourceSeriesTogetherSumsToTheTotalOnEveryDay() throws {
        let store = makeStore(events: [
            try event("2026-07-14T09:00:00.000Z", tokens: 100, entrypoint: .cli),
            try event("2026-07-14T10:00:00.000Z", tokens: 40, entrypoint: nil),
            try event("2026-07-15T09:00:00.000Z", tokens: 300, entrypoint: .sdkAgent),
            try event("2026-07-15T10:00:00.000Z", tokens: 900, entrypoint: nil),
        ])

        let history = try store.dailyUsage(days: 30)

        // The invariant the "Other" bucket exists for: the bands of the source
        // chart reach exactly the height the cost chart's day does, so a total
        // may be drawn over the stack.
        for (index, point) in history.total.enumerated() {
            XCTAssertEqual(
                history.bySource.values.reduce(0) { $0 + $1[index].totalTokens },
                point.totalTokens,
                "day \(point.day)"
            )
        }
    }

    func testModelSeriesCoverEveryTokenIncludingUnknownIDs() throws {
        let store = makeStore(events: [
            try event("2026-07-15T09:00:00.000Z", tokens: 100, model: "claude-sonnet-5"),
            try event("2026-07-15T10:00:00.000Z", tokens: 50, model: "claude-opus-5"),
            try event("2026-07-15T11:00:00.000Z", tokens: 7, model: "claude-mystery-9"),
            try event("2026-07-15T11:30:00.000Z", tokens: 3, model: nil),
        ])

        let history = try store.dailyUsage(days: 30)

        XCTAssertEqual(tokens(history.byModelFamily[.sonnet]), [100])
        XCTAssertEqual(tokens(history.byModelFamily[.opus]), [50])
        // Unrecognised IDs and missing ones share the `nil` family, so a
        // stacked chart of the families still sums to the total.
        XCTAssertEqual(tokens(history.byModelFamily[ModelFamily?.none]), [10])
        XCTAssertEqual(
            history.byModelFamily.values.reduce(0) { $0 + ($1.first?.totalTokens ?? 0) },
            history.total.first?.totalTokens
        )
    }

    func testSyntheticZeroUsageEventsDoNotOpenADay() throws {
        let store = makeStore(events: [
            UsageEvent(
                timestamp: try date("2026-07-01T09:00:00.000Z"),
                entrypoint: .cli,
                modelID: "<synthetic>",
                usage: .zero
            ),
            try event("2026-07-15T09:00:00.000Z", tokens: 100),
        ])

        // Without the guard the axis would stretch back to the 1st over two
        // weeks of nothing.
        let history = try store.dailyUsage(days: 30)
        XCTAssertEqual(history.days.count, 1)
        XCTAssertEqual(tokens(history.total), [100])
    }

    func testCostAccumulatesPerDay() throws {
        let store = makeStore(events: [
            UsageEvent(
                timestamp: try date("2026-07-14T09:00:00.000Z"),
                entrypoint: .cli,
                modelID: "claude-sonnet-5",
                usage: TokenUsage(inputTokens: 1_000_000)
            ),
            UsageEvent(
                timestamp: try date("2026-07-15T09:00:00.000Z"),
                entrypoint: .cli,
                modelID: "claude-sonnet-5",
                usage: TokenUsage(inputTokens: 2_000_000)
            ),
        ])

        let history = try store.dailyUsage(days: 30)
        let costs = history.total.map(\.estimatedCostUSD)
        XCTAssertEqual(costs.count, 2)
        XCTAssertGreaterThan(costs[0], 0)
        XCTAssertEqual(costs[1], costs[0] * 2, accuracy: 0.000_01)
    }

    func testTodaysPointMatchesEstimatedCostToday() throws {
        let store = makeStore(events: [
            UsageEvent(
                timestamp: try date("2026-07-14T09:00:00.000Z"),
                entrypoint: .cli,
                modelID: "claude-sonnet-5",
                usage: TokenUsage(inputTokens: 1_000_000)
            ),
            UsageEvent(
                timestamp: try date("2026-07-15T09:00:00.000Z"),
                entrypoint: .cli,
                modelID: "claude-opus-5",
                usage: TokenUsage(inputTokens: 2_000_000)
            ),
        ])

        // The popover draws the curve and the `Today` row under it from these
        // two calls. Both count from the same local midnight, and today is
        // always inside retention, so they cannot be allowed to disagree — a
        // chart ending below the number printed beneath it reads as a bug in
        // whichever the user trusts less.
        let history = try store.dailyUsage(days: 30)
        XCTAssertEqual(
            try XCTUnwrap(history.total.last).estimatedCostUSD,
            try store.estimatedCostToday(),
            accuracy: 0.000_001
        )
        XCTAssertGreaterThan(try store.estimatedCostToday(), 0)
    }

    // MARK: - Folded history

    func testFoldedCellsAndRetainedEventsCombineWithoutDoubleCounting() throws {
        let oldDay = try date("2026-07-05T00:00:00.000Z")
        let cell = DailyUsageCell(day: oldDay, modelID: "claude-opus-5", entrypoint: .sdkAgent)
        let store = makeStore(
            events: [try event("2026-07-15T09:00:00.000Z", tokens: 100)],
            historicalDailyCells: [
                cell: DailyUsageTotals(usage: TokenUsage(inputTokens: 42), estimatedCostUSD: 1.5)
            ]
        )

        let history = try store.dailyUsage(days: 30)

        XCTAssertEqual(history.days.first, oldDay)
        XCTAssertEqual(history.days.count, 11)  // 5th … 15th inclusive
        XCTAssertEqual(history.total.first?.totalTokens, 42)
        XCTAssertEqual(history.total.last?.totalTokens, 100)
        XCTAssertEqual(history.total.reduce(0) { $0 + $1.totalTokens }, 142)
        XCTAssertEqual(tokens(history.bySource[.sdkAgent]).first, 42)
        XCTAssertEqual(tokens(history.byModelFamily[.opus]).first, 42)
    }

    func testFoldedCellsOlderThanTheWindowAreDropped() throws {
        let cell = DailyUsageCell(
            day: try date("2026-06-01T00:00:00.000Z"),
            modelID: "claude-opus-5",
            entrypoint: .cli
        )
        let store = makeStore(
            events: [try event("2026-07-15T09:00:00.000Z", tokens: 100)],
            historicalDailyCells: [cell: DailyUsageTotals(usage: TokenUsage(inputTokens: 42))]
        )

        let history = try store.dailyUsage(days: 30)
        XCTAssertEqual(history.days.count, 1)
        XCTAssertEqual(tokens(history.total), [100])
    }

    func testEmptyHistoryCarriesNoDaysAndNoSeries() {
        let empty = DailyUsageHistory.empty

        // The value a caller gets for "nothing to chart" — the popover keys its
        // empty state off `isEmpty`, so the two must never disagree.
        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(empty.days.isEmpty)
        XCTAssertTrue(empty.total.isEmpty)
        XCTAssertTrue(empty.bySource.isEmpty)
        XCTAssertTrue(empty.byModelFamily.isEmpty)
    }

    func testOnlyEventsWithTokensCountTowardsDailyHistory() throws {
        let real = try event("2026-07-15T09:00:00.000Z", tokens: 1)
        let synthetic = UsageEvent(
            timestamp: try date("2026-07-15T09:00:00.000Z"),
            entrypoint: .cli,
            modelID: "<synthetic>",
            usage: .zero
        )

        XCTAssertTrue(DailyUsageTotals.countsTowardsDailyHistory(real))
        XCTAssertFalse(DailyUsageTotals.countsTowardsDailyHistory(synthetic))
    }

    // MARK: - Summing a series

    func testSummingASeriesAddsUpItsTokensAndItsCost() throws {
        let store = makeStore(events: [
            UsageEvent(
                timestamp: try date("2026-07-14T09:00:00.000Z"),
                entrypoint: .cli,
                modelID: "claude-sonnet-5",
                usage: TokenUsage(inputTokens: 1_000_000, outputTokens: 2_000)
            ),
            UsageEvent(
                timestamp: try date("2026-07-15T09:00:00.000Z"),
                entrypoint: .cli,
                modelID: "claude-sonnet-5",
                usage: TokenUsage(inputTokens: 500_000, cacheReadInputTokens: 7)
            ),
        ])
        let history = try store.dailyUsage(days: 30)

        // What a table under a 30-day chart reads out for one band: the window's
        // whole reading, split kept, not just a token count.
        let summed = history.total.summed()
        XCTAssertEqual(summed.usage.inputTokens, 1_500_000)
        XCTAssertEqual(summed.usage.outputTokens, 2_000)
        XCTAssertEqual(summed.usage.cacheReadInputTokens, 7)
        XCTAssertEqual(summed.usage.totalTokens, history.total.reduce(0) { $0 + $1.totalTokens })
        XCTAssertEqual(
            summed.estimatedCostUSD,
            history.total.reduce(0) { $0 + $1.estimatedCostUSD },
            accuracy: 0.000_001
        )
        XCTAssertGreaterThan(summed.estimatedCostUSD, 0)
    }

    func testSummingAnEmptySeriesIsTheZeroReading() {
        // The state a table renders while a band has no points at all — a row
        // of zeroes, never a crash and never a missing row.
        let summed = [DailyUsagePoint]().summed()

        XCTAssertEqual(summed.usage, .zero)
        XCTAssertEqual(summed.estimatedCostUSD, 0)
    }

    func testSummingASliceOfASeriesCoversOnlyThatSlice() throws {
        let store = makeStore(events: [
            try event("2026-07-13T09:00:00.000Z", tokens: 100),
            try event("2026-07-14T09:00:00.000Z", tokens: 20),
            try event("2026-07-15T09:00:00.000Z", tokens: 3),
        ])
        let history = try store.dailyUsage(days: 30)

        XCTAssertEqual(history.total.suffix(2).summed().usage.totalTokens, 23)
    }

    // MARK: - Day resolver

    func testDayResolverReusesTheDayAndStillHandlesDST() throws {
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        var resolver = LocalDayResolver(calendar: berlin)

        // 2026-03-29 is the spring-forward day in Berlin: that local day is 23
        // hours long, so a resolver that cached "start + 86400" would file the
        // last hour under the wrong date.
        let beforeSwitch = try date("2026-03-29T00:30:00.000Z")   // 01:30 CET, the 29th
        let afterSwitch = try date("2026-03-29T21:30:00.000Z")    // 23:30 CEST, still the 29th
        let nextDay = try date("2026-03-29T22:30:00.000Z")        // 00:30 CEST, the 30th

        let day29 = resolver.day(for: beforeSwitch)
        XCTAssertEqual(resolver.day(for: afterSwitch), day29)
        XCTAssertNotEqual(resolver.day(for: nextDay), day29)
        XCTAssertEqual(
            resolver.day(for: nextDay),
            berlin.startOfDay(for: nextDay)
        )
    }

    func testDayResolverIsCorrectForOutOfOrderTimestamps() throws {
        var resolver = LocalDayResolver(calendar: Self.utcCalendar)
        let stamps = [
            "2026-07-15T09:00:00.000Z",
            "2026-07-10T09:00:00.000Z",  // backwards jump
            "2026-07-15T23:59:59.000Z",
            "2026-07-01T00:00:00.000Z",
        ]

        // The cache is an optimisation, never a rounding: each timestamp must
        // still resolve to exactly what the calendar would say on its own.
        for iso in stamps {
            let timestamp = try date(iso)
            XCTAssertEqual(
                resolver.day(for: timestamp),
                Self.utcCalendar.startOfDay(for: timestamp),
                "\(iso) resolved to a neighbour's day"
            )
        }
    }

    // MARK: - Mock

    func testMockSampleHistoryIsDeterministicAndInternallyConsistent() throws {
        let now = Self.referenceNow
        let store = MockUsageStore(calendar: Self.utcCalendar, now: { now })

        let first = try store.dailyUsage(days: 30)
        let second = try store.dailyUsage(days: 30)

        XCTAssertEqual(first, second, "a preview redrawn twice must draw the same chart")
        XCTAssertEqual(first.days.count, 30)
        XCTAssertEqual(Set(first.bySource.keys), Set(Entrypoint.allCases))
        for (index, day) in first.days.enumerated() {
            let sources = Entrypoint.allCases.reduce(0) { $0 + (first.bySource[$1]?[index].totalTokens ?? 0) }
            let models = first.byModelFamily.values.reduce(0) { $0 + $1[index].totalTokens }
            // Each series is rounded to whole tokens independently, so the two
            // splits of the same day can drift by a token or two — but not more,
            // or the two charts would contradict each other on \(day).
            XCTAssertLessThanOrEqual(abs(sources - models), 4, "day \(day)")
        }
    }

    func testMockCostTodayMatchesTheLastPointOfItsOwnSampleHistory() throws {
        let now = Self.referenceNow
        let store = MockUsageStore(calendar: Self.utcCalendar, now: { now })

        // The same invariant the real store gets for free — see
        // `testTodaysPointMatchesEstimatedCostToday`. Worth pinning on the mock
        // too: the README screenshots are rendered from it, so a drift here
        // ships a picture of the popover contradicting itself.
        let history = try store.dailyUsage(days: 30)
        XCTAssertEqual(
            try XCTUnwrap(history.total.last).estimatedCostUSD,
            try store.estimatedCostToday(),
            accuracy: 0.000_001
        )
        XCTAssertGreaterThan(try store.estimatedCostToday(), 0)
    }
}
