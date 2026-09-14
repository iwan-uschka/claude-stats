import AppKit
import SwiftUI
import XCTest

@testable import ClaudeStats
@testable import ClaudeStatsCore

/// Measures where a popover chart actually puts its ink, and whether it leaves
/// any gaps in it.
///
/// Pixels, because nothing else can see this. Where Swift Charts places a mark
/// along the x scale is not reachable from the view — `ChartProxy` answers for
/// the scale, not for the mark, and reports the same position whether or not
/// the mark is binned. The bug this guards lived in exactly that gap: every
/// mark carried `unit: .day`, which bins the date and draws the mark at the
/// *centre* of its bin, while the axis ticks are plain dates on the bin's
/// leading edge. The rule under the pointer sat a measured 19 px — half a day,
/// close to 5 pt — right of the tick naming the day it claimed to mark, and
/// every unit test passed.
///
/// The seam between two stacked bands is the same kind of thing: invisible to
/// every measurement here except a pixel one, and the first thing the eye finds
/// in the rendered card.
///
/// Rendered through ``PopoverPixels``, the draw path ``ReadmeAssetRenderTests``
/// uses and the one the shipping popover takes.
@MainActor
final class PopoverChartAlignmentTests: XCTestCase {
    /// A day is about 39 px wide at this scale and the offset this guards was
    /// 19 px, so three leaves room for anti-aliasing and nothing else.
    private static let tolerance: CGFloat = 3

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static let firstDay = SessionLogParser.parseTimestamp("2026-07-01T00:00:00.000Z")!

    private func days(_ count: Int) -> [Date] {
        (0..<count).compactMap { Self.calendar.date(byAdding: .day, value: $0, to: Self.firstDay) }
    }

    // MARK: - Tests

    /// A day that carries a tick, so the rule has something to line up with.
    /// Not the first or the last: a rule at an edge would also line up if the
    /// plot were simply clipping it.
    private func hoveredTickDay(in days: [Date]) -> Date { PopoverChartAxis.tickDays(in: days)[1] }

    /// One band of `points`, which is all any of these measurements needs —
    /// the offsets they guard are properties of the scale, not of the stack.
    private func band(_ points: [DailyUsagePoint]) -> [DailyUsageSeries] {
        [DailyUsageSeries(label: "CLI", color: DailyUsageSeries.bandColor(0, of: 1), points: points)]
    }

    func testTheModelChartsHoverRuleLandsOnTheHoveredDaysAxisTick() throws {
        // The cost metric measured separately from the token one: it picks its
        // own y-values and its own label widths, and the leading edge those put
        // the plot at is exactly what a misaligned rule would be measured from.
        let days = self.days(30)
        let series = band(days.map { DailyUsagePoint(day: $0, estimatedCostUSD: 5) })

        try assertRuleSitsOnATick(
            hovered: DailyUsageChart(days: days, series: series, metric: .cost, hoveredDay: hoveredTickDay(in: days)),
            resting: DailyUsageChart(days: days, series: series, metric: .cost)
        )
    }

    func testTheSourceChartsHoverRuleLandsOnTheHoveredDaysAxisTick() throws {
        let days = self.days(30)
        let series = band(days.map { DailyUsagePoint(day: $0, usage: TokenUsage(inputTokens: 1000)) })

        try assertRuleSitsOnATick(
            hovered: DailyUsageChart(days: days, series: series, hoveredDay: hoveredTickDay(in: days)),
            resting: DailyUsageChart(days: days, series: series)
        )
    }

    /// The two charts the popover stacks, over the same days, with y-labels of
    /// deliberately different widths: `$2.50`-shaped against `2G`-shaped.
    private func stackedCharts(days: [Date], yLabelWidth: CGFloat? = nil) -> (cost: DailyUsageChart, source: DailyUsageChart) {
        (
            DailyUsageChart(
                days: days,
                series: band(days.map { DailyUsagePoint(day: $0, estimatedCostUSD: 2.5) }),
                metric: .cost,
                yLabelWidth: yLabelWidth
            ),
            DailyUsageChart(
                days: days,
                series: band(days.map { DailyUsagePoint(day: $0, usage: TokenUsage(inputTokens: 2_000_000_000)) }),
                yLabelWidth: yLabelWidth
            )
        )
    }

