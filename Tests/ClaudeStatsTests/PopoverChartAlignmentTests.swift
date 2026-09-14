import AppKit
import SwiftUI
import XCTest

@testable import ClaudeStats
@testable import ClaudeStatsCore

/// Pixels per point in every render here. File scope rather than a member, so
/// the measuring code stays off the main actor with the pixels it reads.
private let renderScale: CGFloat = 4

/// Measures where a popover chart actually puts its ink.
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
/// Rendered through an `NSHostingView` in an offscreen window, the draw path
/// ``ReadmeAssetRenderTests`` uses and the one the shipping popover takes. 4×,
/// so a tolerance under a point is still whole pixels.
@MainActor
final class PopoverChartAlignmentTests: XCTestCase {
    /// The width a chart gets in the popover. Every offset measured here is a
    /// fraction of the plot, so it has to be measured at the shipping size.
    private static let contentWidth = PopoverMetrics.popoverWidth - 2 * PopoverMetrics.contentPadding

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
        [DailyUsageSeries(label: "CLI", color: DailyUsageSeries.bandColor(0), points: points)]
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
            try render(charts.cost).dataLeadingEdge(),
            try render(charts.source).dataLeadingEdge(),
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

        let alone = wider ? try render(natural.cost) : try render(natural.source)
        let withColumn = stackedCharts(days: days, yLabelWidth: shared)
        let shared_ = wider ? try render(withColumn.cost) : try render(withColumn.source)

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
        let resting = try render(costChart(days: days, points: points))
        let lines = try resting.horizontalLineExtent()

