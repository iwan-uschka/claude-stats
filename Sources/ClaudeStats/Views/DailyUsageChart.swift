import Accessibility
import AppKit
import Charts
import ClaudeStatsCore
import SwiftUI

/// What a popover chart plots off a ``DailyUsagePoint``.
///
/// One chart type draws both of the popover's blocks — "By source" stacks
/// tokens, "By model" stacks the money those tokens are estimated to have cost.
/// The shapes are identical (thirty dense daily points per band, stacked, over
/// one shared x-axis), and the only things that differ are which field of a
/// point is read and how the y-axis spells it. A second 300-line chart type for
/// that would be two places to fix every alignment bug.
enum DailyUsageMetric {
    case tokens
    case cost

    /// The number this metric reads out of one day of one band.
    func value(of point: DailyUsagePoint) -> Double {
        switch self {
        case .tokens: return Double(point.totalTokens)
        case .cost: return point.estimatedCostUSD
        }
    }

    /// The y-axis labels for `values`, in order. One unit and one decimal count
    /// for the whole column either way — see ``DisplayFormat/tokenAxisLabels(_:)``
    /// and ``DisplayFormat/costAxisLabels(_:)``.
    func axisLabels(_ values: [Double]) -> [String] {
        switch self {
        case .tokens: return DisplayFormat.tokenAxisLabels(values.map { Int($0.rounded()) })
        case .cost: return DisplayFormat.costAxisLabels(values)
        }
    }

    /// What the mark's y value is called inside `Chart` — the plottable's own
    /// label, which VoiceOver falls back on.
    var markLabel: String {
        switch self {
        case .tokens: return "Tokens"
        case .cost: return "Estimated cost"
        }
    }

    /// The ``AXNumericDataAxisDescriptor`` title. Spelled out for cost, because
    /// VoiceOver reads it with no visual context and `$` is not spoken.
    var axisTitle: String {
        switch self {
        case .tokens: return "Tokens"
        case .cost: return "Estimated cost in US dollars"
        }
    }

    /// The leading half of the chart's spoken title, e.g. `Token usage by
    /// source, last 30 days`.
    var chartTitle: String {
        switch self {
        case .tokens: return "Token usage"
        case .cost: return "Estimated cost"
        }
    }

    /// How VoiceOver reads one value off the y-axis.
    ///
    /// Both branches guard the framework's own probe values: `AXChartDescriptor`
    /// calls this with numbers of its choosing, and both a non-finite `Int(_:)`
    /// conversion and a `%f` of `greatestFiniteMagnitude` were live failures
    /// here — the first a trap, the second a 300-digit label that renders.
    func describe(_ value: Double) -> String {
        switch self {
        case .tokens:
            guard value.isFinite else { return "unknown" }
            return "\(DisplayFormat.tokens(Int(value.clampedToRepresentableCount()))) tokens"
        case .cost:
            return DisplayFormat.compactCost(value).map { "\($0) estimated" } ?? "unknown"
        }
    }
}

/// One stacked band of a ``DailyUsageChart``, and one row of the table under it.
struct DailyUsageSeries: Identifiable, Hashable {
    /// Stable key, also the value the chart's style scale is keyed by. Uses the
    /// label rather than a synthetic id so `chartForegroundStyleScale` and the
    /// table can't drift apart.
    var id: String { label }

    /// Row label, e.g. `CLI` or `Sonnet` — the same string the table shows.
    let label: String

    /// This band's ink — one shade of ``PopoverMetrics/brandColor``, from
    /// ``PopoverMetrics/chartBandColor(_:of:)`` by position in the band list.
    /// Shades of the one brand hue rather than a hue per band: colour anywhere
    /// else in this popover means Claude, and a five-colour chart would make
    /// the section shout louder than the quota bars above it.
    let color: Color

    /// One point per day of ``DailyUsageChart/days``, same order.
    let points: [DailyUsagePoint]

    /// The band ink for row `index` of a `count`-band block, strongest first.
    ///
    /// `count` is part of the question, not a detail: the ramp spreads whatever
    /// it is handed across its whole bounded range, so three bands sit much
    /// further apart than three of five fixed steps did — see
    /// ``PopoverMetrics/chartBandColor(_:of:)``.
    static func bandColor(_ index: Int, of count: Int) -> Color {
        PopoverMetrics.chartBandColor(index, of: count)
    }

