import Accessibility
import XCTest
@testable import ClaudeStats
@testable import ClaudeStatsCore

/// Coverage for the "Tokens by source" chart's data shaping and its accessibility
/// descriptor — the two parts of the section that are logic rather than layout.
final class DailyUsageChartTests: XCTestCase {

    static let referenceNow = SessionLogParser.parseTimestamp("2026-07-15T12:00:00.000Z")!

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Three days of usage, CLI and SDK only — VS Code deliberately silent.
    private func makeHistory() throws -> DailyUsageHistory {
        let now = Self.referenceNow
        let store = LocalLogUsageStore(
            events: [
                UsageEvent(
                    timestamp: try XCTUnwrap(SessionLogParser.parseTimestamp("2026-07-13T09:00:00.000Z")),
                    entrypoint: .cli,
                    modelID: "claude-sonnet-5",
                    usage: TokenUsage(inputTokens: 100)
                ),
                // Same day as the SDK event below, so the stacked height of
                // the last day (900) exceeds the tallest single band (700).
                UsageEvent(
                    timestamp: try XCTUnwrap(SessionLogParser.parseTimestamp("2026-07-15T08:00:00.000Z")),
                    entrypoint: .cli,
                    modelID: "claude-sonnet-5",
                    usage: TokenUsage(inputTokens: 200)
                ),
                UsageEvent(
                    timestamp: try XCTUnwrap(SessionLogParser.parseTimestamp("2026-07-15T09:00:00.000Z")),
                    entrypoint: .sdkAgent,
                    modelID: "claude-opus-5",
                    usage: TokenUsage(inputTokens: 700)
                ),
            ],
            calendar: Self.utcCalendar,
            now: { now }
        )
        return try store.dailyUsage(days: 30)
    }

    // MARK: - Series shaping

    func testSourceSeriesFollowEntrypointDisplayOrder() throws {
        let series = DailyUsageSeries.sources(from: try makeHistory())

        // The legend zips these bands against `Entrypoint.displayOrder` to pair
        // each swatch with its five-hour number, so the orders must match.
        XCTAssertEqual(series.map(\.label), Entrypoint.displayOrder.map(\.displayName))
    }

    func testSilentSourceStillGetsABand() throws {
        let series = DailyUsageSeries.sources(from: try makeHistory())
        let vscode = try XCTUnwrap(series.first { $0.label == Entrypoint.vscode.displayName })

        // "VS Code: 0" is a reading the popover shows, not a row it drops — and
        // a band with no points at all would leave its legend swatch meaning
        // nothing.
        XCTAssertEqual(vscode.points.count, 3)
        XCTAssertTrue(vscode.points.allSatisfy { $0.totalTokens == 0 })
    }

    func testBandShadesAreDistinctAndDescending() throws {
        let shades = DailyUsageSeries.sources(from: try makeHistory()).map(\.shade)

        XCTAssertEqual(Set(shades).count, shades.count, "two bands sharing a shade are unreadable")
        XCTAssertEqual(shades, shades.sorted(by: >))
    }

    func testEmptyHistoryStillYieldsOneBandPerSourceWithNoPoints() {
        let series = DailyUsageSeries.sources(from: .empty)

        XCTAssertEqual(series.map(\.label), Entrypoint.displayOrder.map(\.displayName))
        XCTAssertTrue(series.allSatisfy { $0.points.isEmpty })
    }

    // MARK: - X-axis ticks

    private func chart(dayCount: Int) -> DailyUsageChart {
        let start = Self.utcCalendar.startOfDay(for: Self.referenceNow)
        let days = (0..<dayCount).compactMap {
            Self.utcCalendar.date(byAdding: .day, value: -($0), to: start)
        }.reversed()
        return DailyUsageChart(days: Array(days), series: [])
    }

    func testTicksAreWeeklyAndStopShortOfTheRightEdge() {
        let chart = self.chart(dayCount: 30)
        let ticks = chart.tickDays

        // Every seventh day, and nothing in the last four — a label centred on
        // a tick that close is truncated against the chart's trailing bound.
        XCTAssertEqual(ticks.count, 4)
        XCTAssertEqual(ticks, [0, 7, 14, 21].map { chart.days[$0] })
        let cutoff = chart.days[chart.days.count - 1 - 4]
        XCTAssertTrue(ticks.allSatisfy { $0 <= cutoff })
    }

    func testEveryTickIsADayTheChartActuallyPlots() {
        let chart = self.chart(dayCount: 23)
        XCTAssertTrue(chart.tickDays.allSatisfy { chart.days.contains($0) })
    }

    func testAShortWindowStillGetsOneDatedTick() {
        // Three days is inside the edge margin from both ends; a chart with no
        // tick at all would be undated.
        let chart = self.chart(dayCount: 3)
        XCTAssertEqual(chart.tickDays, [chart.days[0]])
    }

    func testNoDaysMeansNoTicks() {
        XCTAssertTrue(chart(dayCount: 0).tickDays.isEmpty)
    }

    // MARK: - Hover highlight

    func testTheHighlightMarksTheHoveredDay() {
        let chart = self.chart(dayCount: 30)
        let hovered = DailyUsageChart(days: chart.days, series: [], hoveredDay: chart.days[4])

        XCTAssertEqual(hovered.highlightedIndex, 4)
        XCTAssertNil(chart.highlightedIndex, "no pointer, no rule")
    }