        for (day, end) in [(days.first, lines.first), (days.last, lines.last)] {
            let hovered = try render(costChart(days: days, points: points, hoveredDay: day))
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
        let resting = try render(costChart(days: days, points: points))
        let hovered = try render(costChart(days: days, points: points, hoveredDay: pick(days)))

        let rule = try XCTUnwrap(hovered.tallestDifference(from: resting), "hover drew nothing", file: file, line: line)
        let extent = try XCTUnwrap(hovered.differenceExtent(from: resting), "hover drew nothing", file: file, line: line)

        // `chartHoverPointSize` is the dot's *area*, and it is centred on the
        // rule. Two pixels of slack for the anti-aliased rim.
        let radius = (PopoverMetrics.chartHoverPointSize / .pi).squareRoot() * renderScale - 2
        XCTAssertGreaterThanOrEqual(rule - extent.first, radius, "the dot is clipped on its leading side", file: file, line: line)
        XCTAssertGreaterThanOrEqual(extent.last - rule, radius, "the dot is clipped on its trailing side", file: file, line: line)
    }

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
        let restingBitmap = try render(resting)
        let rule = try XCTUnwrap(
            try render(hovered).tallestDifference(from: restingBitmap),
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

    /// Greyscale pixels of a chart drawn on white, and the handful of
    /// measurements this file takes off them.
    private struct Bitmap {
        let width: Int
        let height: Int
        /// 0 is black, 1 is white, row-major.
        let luminance: [Double]

        /// Faint on purpose: a gridline is drawn at 0.12 opacity, so a
        /// threshold anywhere near mid-grey would miss the plot's own edges.
        private static let inkThreshold = 0.97

        func isInk(_ x: Int, _ y: Int) -> Bool { luminance[y * width + x] < Self.inkThreshold }

        /// The x of the tallest column of pixels that differ from `other` — the
        /// hover rule, which spans the plot's whole height while the dots on it
        /// are a few rows each.
        ///
        /// The centre of the run rather than its darkest column: a 0.5 pt
        /// stroke is 2 px here and anti-aliasing spreads it over three.
        func tallestDifference(from other: Bitmap) -> CGFloat? {
            guard other.width == width, other.height == height else { return nil }
            let changed = (0..<width).map { x in
                (0..<height).reduce(0) { $0 + (abs(luminance[$1 * width + x] - other.luminance[$1 * width + x]) > 0.01 ? 1 : 0) }
            }
            let floor = height / 4
            guard let peak = changed.indices.max(by: { changed[$0] < changed[$1] }), changed[peak] > floor else { return nil }
            var left = peak, right = peak
            while left > 0, changed[left - 1] > floor { left -= 1 }
            while right < width - 1, changed[right + 1] > floor { right += 1 }
            return CGFloat(left + right) / 2
        }

        /// The leftmost and rightmost columns that differ from `other` — the
        /// full width of what hover drew, rule and dots together.
        func differenceExtent(from other: Bitmap) -> (first: CGFloat, last: CGFloat)? {
            guard other.width == width, other.height == height else { return nil }
            let changed = (0..<width).filter { x in
                (0..<height).contains { abs(luminance[$0 * width + x] - other.luminance[$0 * width + x]) > 0.01 }
            }
            guard let first = changed.first, let last = changed.last else { return nil }
            return (CGFloat(first), CGFloat(last))
        }

        /// The x each x-axis tick is centred on, left to right.
        ///
        /// Sampled from a row halfway down the ticks' own 3 pt — below the plot,
        /// above the dated labels — with everything left of the plot dropped,
        /// since the leading y-axis labels reach into those rows too.
        func axisTickColumns() throws -> [CGFloat] {
            let plot = try plotEdges()
            let row = plot.bottom + Int(PopoverMetrics.chartTickLength * renderScale) / 2
            let columns = inkColumns(inRow: row).filter { $0 >= plot.left }
            return runs(in: columns).map { CGFloat($0.first! + $0.last!) / 2 }
        }

        /// Where the plotted days start — the leading end of the horizontal
        /// lines, which run from the first day to the last.
        func dataLeadingEdge() throws -> CGFloat { CGFloat(try plotEdges().left) }

        /// Both ends of the chart's horizontal lines.
        func horizontalLineExtent() throws -> (first: CGFloat, last: CGFloat) {
            let edges = try plotEdges()
            return (CGFloat(edges.left), CGFloat(edges.right))
        }

        /// The plot's own edges and its baseline.
        ///
        /// All three read off the widest rows of ink in the image, which are
        /// the chart's horizontal lines: they run the length of the data and
        /// nothing else in the chart is that wide.
        private func plotEdges() throws -> (left: Int, right: Int, bottom: Int) {
            var widest: [Int] = []
            var bottom = 0
            for y in 0..<height {
                let columns = inkColumns(inRow: y)
                guard columns.count > width / 2 else { continue }
                if columns.count >= widest.count { widest = columns }
                bottom = max(bottom, y)
            }
            let gridline = try XCTUnwrap(runs(in: widest).max { $0.count < $1.count }, "no gridline to measure the plot by")
            return (gridline.first!, gridline.last!, bottom)
        }

        private func columnInk(_ x: Int) -> Int {
            (0..<height).reduce(0) { $0 + (isInk(x, $1) ? 1 : 0) }
        }

        private func inkColumns(inRow row: Int) -> [Int] {
            (0..<width).filter { isInk($0, row) }
        }

        /// Consecutive columns grouped, so a 2 px stroke smeared over three
        /// columns by anti-aliasing counts once.
        private func runs(in columns: [Int]) -> [[Int]] {
            columns.reduce(into: [[Int]]()) { runs, column in
                if runs.last?.last == column - 1 {
                    runs[runs.count - 1].append(column)
                } else {
                    runs.append([column])
                }
            }
        }
    }

    /// Draws `chart` at popover width on opaque white, at ``renderScale``.
    ///
    /// White and `.light` rather than the popover's own material: every mark
    /// here is `Color.primary` at some opacity, and finding a faint stroke's
    /// centre wants the most contrast available, not the shipping backdrop.
    private func render(_ chart: some View) throws -> Bitmap {
        let hosting = NSHostingView(
            rootView: chart
                .frame(width: Self.contentWidth)
                .background(Color.white)
                .environment(\.colorScheme, .light)
        )
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)

        // A window, not a bare view: AppKit resolves appearance-derived colors
        // off the window a view belongs to.
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = hosting.appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        let bounds = hosting.bounds
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((bounds.width * renderScale).rounded()),
            pixelsHigh: Int((bounds.height * renderScale).rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        // Points for `size`, pixels for the buffer — `cacheDisplay(in:to:)`
        // then draws at `scale`, the trick ``ReadmeAssetRenderTests`` uses.
        rep.size = bounds.size
        hosting.cacheDisplay(in: bounds, to: rep)

        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        let bytesPerRow = rep.bytesPerRow
        let samples = rep.samplesPerPixel
        let data = try XCTUnwrap(rep.bitmapData)
        var luminance = [Double](repeating: 1, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = data + y * bytesPerRow + x * samples
                luminance[y * width + x] = Double(Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / (3 * 255)
            }
        }
        return Bitmap(width: width, height: height, luminance: luminance)
    }
}