    /// Label for the band carrying whatever this version doesn't recognise —
    /// an unknown `entrypoint` in "By source", an unknown model ID in "By
    /// model". One label for both, because it is the same bucket in both: the
    /// remainder that would otherwise make the stack fall short of the total.
    static let otherBandLabel = "Other"

    /// The sources the "By source" bands stand for, in table order: display
    /// order, then the unrecognised bucket — `nil` — when the window has one.
    ///
    /// "Other" goes last, i.e. the last table row and the *bottom* of the
    /// stack: the named sources are what a reader is looking for, and a bucket
    /// that can appear and vanish between two polls must not shuffle the bands
    /// beside it when it does.
    ///
    /// Published separately from ``sources(from:)`` because a caller may need
    /// the entrypoint *and* the band, and zipping the band list against
    /// ``Entrypoint/displayOrder`` silently drops whichever of the two is
    /// shorter — which is exactly what an "Other" band makes them.
    static func sourceKeys(in history: DailyUsageHistory) -> [Entrypoint?] {
        let known: [Entrypoint?] = Entrypoint.displayOrder.map { $0 }
        return history.bySource[Entrypoint?.none] == nil ? known : known + [nil]
    }

    /// Ordered bands for the "By source" block: ``sourceKeys(in:)``, strongest
    /// shade first, including sources that did nothing in the window.
    static func sources(from history: DailyUsageHistory) -> [DailyUsageSeries] {
        bands(keys: sourceKeys(in: history)) { key in
            (key?.displayName ?? otherBandLabel, history.bySource[key] ?? [])
        }
    }

    /// The model families the "By model" bands stand for, in table order.
    ///
    /// Filtered to the families the window actually holds, unlike
    /// ``sourceKeys(in:)`` which keeps a silent source. The asymmetry follows
    /// the data: ``DailyUsageHistory/bySource`` is dense over
    /// ``Entrypoint/allCases`` because "VS Code: 0" is a reading about a tool
    /// the user either uses or doesn't, while ``DailyUsageHistory/byModelFamily``
    /// carries only families that appear — a zero row for a model Anthropic
    /// ships but this account never touches says nothing.
    static func modelKeys(in history: DailyUsageHistory) -> [ModelFamily?] {
        let known: [ModelFamily?] = ModelFamily.displayOrder
            .filter { history.byModelFamily[$0] != nil }
            .map { $0 }
        return history.byModelFamily[ModelFamily?.none] == nil ? known : known + [nil]
    }

    /// Ordered bands for the "By model" block — ``modelKeys(in:)`` against the
    /// same ramp, taken in the same order, so a dot means the same thing in
    /// both tables.
    static func models(from history: DailyUsageHistory) -> [DailyUsageSeries] {
        bands(keys: modelKeys(in: history)) { key in
            (key?.displayName ?? otherBandLabel, history.byModelFamily[key] ?? [])
        }
    }

    /// Shared band construction: the ramp is indexed by row position *and*
    /// handed the row count, which is the one rule both splits have to follow
    /// identically — a three-band block and a five-band block do not draw the
    /// same three shades.
    private static func bands<Key>(
        keys: [Key],
        resolve: (Key) -> (label: String, points: [DailyUsagePoint])
    ) -> [DailyUsageSeries] {
        keys.enumerated().map { index, key in
            let band = resolve(key)
            return DailyUsageSeries(
                label: band.label,
                color: bandColor(index, of: keys.count),
                points: band.points
            )
        }
    }
}

extension Array where Element == DailyUsageSeries {
    /// The tallest day across all bands, stacked — not the tallest single band,
    /// since the bands sit on each other.
    ///
    /// One implementation because two consumers scale against it: the visible
    /// y-axis and the accessibility descriptor's audio graph. Computed twice,
    /// a change to how the height is measured could be applied to one copy and
    /// silently leave VoiceOver reading against a ceiling the chart exceeds.
    func stackedMaximum(metric: DailyUsageMetric) -> Double {
        let dayCount = map(\.points.count).max() ?? 0
        return (0..<dayCount).map { day in
            reduce(0.0) { $0 + (day < $1.points.count ? metric.value(of: $1.points[day]) : 0) }
        }.max() ?? 0
    }
}

