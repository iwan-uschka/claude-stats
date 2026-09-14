import Accessibility
import XCTest
@testable import ClaudeStats
@testable import ClaudeStatsCore

/// Coverage for the stacked chart's data shaping and its accessibility
/// descriptor — the parts of a usage block that are logic rather than layout.
///
/// One chart type draws both blocks, so most of this is asserted once and the
/// metric-specific half (which field of a day is read, how the axis spells it,
/// what VoiceOver says) is asserted for each of ``DailyUsageMetric``'s cases.
final class DailyUsageChartTests: XCTestCase {

    static let referenceNow = SessionLogParser.parseTimestamp("2026-07-15T12:00:00.000Z")!

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Three days of usage, CLI and SDK only — VS Code deliberately silent,
    /// Sonnet and Opus only — Haiku and Fable deliberately absent.
    ///
    /// `unrecognisedSourceTokens` adds an event on the last day whose
    /// `entrypoint` this version doesn't know, and `unrecognisedModelTokens` one
    /// whose model ID it doesn't know. Either is what the history buckets under
    /// `nil` and the chart draws as "Other" in its own split.
    private func makeHistory(
        unrecognisedSourceTokens: Int = 0,
        unrecognisedModelTokens: Int = 0
    ) throws -> DailyUsageHistory {
        let now = Self.referenceNow
        let unrecognised: [UsageEvent] = (unrecognisedSourceTokens == 0 ? [] : [
            UsageEvent(
                timestamp: try XCTUnwrap(SessionLogParser.parseTimestamp("2026-07-15T10:00:00.000Z")),
                entrypoint: nil,
                modelID: "claude-sonnet-5",
                usage: TokenUsage(inputTokens: unrecognisedSourceTokens)
            )
        ]) + (unrecognisedModelTokens == 0 ? [] : [
            UsageEvent(
                timestamp: try XCTUnwrap(SessionLogParser.parseTimestamp("2026-07-15T11:00:00.000Z")),
                entrypoint: .cli,
                modelID: "some-model-from-the-future",
                usage: TokenUsage(inputTokens: unrecognisedModelTokens)
            )
        ])
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
            ] + unrecognised,
            calendar: Self.utcCalendar,
            now: { now }
        )
        return try store.dailyUsage(days: 30)
    }

    // MARK: - Series shaping

    func testSourceSeriesFollowEntrypointDisplayOrder() throws {
        let series = DailyUsageSeries.sources(from: try makeHistory())

        // Display order is table order, and the chart stacks it upside down
        // so the first row is the *top* band — see `stackOrder`.
        XCTAssertEqual(series.map(\.label), Entrypoint.displayOrder.map(\.displayName))
    }

    func testTheOtherBandComesLastAndOnlyWhenThereIsOtherUsage() throws {
        let plain = try makeHistory()
        XCTAssertEqual(DailyUsageSeries.sourceKeys(in: plain), Entrypoint.displayOrder.map { $0 })
        XCTAssertFalse(DailyUsageSeries.sources(from: plain).contains { $0.label == DailyUsageSeries.otherBandLabel })

        let history = try makeHistory(unrecognisedSourceTokens: 500)
        let series = DailyUsageSeries.sources(from: history)

        // Last row, i.e. the bottom of the stack: the named sources are what a
        // reader is looking for, and a bucket that can appear between two polls
        // must not shuffle the bands beside it when it does.
        XCTAssertEqual(
            series.map(\.label),
            Entrypoint.displayOrder.map(\.displayName) + [DailyUsageSeries.otherBandLabel]
        )
        XCTAssertEqual(DailyUsageSeries.sourceKeys(in: history), Entrypoint.displayOrder.map { $0 } + [nil])
        XCTAssertEqual(series.last?.points.map(\.totalTokens).reduce(0, +), 500)
        XCTAssertEqual(series.last?.color, DailyUsageSeries.bandColor(3, of: 4))
    }

    /// Keys and bands are published separately, and anything pairing them zips
    /// the two lists — a mismatch in either direction mislabels a colour, which
    /// is the whole point of the dot.
    func testTheKeysAndTheBandsLineUpInBothShapesOfTheWindow() throws {
        for history in [try makeHistory(), try makeHistory(unrecognisedSourceTokens: 500)] {
            let keys = DailyUsageSeries.sourceKeys(in: history)
            let series = DailyUsageSeries.sources(from: history)

            XCTAssertEqual(keys.count, series.count)
            XCTAssertEqual(
                zip(keys, series).map { $0.0?.displayName ?? DailyUsageSeries.otherBandLabel },
                series.map(\.label)
            )
        }
    }

    func testSilentSourceStillGetsABand() throws {
        let series = DailyUsageSeries.sources(from: try makeHistory())
        let vscode = try XCTUnwrap(series.first { $0.label == Entrypoint.vscode.displayName })

        // "VS Code: 0" is a reading the popover shows, not a row it drops — and
        // a band with no points at all would leave its table dot meaning
        // nothing.
        XCTAssertEqual(vscode.points.count, 3)
        XCTAssertTrue(vscode.points.allSatisfy { $0.totalTokens == 0 })
    }

    func testBandsTakeTheRampsShadesInRowOrder() throws {
        let colors = DailyUsageSeries.sources(from: try makeHistory()).map(\.color)

        // Strongest shade on the first row, which is the top of the stack, one
        // step per band down the table. Which shades those are, that the ramp
        // spreads them over its whole range, and that they can be told apart,
        // is measured in `PopoverColorTests`.
        XCTAssertEqual(Set(colors).count, colors.count, "two bands sharing a shade are unreadable")
        XCTAssertEqual(colors, colors.indices.map { DailyUsageSeries.bandColor($0, of: colors.count) })
    }

    func testTheStackIsTheTableUpsideDownSoTheFirstRowIsTheTopBand() throws {
        // The flip this exists for. The table reads downwards from its first
        // row and a stack reads downwards from its top band; with the first
        // band at the bottom those two sequences were mirror images of each
        // other, and row one pointed at the band furthest from it. Now they run
        // the same way — and "Other", last in display order, is the bottom band
        // rather than the top one.
        let history = try makeHistory(unrecognisedSourceTokens: 500)
        let series = DailyUsageSeries.sources(from: history)
        let chart = DailyUsageChart(days: history.days, series: series)

        XCTAssertEqual(chart.stackOrder.map(\.label), series.map(\.label).reversed())
        XCTAssertEqual(chart.series.first?.label, Entrypoint.cli.displayName)
        XCTAssertEqual(chart.stackOrder.first?.label, DailyUsageSeries.otherBandLabel)
        XCTAssertEqual(chart.stackOrder.last?.label, Entrypoint.cli.displayName)
        // The ramp still follows the *rows*: band 0 is the brand colour and it
        // is the top of the stack now, not the bottom.
        XCTAssertEqual(chart.stackOrder.last?.color, PopoverMetrics.chartBandColor(0, of: series.count))
    }

    func testEmptyHistoryStillYieldsOneBandPerSourceWithNoPoints() {
        let series = DailyUsageSeries.sources(from: .empty)

        XCTAssertEqual(series.map(\.label), Entrypoint.displayOrder.map(\.displayName))
        XCTAssertTrue(series.allSatisfy { $0.points.isEmpty })
    }

    // MARK: - Model series shaping

    func testModelSeriesFollowFamilyDisplayOrderAndSkipAbsentFamilies() throws {
        let history = try makeHistory()
        let series = DailyUsageSeries.models(from: history)

        // Only the families the window holds, unlike the source split, which
        // keeps a silent entrypoint. A zero row for a model Anthropic ships but
        // this account never touched says nothing about this Mac.
        XCTAssertEqual(series.map(\.label), [ModelFamily.sonnet.displayName, ModelFamily.opus.displayName])
        XCTAssertEqual(DailyUsageSeries.modelKeys(in: history), [ModelFamily?.some(.sonnet), .some(.opus)])
        XCTAssertFalse(series.contains { $0.label == ModelFamily.haiku.displayName })
    }

    func testTheOtherModelBandComesLastAndOnlyWhenThereIsOtherUsage() throws {
        XCTAssertFalse(DailyUsageSeries.models(from: try makeHistory()).contains {
            $0.label == DailyUsageSeries.otherBandLabel
        })

        let history = try makeHistory(unrecognisedModelTokens: 400)
        let series = DailyUsageSeries.models(from: history)

        // Last row, i.e. the bottom of the stack — the same rule the source
        // split follows, for the same reason: a bucket that can appear between
        // two polls must not shuffle the named bands beside it.
        XCTAssertEqual(
            series.map(\.label),
            [ModelFamily.sonnet.displayName, ModelFamily.opus.displayName, DailyUsageSeries.otherBandLabel]
        )
        XCTAssertEqual(DailyUsageSeries.modelKeys(in: history).last, ModelFamily?.none)
        XCTAssertEqual(series.last?.points.map(\.totalTokens).reduce(0, +), 400)
    }

    func testBothSplitsIndexTheRampTheSameWay() throws {
        // One rule for both tables: the ramp is indexed by row position and
        // handed the row count, so a dot two rows down means "two bands down
        // from the top" in either block. Anything else would make the same
        // shade mean two things.
        let history = try makeHistory(unrecognisedSourceTokens: 500, unrecognisedModelTokens: 400)
        for series in [DailyUsageSeries.sources(from: history), DailyUsageSeries.models(from: history)] {
            XCTAssertEqual(series.map(\.color), series.indices.map { DailyUsageSeries.bandColor($0, of: series.count) })
        }
    }

    func testTheModelBandsSumToTheWindowsTotalSpend() throws {
        let history = try makeHistory(unrecognisedModelTokens: 400)
        let bands = DailyUsageSeries.models(from: history)
            .map { $0.points.summed().estimatedCostUSD }
            .reduce(0, +)

        // The top edge of this stack replaced the old single cost line, so it
        // has to be that line: nothing dropped, nothing double-counted.
        XCTAssertEqual(bands, history.total.summed().estimatedCostUSD, accuracy: 1e-9)
    }

    // MARK: - Metric

    private func costChart(from history: DailyUsageHistory, hoveredDay: Date? = nil) -> DailyUsageChart {
        DailyUsageChart(
            days: history.days,
            series: DailyUsageSeries.models(from: history),
            metric: .cost,
            bandsName: "model",
            hoveredDay: hoveredDay
        )
    }

    func testTheCostMetricPlotsSpendWhereTheTokenMetricPlotsTokens() throws {
        let history = try makeHistory()
        let series = DailyUsageSeries.models(from: history)
        let tokens = DailyUsageChart(days: history.days, series: series)
        let cost = costChart(from: history)

        // Same bands, same days, two different readings off them — which is the
        // whole of what the metric parameter decides.
        XCTAssertEqual(tokens.stackedMaximum, Double(history.total.map(\.totalTokens).max() ?? 0))
        XCTAssertEqual(cost.stackedMaximum, history.total.map(\.estimatedCostUSD).max() ?? 0, accuracy: 1e-9)
        XCTAssertNotEqual(tokens.stackedMaximum, cost.stackedMaximum)
    }

    func testTheCostChartsDotsClimbTheStackInDollars() throws {
        let history = try makeHistory()
        let chart = costChart(from: history, hoveredDay: history.days.last)
        let index = try XCTUnwrap(chart.highlightedIndex)
        let bands = DailyUsageSeries.models(from: history).map { $0.points[index].estimatedCostUSD }

        // Cumulative, like the token stack: a dot at a band's own spend would
        // float inside the stack rather than sit on the edge the chart draws.
        // Bottom band first, and the bottom band is the *last* row — Opus here,
        // with Sonnet's edge sitting on top of it.
        XCTAssertEqual(chart.stackTops(at: index).map(\.value), [bands[1], bands[1] + bands[0]])
    }

    func testEachMetricLabelsItsAxisInItsOwnUnit() {
        // `$2.50` is not `2G` wide, which is the whole reason the popover
        // measures a shared label column instead of reserving one.
        let days = chart(dayCount: 30).days
        let cost = DailyUsageChart(
            days: days,
            series: [DailyUsageSeries(
                label: "Sonnet",
                color: DailyUsageSeries.bandColor(0, of: 1),
                points: days.map { DailyUsagePoint(day: $0, estimatedCostUSD: 2.5) }
            )],
            metric: .cost
        )
        let tokens = DailyUsageChart(
            days: days,
            series: [DailyUsageSeries(
                label: "CLI",
                color: DailyUsageSeries.bandColor(0, of: 1),
                points: days.map { DailyUsagePoint(day: $0, usage: TokenUsage(inputTokens: 2_000_000_000)) }
            )]
        )

        XCTAssertEqual(cost.yLabels, DisplayFormat.costAxisLabels(cost.yValues))
        XCTAssertEqual(tokens.yLabels, DisplayFormat.tokenAxisLabels(tokens.yValues.map { Int($0.rounded()) }))
        XCTAssertTrue(cost.yLabels.contains { $0.hasPrefix("$") })
        XCTAssertFalse(tokens.yLabels.contains { $0.hasPrefix("$") })
        XCTAssertNotEqual(cost.naturalYLabelWidth, tokens.naturalYLabelWidth)
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

        // The areas stack, so the dots have to climb with them — and they climb
        // in *stack* order, which is the table read upwards: the SDK's 700 sits
        // at the bottom and CLI's 200 closes the stack at 900, not two dots at
        // their own heights. VS Code did nothing that day and gets no dot.
        XCTAssertEqual(chart.stackTops(at: index).map(\.value), [700, 900])
        XCTAssertEqual(chart.stackTops(at: index).map(\.id), [Entrypoint.sdkAgent.displayName, "CLI"])
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
        XCTAssertEqual(chart.stackTops(at: index).map(\.value), [100])
    }

    // MARK: - Accessibility

    func testChartDescriptorCarriesEverySourceAndEveryDay() throws {
        let history = try makeHistory()
        let descriptor = DailyUsageChartDescriptor(
            days: history.days,
            series: DailyUsageSeries.sources(from: history)
        ).makeChartDescriptor()

        // The chart is the only place thirty days of per-band readings exist —
        // the table beneath it reads one window — so VoiceOver gets every
        // source and every day as data rather than an unlabelled image.
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

    func testTheCostDescriptorNamesItsUnitAndItsSplit() throws {
        let history = try makeHistory()
        let descriptor = DailyUsageChartDescriptor(
            days: history.days,
            series: DailyUsageSeries.models(from: history),
            metric: .cost,
            bandsName: "model"
        ).makeChartDescriptor()

        // VoiceOver reads this with no visual context, so neither the `$` nor
        // the section title is available to say what the numbers are.
        XCTAssertEqual(descriptor.title, "Estimated cost by model, last \(history.days.count) days")
        let yAxis = try XCTUnwrap(descriptor.yAxis as? AXNumericDataAxisDescriptor)
        XCTAssertEqual(yAxis.title, "Estimated cost in US dollars")
        // Floored at 1 like the token axis: a fixture whose dearest day is
        // under a dollar must not hand VoiceOver's audio graph a hair-thin
        // range to scale every reading against.
        XCTAssertEqual(
            yAxis.range.upperBound,
            max(history.total.map(\.estimatedCostUSD).max() ?? 0, 1),
            accuracy: 1e-9
        )
        XCTAssertEqual(descriptor.series.map(\.name), [ModelFamily.sonnet.displayName, ModelFamily.opus.displayName])
    }

    /// The same probe-value guard the token axis needs, on the formatter the
    /// cost axis uses: `%f` of `greatestFiniteMagnitude` is a 300-digit label
    /// rather than a crash, which is worse — it renders.
    func testTheCostDescriptorDescribesProbeValuesWithoutTrappingOrLying() throws {
        let descriptor = DailyUsageChartDescriptor(
            days: try makeHistory().days,
            series: [],
            metric: .cost
        ).makeChartDescriptor()
        let yAxis = try XCTUnwrap(descriptor.yAxis as? AXNumericDataAxisDescriptor)
        let describe = try XCTUnwrap(yAxis.valueDescriptionProvider)

        XCTAssertEqual(describe(.nan), "unknown")
        XCTAssertEqual(describe(.infinity), "unknown")
        XCTAssertEqual(describe(.greatestFiniteMagnitude), "unknown")
        // Never a bare number: read out of any visual context, the estimate has
        // to say it is one.
        XCTAssertEqual(describe(12.25), "$12 estimated")
        XCTAssertEqual(describe(0), "$0 estimated")
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

    // MARK: - Y-axis values

    func testTheYAxisStepsInRoundNumbersPastTheTallestDay() {
        // Round steps, and a top *above* the data: the last value is the
        // domain's ceiling, so a spike never touches the top of the plot.
        XCTAssertEqual(PopoverChartAxis.yValues(upTo: 5.2), [0, 2, 4, 6])
        XCTAssertEqual(PopoverChartAxis.yValues(upTo: 2_200_000), [0, 1_000_000, 2_000_000, 3_000_000])
        XCTAssertEqual(PopoverChartAxis.yValues(upTo: 0.9), [0, 0.5, 1])
    }

    func testAWindowWithNothingInItStillHasAScale() {
        // A `0...0` domain is a divide by zero waiting to happen, and an axis
        // with one value on it says less than one that shows the zero line.
        XCTAssertEqual(PopoverChartAxis.yValues(upTo: 0), [0, 1])
    }

    func testTheLabelColumnIsMeasuredInTheFontTheAxisDrawsIn() {
        // The width the popover gives both charts comes from these strings, so
        // it has to be measured in the font that renders them.
        let width = PopoverChartAxis.yLabelWidth(of: ["0", "2M", "4M"])
        let widest = ("4M" as NSString).size(withAttributes: [.font: PopoverMetrics.captionNSFont]).width

        XCTAssertEqual(width, widest, accuracy: 0.01)
        XCTAssertEqual(PopoverChartAxis.yLabelWidth(of: []), 0)
    }
}