    /// A cost chart over `points` — the "By model" shape, the one whose ink is
    /// the sharper measuring stick for where the plot starts and stops.
    private func costChart(days: [Date], points: [DailyUsagePoint], hoveredDay: Date? = nil) -> DailyUsageChart {
        DailyUsageChart(days: days, series: band(points), metric: .cost, hoveredDay: hoveredDay)
    }

    func testAChartsLabelColumnIsTheWidthOfItsOwnWidestLabel() {
        // The number the popover collects from each chart. It has to be
        // measured from the strings the axis will actually draw, which is why
        // the charts pick their own y-values rather than leaving them
        // automatic — see ``PopoverChartAxis/yValues(upTo:count:)``.
        let charts = stackedCharts(days: days(30))
        let widest = charts.cost.yLabels
            .map { ($0 as NSString).size(withAttributes: [.font: PopoverMetrics.captionNSFont]).width }
            .max()

        XCTAssertEqual(charts.cost.naturalYLabelWidth, try XCTUnwrap(widest), accuracy: 0.01)
        // Data-sized, not the column it replaced: 32 pt held `$12.5k`, which is
        // the widest label the formatters can produce and not a day either of
        // these charts plots.
        XCTAssertLessThan(max(charts.cost.naturalYLabelWidth, charts.source.naturalYLabelWidth), 30)
    }

    func testBothChartsStartTheirPlotsAtTheSameX() throws {
        // The two plots are stacked in one column and take the same x-ticks, so
        // a given x has to mean one day in both — which it doesn't if each
        // chart starts its plot wherever its own widest y-label happens to end.
        // This is the popover's own arithmetic: measure what each chart needs,
        // hand both the larger.
        let days = self.days(30)
        let natural = stackedCharts(days: days)
        let shared = max(natural.cost.naturalYLabelWidth, natural.source.naturalYLabelWidth)
        XCTAssertNotEqual(natural.cost.naturalYLabelWidth, natural.source.naturalYLabelWidth, "the fixture needs two different label widths to be testing anything")

        let charts = stackedCharts(days: days, yLabelWidth: shared)
        XCTAssertEqual(
            try PopoverPixels.render(charts.cost).dataLeadingEdge(),
            try PopoverPixels.render(charts.source).dataLeadingEdge(),
            accuracy: Self.tolerance
        )
    }

    func testTheSharedColumnCostsTheWiderChartNothing() throws {
        // Sized to the data, or it is the reserved column again: the chart that
        // needed the most room must start its plot in exactly the same place
        // whether or not the column is applied — only the narrower one moves.
        let days = self.days(30)
        let natural = stackedCharts(days: days)
        let shared = max(natural.cost.naturalYLabelWidth, natural.source.naturalYLabelWidth)
        let wider = natural.cost.naturalYLabelWidth > natural.source.naturalYLabelWidth

        let alone = wider ? try PopoverPixels.render(natural.cost) : try PopoverPixels.render(natural.source)
        let withColumn = stackedCharts(days: days, yLabelWidth: shared)
        let shared_ = wider ? try PopoverPixels.render(withColumn.cost) : try PopoverPixels.render(withColumn.source)

        XCTAssertEqual(try alone.dataLeadingEdge(), try shared_.dataLeadingEdge(), accuracy: Self.tolerance)
    }