/// A stacked 30-day area chart of one daily metric, sized for the popover.
///
/// Both axes are drawn: without a y-axis the bands show shape but no
/// magnitude, and without dated x-ticks a spike can't be tied to a day. Ticks
/// are sparse on purpose — a label every seven days, three or four round
/// values up the y-axis — because thirty dated labels across a 340 pt popover
/// would be unreadable mush. Exact per-band numbers stay in the table under the
/// chart.
struct DailyUsageChart: View {
    /// Local midnights, oldest first — the x positions every series shares.
    let days: [Date]

    /// The bands in *table* order — first row first, which is the **top** of
    /// the stack. See ``stackOrder``.
    let series: [DailyUsageSeries]

    /// Which field of a day this chart plots, and how its axis spells it.
    var metric: DailyUsageMetric = .tokens

    /// What the bands are a split of, for the spoken chart title: `source`,
    /// `model`. Only VoiceOver sees it — the section title says it on screen.
    var bandsName: String = "source"

    /// The day the pointer is on, drawn as a rule across the stack. Ignored
    /// when it is not a day this chart plots — see
    /// ``PopoverChartHover/index(of:in:)``.
    var hoveredDay: Date?

    /// Reports the day under the pointer, `nil` on exit. Defaulted so a chart
    /// built for a test or a preview needs neither.
    var onHover: (Date?) -> Void = { _ in }

    /// Width of the y-label column, shared with the other popover chart so the
    /// two plots start at the same x. `nil` lets each label take its own width,
    /// which is the first frame and every chart built for a test or a preview.
    var yLabelWidth: CGFloat?

    /// The hovered day's position in ``days``, or `nil` when the pointer is
    /// out, or when a reload moved the window under it.
    var highlightedIndex: Int? { PopoverChartHover.index(of: hoveredDay, in: days) }

    /// The bands bottom-first, which is the order Swift Charts stacks them in
    /// and the reverse of ``series``.
    ///
    /// The flip is deliberate and it is the *stack* that moved, not the table.
    /// A table reads downwards from its first row, a stack reads downwards from
    /// its top band, and with the first band at the bottom those two sequences
    /// were mirror images: row one pointed at the band furthest from it. Now
    /// row one is the top band, so the eye crosses the plot and the rows in the
    /// same direction, and "Other" — last in display order because it can
    /// appear between two polls — lands at the bottom of the stack where it
    /// shuffles nothing above it.
    ///
    /// Reversing here rather than in `Entrypoint.displayOrder` or
    /// ``DailyUsageSeries/sourceKeys(in:)``: display order is what the tables,
    /// the ramp positions and VoiceOver all read, and only the chart's own
    /// stacking is upside down relative to it.
    var stackOrder: [DailyUsageSeries] { series.reversed() }

    /// Flattened for `Chart`, which wants one record per mark.
    private struct Record: Identifiable {
        let id: String
        let series: String
        let day: Date
        let value: Double
    }

    /// One record per band per day, bottom band first — Swift Charts stacks an
    /// `AreaMark` in the order its series appear, so this order *is* the stack.
    private var records: [Record] {
        stackOrder.flatMap { band in
            zip(days, band.points).enumerated().map { index, pair in
                Record(id: "\(band.label)-\(index)", series: band.label, day: pair.0, value: metric.value(of: pair.1))
            }
        }
    }

    /// One band's cumulative top edge, as a polyline the band strokes over its
    /// own boundary.
    private struct Seam: Identifiable {
        let id: String
        let color: Color
        let points: [Point]

        struct Point: Identifiable {
            var id: Int { index }
            let index: Int
            let day: Date
            let value: Double
        }
    }

    /// The edge every band shares with the one above it, one polyline each.
    ///
    /// Fills alone leave a seam: each band is its own anti-aliased path, so at
    /// a shared boundary both paths cover the edge pixel about half and the
    /// card behind shows through as a dark, ragged hairline — visible on the
    /// dark popover, where the card is much darker than any band. Stroking each
    /// band's own top edge in its own ink covers it. Same
    /// ``PopoverMetrics/chartBandOpacity`` and same `.monotone` interpolation as
    /// the fill, or the stroke would sit beside the curve rather than on it.
    ///
    /// Cumulative, for the same reason ``stackTops(at:)`` is: the boundary a
    /// band is drawn at is the sum of every band under it.
    private var seams: [Seam] {
        var running = [Double](repeating: 0, count: days.count)
        return stackOrder.map { band in
            let points = zip(days, band.points).enumerated().map { index, pair -> Seam.Point in
                running[index] += metric.value(of: pair.1)
                return Seam.Point(index: index, day: pair.0, value: running[index])
            }
            return Seam(id: band.label, color: band.color, points: points)
        }
    }