    func testADayFromAWindowThatHasMovedIsNotHighlighted() {
        let chart = self.chart(dayCount: 30)
        let dropped = Self.utcCalendar.date(byAdding: .day, value: -90, to: Self.referenceNow)

        XCTAssertNil(DailyUsageChart(days: chart.days, series: [], hoveredDay: dropped).highlightedIndex)
    }

    func testEachDotSitsOnTheEdgeOfItsOwnBand() throws {
        let history = try makeHistory()
        let series = DailyUsageSeries.sources(from: history)
        let chart = DailyUsageChart(days: history.days, series: series, hoveredDay: history.days.last)
        let index = try XCTUnwrap(chart.highlightedIndex)

        // The areas stack, so the dots have to climb with them — CLI's 200 and
        // the SDK's 700 make edges at 200 and 900, not two dots at their own
        // heights. VS Code did nothing that day and gets no dot.
        XCTAssertEqual(chart.stackTops(at: index).map(\.tokens), [200, 900])
        XCTAssertEqual(chart.stackTops(at: index).map(\.id), ["CLI", Entrypoint.sdkAgent.displayName])
    }

    func testASilentSourceGetsNoDotOfItsOwn() throws {
        let history = try makeHistory()
        let chart = DailyUsageChart(
            days: history.days,
            series: DailyUsageSeries.sources(from: history),
            hoveredDay: history.days.first
        )
        let index = try XCTUnwrap(chart.highlightedIndex)

        // Only CLI ran on the first day of the fixture. A dot for each silent
        // source would stack three of them on one edge.
        XCTAssertEqual(chart.stackTops(at: index).map(\.tokens), [100])
    }

    // MARK: - Accessibility

    func testChartDescriptorCarriesEverySourceAndEveryDay() throws {
        let history = try makeHistory()
        let descriptor = DailyUsageChartDescriptor(
            days: history.days,
            series: DailyUsageSeries.sources(from: history)
        ).makeChartDescriptor()

        // Replacing the table means replacing what it announced: every source,
        // every day, as data rather than as an image.
        XCTAssertEqual(descriptor.series.count, Entrypoint.displayOrder.count)
        XCTAssertEqual(descriptor.series.map(\.name), Entrypoint.displayOrder.map(\.displayName))
        for series in descriptor.series {
            XCTAssertEqual(series.dataPoints.count, history.days.count)
        }
        XCTAssertTrue(descriptor.title?.contains("\(history.days.count) days") ?? false)
    }

    func testChartDescriptorYAxisCoversTheTallestDay() throws {
        let history = try makeHistory()
        let descriptor = DailyUsageChartDescriptor(
            days: history.days,
            series: DailyUsageSeries.sources(from: history)
        ).makeChartDescriptor()

        let yAxis = try XCTUnwrap(descriptor.yAxis as? AXNumericDataAxisDescriptor)
        let tallestDay = history.total.map(\.totalTokens).max() ?? 0
        let tallestBand = DailyUsageSeries.sources(from: history)
            .flatMap { $0.points.map(\.totalTokens) }
            .max() ?? 0
        XCTAssertGreaterThan(tallestDay, tallestBand, "fixture must stack higher than any one band")
        XCTAssertEqual(yAxis.range.upperBound, Double(tallestDay), accuracy: 0.5)
    }

    /// The crash this guards was real: the first run of these tests died with
    /// `Double value cannot be converted to Int because it is either infinite
    /// or NaN`, because the framework calls this closure with probe values of
    /// its own choosing and `Int(Double)` traps on those.
    func testChartDescriptorDescribesNonFiniteAndOutOfRangeValuesWithoutTrapping() throws {
        let history = try makeHistory()
        let descriptor = DailyUsageChartDescriptor(
            days: history.days,
            series: DailyUsageSeries.sources(from: history)
        ).makeChartDescriptor()
        let yAxis = try XCTUnwrap(descriptor.yAxis as? AXNumericDataAxisDescriptor)
        let describe = try XCTUnwrap(yAxis.valueDescriptionProvider)

        XCTAssertEqual(describe(.infinity), "unknown")
        XCTAssertEqual(describe(-.infinity), "unknown")
        XCTAssertEqual(describe(.nan), "unknown")
        XCTAssertFalse(describe(.greatestFiniteMagnitude).isEmpty)
        XCTAssertFalse(describe(-1).isEmpty)
        XCTAssertTrue(describe(900).contains("900"))
    }

    func testChartDescriptorSurvivesAnEmptyHistory() {
        // An all-zero range would be a divide-by-zero waiting to happen for
        // VoiceOver's audio graph.
        let descriptor = DailyUsageChartDescriptor(
            days: [],
            series: DailyUsageSeries.sources(from: .empty)
        ).makeChartDescriptor()

        let yAxis = descriptor.yAxis as? AXNumericDataAxisDescriptor
        XCTAssertGreaterThan(yAxis?.range.upperBound ?? 0, 0)
        XCTAssertTrue(descriptor.series.allSatisfy { $0.dataPoints.isEmpty })
    }
}