    func testTheHorizontalLinesStopWhereTheDaysDo() throws {
        // They used to be `AxisGridLine`s, which span the whole plot — gutter
        // included — so they overhung the curve they are there to be read
        // against by the 3 pt at each end that keeps a hover dot whole. Drawn
        // as marks now, from the first day to the last.
        //
        // The first and last days' own x positions come from hovering them: the
        // rule the highlight draws is exactly where the day is.
        let days = self.days(30)
        let points = days.enumerated().map { DailyUsagePoint(day: $1, estimatedCostUSD: 3 + Double($0 % 5)) }
        let resting = try PopoverPixels.render(costChart(days: days, points: points))
        let lines = try resting.horizontalLineExtent()

        for (day, end) in [(days.first, lines.first), (days.last, lines.last)] {
            let hovered = try PopoverPixels.render(costChart(days: days, points: points, hoveredDay: day))
            let dayX = try XCTUnwrap(hovered.tallestDifference(from: resting), "hover drew nothing")
            XCTAssertEqual(dayX, end, accuracy: Self.tolerance, "a horizontal line overhangs the days it spans")
        }
    }

    func testTheHoverDotOnTodayIsDrawnWhole() throws {
        // Days sit on their own midnights, so the last of them is at the far
        // end of the scale and half its dot would hang outside a plot whose
        // range ran edge to edge — on the day most likely to be hovered.
        try assertHoverDotIsWhole(on: \.last)
    }

    func testTheHoverDotOnTheOldestDayIsDrawnWhole() throws {
        try assertHoverDotIsWhole(on: \.first)
    }

    /// Hovers the day `pick` chooses and asserts the dot reaches its full
    /// radius either side of the rule.
    ///
    /// The dot itself, measured, rather than its distance from an edge: the
    /// horizontal lines stop where the data stops now, so there is no ink in
    /// the render marking where the plot's own edge is. What matters is only
    /// ever whether the whole dot got drawn.
    private func assertHoverDotIsWhole(
        on pick: ([Date]) -> Date?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let days = self.days(30)
        let points = days.enumerated().map { DailyUsagePoint(day: $1, estimatedCostUSD: 3 + Double($0 % 5)) }
        let resting = try PopoverPixels.render(costChart(days: days, points: points))
        let hovered = try PopoverPixels.render(costChart(days: days, points: points, hoveredDay: pick(days)))

        let rule = try XCTUnwrap(hovered.tallestDifference(from: resting), "hover drew nothing", file: file, line: line)
        let extent = try XCTUnwrap(hovered.differenceExtent(from: resting), "hover drew nothing", file: file, line: line)

        // `chartHoverPointSize` is the dot's *area*, and it is centred on the
        // rule. Two pixels of slack for the anti-aliased rim.
        let radius = (PopoverMetrics.chartHoverPointSize / .pi).squareRoot() * popoverRenderScale - 2
        XCTAssertGreaterThanOrEqual(rule - extent.first, radius, "the dot is clipped on its leading side", file: file, line: line)
        XCTAssertGreaterThanOrEqual(extent.last - rule, radius, "the dot is clipped on its trailing side", file: file, line: line)
    }

    // MARK: - Seams between bands

    /// The card the dark popover is drawn on — the same fill
    /// ``ReadmeAssetRenderTests`` paints behind the content, and the one
    /// background a seam can show against: it is far darker than any band.
    private static let darkCardWhite = 0.07
    private static let darkCard = Color(white: darkCardWhite)

    /// How much darker than the palest band a pixel may be before it counts as
    /// the card showing through. Measured on this fixture: with the seams
    /// stroked the darkest pixel *inside* a stack sits just above the palest
    /// band (0.2954 against a floor of 0.2949); with the stroke removed it
    /// drops to 0.2745, a fifth of the card's own 0.07 bleeding through.
    private static let seamTolerance = 0.01