    /// The top edge of one band on one day — where its highlight dot goes.
    struct StackTop: Identifiable, Equatable {
        /// The band's label, so `ForEach` has a stable key.
        let id: String
        /// The band's *cumulative* height, not its own.
        let value: Double
    }

    /// Where each band ends on the hovered day, bottom band first — i.e. in
    /// ``stackOrder``, not in table order.
    ///
    /// Cumulative sums, because the areas stack: a dot at a band's own value
    /// would float somewhere inside the stack rather than sitting on the edge
    /// the chart draws. The running total has to climb the stack in the order
    /// the stack is *drawn*, or every dot but the topmost lands on a boundary
    /// that isn't there.
    ///
    /// A band that did nothing that day is skipped. Its edge is its
    /// neighbour's, so its dot would land exactly on top of another one and
    /// darken it for no reading — and a silent source is a case the popover
    /// shows rather than drops, so this is not hypothetical.
    func stackTops(at index: Int) -> [StackTop] {
        var running = 0.0
        return stackOrder.compactMap { band in
            guard index < band.points.count else { return nil }
            let value = metric.value(of: band.points[index])
            running += value
            guard value > 0 else { return nil }
            return StackTop(id: band.label, value: running)
        }
    }

    /// See ``PopoverChartAxis/tickDays(in:)``.
    var tickDays: [Date] { PopoverChartAxis.tickDays(in: days) }

    /// The tallest day in the window — see `stackedMaximum(metric:)` on the
    /// band array, which the accessibility descriptor scales against too.
    var stackedMaximum: Double { series.stackedMaximum(metric: metric) }

    /// The values the y-axis labels, lowest first; the last is the top of the
    /// scale. See ``PopoverChartAxis/yValues(upTo:count:)``.
    var yValues: [Double] { PopoverChartAxis.yValues(upTo: stackedMaximum) }

    /// The y-axis labels, in ``yValues`` order.
    var yLabels: [String] { metric.axisLabels(yValues) }

    /// What this chart's own y-labels need, before the popover widens the
    /// column to whatever the other chart needs.
    var naturalYLabelWidth: CGFloat { PopoverChartAxis.yLabelWidth(of: yLabels) }

    var body: some View {
        Chart {
            // The horizontal lines, drawn as marks rather than as
            // `AxisGridLine`s: a gridline spans the whole plot, including the
            // gutter the x scale keeps at each end, so it overhangs the data it
            // is there to be read against. These end exactly where the first
            // and last day do.
            //
            // *Behind* the bands, which is why the bands are painted at
            // ``PopoverMetrics/chartBandOpacity`` — a gridline the stack cuts
            // off can only be followed in the empty region above the plot's
            // tallest day, and a reader taking a value off a spike is reading
            // exactly where the stack is. At 0.85 the line stays visible
            // through a band without competing with it.
            ForEach(yValues, id: \.self) { value in
                RuleMark(
                    xStart: .value("Day", days.first ?? Date()),
                    xEnd: .value("Day", days.last ?? Date()),
                    y: .value(metric.markLabel, value)
                )
                .lineStyle(StrokeStyle(lineWidth: 0.5))
                .foregroundStyle(.secondary)
            }

            ForEach(records) { record in
                // A plain date, deliberately not `unit: .day`: binning draws
                // the mark at the centre of its bin, half a day right of the
                // tick that names the day — the data is already one point per
                // local midnight with no gaps, so binning buys nothing and
                // costs the alignment. Pinned by ``PopoverChartAlignmentTests``.
                AreaMark(
                    x: .value("Day", record.day),
                    y: .value(metric.markLabel, record.value)
                )
                .foregroundStyle(by: .value("Band", record.series))
                // Monotone, not `catmullRom`: a spline through spiky daily counts
                // overshoots, and on a stacked band an overshoot dips below the band
                // underneath it — drawing usage that never happened, or on the cost
                // stack a day Anthropic paid you. Monotone keeps every segment
                // within its own two points.
                .interpolationMethod(.monotone)
                .opacity(PopoverMetrics.chartBandOpacity)
            }

            // The seam strokes, over the fills and under the highlight — see
            // ``seams``. An explicit `series:` per band, or Swift Charts would
            // join every band's edge into one polyline; an explicit
            // `foregroundStyle`, so they stay out of the style scale's domain
            // and out of the legend.
            ForEach(seams) { seam in
                ForEach(seam.points) { point in
                    LineMark(
                        x: .value("Day", point.day),
                        y: .value(metric.markLabel, point.value),
                        series: .value("Seam", seam.id)
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: PopoverMetrics.chartBandSeamWidth))
                    .foregroundStyle(seam.color)
                    .opacity(PopoverMetrics.chartBandOpacity)
                }
            }

            if let index = highlightedIndex {
                // Every mark here carries a value the chart already plots — the
                // day is one of `days`, each dot sits on a band edge the stack
                // already draws — so no scale widens and no axis moves. That is
                // not cosmetic: a y-scale that grew under a stationary pointer
                // would redraw the bands beneath it and drag the plot's leading
                // edge sideways, changing the day the pointer is on under the
                // user's own hand.
                RuleMark(x: .value("Day", days[index]))
                    .lineStyle(StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.primary.opacity(0.25))
                ForEach(stackTops(at: index)) { top in
                    PointMark(
                        x: .value("Day", days[index]),
                        y: .value(metric.markLabel, top.value)
                    )
                    .symbolSize(PopoverMetrics.chartHoverPointSize)
                    // Plain primary ink, not any band's own shade: a dot has to
                    // read against whichever band it lands on, and the palest
                    // one is drawn at ≈1.8:1 against the card. The dots are
                    // markers, not more data — which is also why they are the
                    // one thing in these charts that is not terracotta.
                    .foregroundStyle(Color.primary)
                }
            }
        }
        // Domain in ``stackOrder`` too, not just the records: Swift Charts
        // takes the stacking order from the style scale's domain as well as
        // from the order the marks arrive in, and the two disagreeing is a
        // stack whose bands don't match their own colours.
        .chartForegroundStyleScale(
            domain: stackOrder.map(\.label),
            range: stackOrder.map(\.color)
        )
        .chartLegend(.hidden)
        // The axis draws the values this chart measured its label column from,
        // so the scale has to end where they do. Zero stays in the domain,
        // which is what keeps a quiet stretch visibly above the axis.
        .chartYScale(domain: 0...(yValues.last ?? 1))
        .chartXScale(range: .plotDimension(
            startPadding: PopoverMetrics.chartXScaleEdgePadding,
            endPadding: PopoverMetrics.chartXScaleEdgePadding
        ))
        .chartXAxis {
            AxisMarks(values: tickDays) { value in
                AxisTick(length: PopoverMetrics.chartTickLength, stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.primary)
                AxisValueLabel(format: PopoverChartHover.dayLabelFormat)
                    .font(PopoverMetrics.captionFont)
                    .foregroundStyle(.primary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: yValues) { value in
                AxisValueLabel {
                    Text(yLabels.indices.contains(value.index) ? yLabels[value.index] : "")
                        .font(PopoverMetrics.captionFont)
                        .foregroundStyle(.primary)
                        .frame(width: yLabelWidth, alignment: .trailing)
                }
            }
        }
        .frame(height: PopoverMetrics.chartHeight)
        .chartHoverTracking(days: days, onHover: onHover)
        .accessibilityChartDescriptor(DailyUsageChartDescriptor(
            days: days,
            series: series,
            metric: metric,
            bandsName: bandsName
        ))
    }
}

/// VoiceOver's model of a popover chart — the audio graph and per-point readout
/// that replaces the numbers a table of every day would have announced.
///
/// Not decorative: a chart left as an image would silently drop thirty days of
/// readings that exist nowhere else in the popover, since the table beneath it
/// reads one window or one day.
struct DailyUsageChartDescriptor: AXChartDescriptorRepresentable {
    let days: [Date]
    let series: [DailyUsageSeries]
    var metric: DailyUsageMetric = .tokens
    var bandsName: String = "source"