    func testNoCardShowsThroughTheSeamsBetweenStackedBands() throws {
        // Fills alone leave a hairline. Two stacked `AreaMark`s are two
        // anti-aliased paths: where they share a boundary the lower one covers
        // the edge pixel by some fraction a and the upper one by the rest, and
        // compositing them in that order leaves a(1-a) of the card visible — a
        // quarter of it at a half-covered pixel. On the dark popover that is a
        // dark, ragged line along every band edge, and it is the first thing
        // the eye finds in the rendered card.
        //
        // Every other measurement in this file is blind to it: the hover rule,
        // the dots, the gridlines' extent and the plot's leading edge are all
        // exactly where they should be, and a seam moves none of them.
        //
        // The whole popover, not a chart on its own: an isolated chart at these
        // sizes composites its bands cleanly and shows no seam at all, so a
        // fixture built out of one would pin nothing. Measured on this one,
        // removing the seam strokes puts 341 pixels below the palest band.
        let now = Date(timeIntervalSince1970: 1_756_600_000)
        let popover = PopoverView(model: .previewShowcase(now: now), clock: PopoverClock(now: now))
            .background(Self.darkCard)
        let bitmap = try PopoverPixels.render(
            popover,
            width: PopoverMetrics.popoverWidth,
            appearance: .darkAqua,
            background: Self.darkCard
        )

        // The palest band, which is the darkest ink any stack paints: both
        // charts' ramps end there whatever their band count, so one figure is
        // the floor for every boundary in the card.
        let floor = try paintedLuminance(of: PopoverMetrics.chartBandNSColor(1, of: 2))
        let bandRows = bitmap.bandRows()
        XCTAssertGreaterThan(bandRows.count, 20, "found no chart bands to measure — the fixture did not render")

        var breaches: [(x: Int, y: Int, luminance: Double)] = []
        for y in bandRows where bandRows.contains(y - 3) && bandRows.contains(y + 3) {
            for x in 0..<bitmap.width {
                // Only pixels *inside* a band: both neighbours have to be band
                // ink at full strength, which excludes the stack's own outline
                // against the card and everything the popover draws in a colour
                // of its own.
                guard bitmap.isBandInk(x, y - 3, floor: floor - Self.seamTolerance),
                      bitmap.isBandInk(x, y + 3, floor: floor - Self.seamTolerance) else { continue }
                let pixel = bitmap.luminance(x, y)
                if pixel < floor - Self.seamTolerance {
                    breaches.append((x, y, pixel))
                }
            }
        }

        let darkest = breaches.min { $0.luminance < $1.luminance }
        XCTAssertEqual(
            breaches.count,
            0,
            "the card shows through at \(breaches.count) pixels between two bands"
                + "; darkest \(darkest.map { "\($0.luminance) at \($0.x),\($0.y)" } ?? "—")"
                + " against a floor of \(floor)"
        )
    }

    /// What a band actually paints on the dark card: its own shade at
    /// ``PopoverMetrics/chartBandOpacity``, as this file's mean-of-channels
    /// luminance.
    private func paintedLuminance(of band: NSColor) throws -> Double {
        let appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = band.usingColorSpace(.sRGB)
        }
        let shade = try XCTUnwrap(resolved)
        let alpha = PopoverMetrics.chartBandOpacity
        return [shade.redComponent, shade.greenComponent, shade.blueComponent]
            .reduce(0.0) { $0 + alpha * $1 + (1 - alpha) * Self.darkCardWhite } / 3
    }

    // MARK: - Measuring a rendered chart
    // MARK: - Measuring a rendered chart

    /// Renders the same chart hovered and at rest, and asserts the stroke hover
    /// adds sits on one of the x-axis ticks.
    ///
    /// Two renders because the rule cannot be picked out of one: these are
    /// *filled* stacks, so every column inside a band is solid ink and no
    /// search for a dark column finds a line there. Differencing leaves exactly
    /// what hover drew — the rule, and the dots on it.
    private func assertRuleSitsOnATick(
        hovered: some View,
        resting: some View,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let restingBitmap = try PopoverPixels.render(resting)
        let rule = try XCTUnwrap(
            try PopoverPixels.render(hovered).tallestDifference(from: restingBitmap),
            "hover drew nothing the resting chart didn't",
            file: file,
            line: line
        )
        let ticks = try restingBitmap.axisTickColumns()
        let nearest = try XCTUnwrap(
            ticks.min { abs($0 - rule) < abs($1 - rule) },
            "found no x-axis ticks to align against",
            file: file,
            line: line
        )

        XCTAssertLessThanOrEqual(
            abs(nearest - rule),
            Self.tolerance,
            "the hover rule is at x \(rule) px and its axis tick at \(nearest) px",
            file: file,
            line: line
        )
    }
}