    func makeChartDescriptor() -> AXChartDescriptor {
        // The same spelling the axis ticks and the hover readout use — a
        // second formatter here would let VoiceOver announce a day differently
        // from how the chart prints it in any locale where the two APIs
        // disagree on abbreviation, order, or separator.
        let categories = days.map(PopoverChartHover.label(for:))
        let xAxis = AXCategoricalDataAxisDescriptor(
            title: "Day",
            categoryOrder: categories
        )

        // The bands stack, so the axis has to reach the tallest *day*, not the
        // tallest single band — otherwise VoiceOver's audio graph scales every
        // reading against a ceiling the chart visibly exceeds.
        let highest = series.stackedMaximum(metric: metric)
        let yAxis = AXNumericDataAxisDescriptor(
            title: metric.axisTitle,
            // Never `0...0`: an empty range is a divide-by-zero waiting to
            // happen in VoiceOver's audio graph.
            range: 0...max(highest, 1),
            gridlinePositions: []
        ) { value in
            metric.describe(value)
        }

        let descriptors = series.map { band in
            AXDataSeriesDescriptor(
                name: band.label,
                isContinuous: true,
                dataPoints: zip(categories, band.points).map { category, point in
                    AXDataPoint(x: category, y: metric.value(of: point))
                }
            )
        }

        return AXChartDescriptor(
            title: "\(metric.chartTitle) by \(bandsName), last \(days.count) days",
            summary: nil,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: descriptors
        )
    }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
        // Every value here is derived from `days` and `series`, so SwiftUI
        // rebuilding this struct with new data is the whole update path.
    }
}

/// X-axis rules shared by every dated chart in the popover, so two charts
/// stacked in the same column can't end up ticking on different days.
enum PopoverChartAxis {
    /// Days that get an x-axis tick: every seventh, stopping short of the
    /// window's right edge so no label is truncated there. Always at least one
    /// tick, so a corpus shorter than the margin still dates its chart.
    static func tickDays(in days: [Date]) -> [Date] {
        guard let first = days.first else { return [] }
        let last = days.count - 1 - PopoverMetrics.chartXAxisEdgeMarginDays
        guard last > 0 else { return [first] }
        return stride(from: 0, through: last, by: PopoverMetrics.chartXAxisStrideDays).map { days[$0] }
    }

    /// Round values for a y-axis running from zero up past `max`, lowest first.
    /// The last is the domain's top, which is why it is always above the data.
    ///
    /// Chosen here rather than left to `.automatic(desiredCount:)` for one
    /// reason: the popover has to *know* the labels. Both charts set their
    /// y-labels in one shared column, sized to the widest label on screen so
    /// the two plots start at the same x — and a width can only be measured
    /// from strings, which means knowing the values before the chart draws
    /// them. `ChartProxy` won't say, and a preference set inside
    /// `AxisValueLabel` does not escape the `Chart` (tried, measured: it
    /// arrives as zero).
    ///
    /// The step is the first of 1, 2, 2.5, 5 × 10ⁿ that is at least
    /// `max / count`, and the top rounds `max` up to a multiple of it — which
    /// is what Swift Charts was picking anyway for the spend chart (`$0` to
    /// `$6` in twos, over a $5.20 day).
    static func yValues(upTo max: Double, count: Int = PopoverMetrics.chartYAxisTickCount) -> [Double] {
        // An empty window, or a day that spent nothing: label zero and one, so
        // the axis still has a scale rather than a degenerate `0...0` domain.
        guard max > 0, count > 0 else { return [0, 1] }

        let rough = max / Double(count)
        let magnitude = pow(10, (log10(rough)).rounded(.down))
        let step = [1.0, 2.0, 2.5, 5.0, 10.0]
            .map { $0 * magnitude }
            .first { $0 >= rough } ?? magnitude * 10
        let top = (max / step).rounded(.up) * step
        return stride(from: 0, through: top + step / 2, by: step).map { Swift.min($0, top) }
    }

    /// Width of the widest label in `labels`, in the font the axis draws them.
    static func yLabelWidth(of labels: [String]) -> CGFloat {
        labels
            .map { ($0 as NSString).size(withAttributes: [.font: PopoverMetrics.captionNSFont]).width }
            .max() ?? 0
    }
}

private extension Double {
    /// Round to a whole number `Int(_:)` is guaranteed to accept.
    ///
    /// Not clamped to `Double(Int.max)`: that constant rounds *up* to 2^63,
    /// which `Int` cannot hold, so clamping to it still traps — which is
    /// exactly what `.greatestFiniteMagnitude` did here. 2^53 is the largest
    /// integer a `Double` represents exactly, and is some six orders of
    /// magnitude past any token count this will ever be handed.
    func clampedToRepresentableCount() -> Double {
        let limit = 9_007_199_254_740_992.0  // 2^53
        return Swift.min(Swift.max(self.rounded(), 0), limit)
    }
}
