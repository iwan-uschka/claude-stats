import Accessibility
import AppKit
import Charts
import ClaudeStatsCore
import SwiftUI

/// One stacked band of a ``DailyUsageChart``.
struct DailyUsageSeries: Identifiable, Hashable {
    /// Stable key, also the value the chart's style scale is keyed by. Uses the
    /// label rather than a synthetic id so `chartForegroundStyleScale` and the
    /// legend can't drift apart.
    var id: String { label }

    /// Row label, e.g. `CLI` — the same string the legend shows.
    let label: String

    /// Opacity applied to the popover's primary ink. The chart is monochrome on
    /// purpose: the rest of the popover carries colour only for warnings and
    /// the one brand link, and three hues for three sources would make the
    /// section shout louder than the quota bars above it.
    let shade: Double

    /// One point per day of ``DailyUsageChart/days``, same order.
    let points: [DailyUsagePoint]

    /// The popover's chart ink, darkest first. Shared so a second chart can say
    /// "the same weight as the source chart's top band" by construction rather
    /// than by repeating a number.
    static let shades: [Double] = [0.62, 0.40, 0.24]

    /// Ordered bands for the "Tokens by source" chart: display order, darkest
    /// band first, including sources that did nothing in the window.
    static func sources(from history: DailyUsageHistory) -> [DailyUsageSeries] {
        let shades = Self.shades
        return Entrypoint.displayOrder.enumerated().map { index, entrypoint in
            DailyUsageSeries(
                label: entrypoint.displayName,
                shade: shades[index % shades.count],
                points: history.bySource[entrypoint] ?? []
            )
        }
    }
}

/// A stacked 30-day area chart of daily token usage, sized for the popover.
///
/// Both axes are drawn: without a y-axis the bands show shape but no
/// magnitude, and without dated x-ticks a spike can't be tied to a day. Ticks
/// are sparse on purpose — a label every seven days, three or four round
/// values up the y-axis
/// — because thirty dated labels across a 340 pt popover would be unreadable
/// mush. Exact per-source numbers stay in the legend under the chart.
struct DailyUsageChart: View {
    /// Local midnights, oldest first — the x positions every series shares.
    let days: [Date]

    /// Stack order, bottom band first.
    let series: [DailyUsageSeries]

    /// The day the pointer is on, drawn as a rule across the stack. Ignored
    /// when it is not a day this chart plots — see
    /// ``PopoverChartHover/index(of:in:)``.
    var hoveredDay: Date?

    /// Reports the day under the pointer, `nil` on exit. Defaulted so a chart
    /// built for a test or a preview needs neither.
    var onHover: (Date?) -> Void = { _ in }

    /// Width of the y-label column, shared with the other popover chart so the
    /// two plots start at the same x — see ``ChartYLabelWidthKey``. `nil` lets
    /// each label take its own width, which is the first frame and every chart
    /// built for a test or a preview.
    var yLabelWidth: CGFloat?

    /// The hovered day's position in ``days``, or `nil` when the pointer is
    /// out, or when a reload moved the window under it.
    var highlightedIndex: Int? { PopoverChartHover.index(of: hoveredDay, in: days) }

    /// Flattened for `Chart`, which wants one record per mark.
    private struct Record: Identifiable {
        let id: String
        let series: String
        let day: Date
        let tokens: Int
    }

    private var records: [Record] {
        series.flatMap { band in
            zip(days, band.points).enumerated().map { index, pair in
                Record(id: "\(band.label)-\(index)", series: band.label, day: pair.0, tokens: pair.1.totalTokens)
            }
        }
    }

    /// The top edge of one band on one day — where its highlight dot goes.
    struct StackTop: Identifiable, Equatable {
        /// The band's label, so `ForEach` has a stable key.
        let id: String
        /// The band's *cumulative* height, not its own.
        let tokens: Int
    }

    /// Where each band ends on the hovered day, bottom band first.
    ///
    /// Cumulative sums, because the areas stack: a dot at a band's own token
    /// count would float somewhere inside the stack rather than sitting on the
    /// edge the chart draws.
    ///
    /// A band that did nothing that day is skipped. Its edge is its
    /// neighbour's, so its dot would land exactly on top of another one and
    /// darken it for no reading — and a silent source is a case the popover
    /// shows rather than drops, so this is not hypothetical.
    func stackTops(at index: Int) -> [StackTop] {
        var running = 0
        return series.compactMap { band in
            guard index < band.points.count else { return nil }
            let tokens = band.points[index].totalTokens
            running += tokens
            guard tokens > 0 else { return nil }
            return StackTop(id: band.label, tokens: running)
        }
    }

    /// See ``PopoverChartAxis/tickDays(in:)``.
    var tickDays: [Date] { PopoverChartAxis.tickDays(in: days) }

    /// The tallest day in the window — the *stack's* height, not the tallest
    /// single band, since the bands sit on each other.
    var stackedMaximum: Int {
        let dayCount = series.map(\.points.count).max() ?? 0
        return (0..<dayCount).map { day in
            series.reduce(0) { $0 + (day < $1.points.count ? $1.points[day].totalTokens : 0) }
        }.max() ?? 0
    }

    /// The token counts the y-axis labels, lowest first; the last is the top of
    /// the scale. See ``PopoverChartAxis/yValues(upTo:count:)``.
    var yValues: [Int] { PopoverChartAxis.yValues(upTo: Double(stackedMaximum)).map { Int($0.rounded()) } }

    /// The y-axis labels, in ``yValues`` order. One unit and one decimal count
    /// for the whole column — see ``DisplayFormat/tokenAxisLabels(_:)``.
    var yLabels: [String] { DisplayFormat.tokenAxisLabels(yValues) }

    /// What this chart's own y-labels need, before the popover widens the
    /// column to whatever the chart below it needs.
    var naturalYLabelWidth: CGFloat { PopoverChartAxis.yLabelWidth(of: yLabels) }

    var body: some View {
        Chart {
            ForEach(records) { record in
                // A plain date, deliberately not `unit: .day`: binning draws
                // the mark at the centre of its bin, half a day right of the
                // tick that names the day — the data is already one point per
                // local midnight with no gaps, so binning buys nothing and
                // costs the alignment. Pinned by ``PopoverChartAlignmentTests``.
                AreaMark(
                    x: .value("Day", record.day),
                    y: .value("Tokens", record.tokens)
                )
                .foregroundStyle(by: .value("Source", record.series))
                // Monotone, not `catmullRom`: a spline through spiky daily counts
                // overshoots, and on a stacked band an overshoot dips below the band
                // underneath it — drawing usage that never happened. Monotone keeps
                // every segment within its own two points.
                .interpolationMethod(.monotone)
            }

                // The horizontal lines, drawn as marks rather than as
                // `AxisGridLine`s: a gridline spans the whole plot, including
                // the gutter the x scale keeps at each end, so it overhangs the
                // data it is there to be read against. These end exactly where
                // the first and last day do.
                //
                // After the data and before the highlight: the same order the
                // axis drew them in — over the bands, under the hovered day.
                ForEach(yValues, id: \.self) { value in
                    RuleMark(
                        xStart: .value("Day", days.first ?? Date()),
                        xEnd: .value("Day", days.last ?? Date()),
                        y: .value("Tokens", value)
                    )
                    .lineStyle(StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.secondary)
                }

            if let index = highlightedIndex {
                // Every mark here carries a value the chart already plots — the
                // day is one of `days`, each dot sits on a band edge the stack
                // already draws — so no scale widens and no axis moves.
                RuleMark(x: .value("Day", days[index]))
                    .lineStyle(StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.primary.opacity(0.25))
                ForEach(stackTops(at: index)) { top in
                    PointMark(
                        x: .value("Day", days[index]),
                        y: .value("Tokens", top.tokens)
                    )
                    .symbolSize(PopoverMetrics.chartHoverPointSize)
                    // One ink for all three, not each band's own shade: the
                    // top band is drawn at 0.24 opacity, and a dot that pale
                    // sitting on its own band is invisible. The dots are
                    // markers, not more data — the same weight the cost
                    // chart's single dot carries.
                    .foregroundStyle(Color.primary.opacity(DailyUsageSeries.shades[0]))
                }
            }
        }
        .chartForegroundStyleScale(
            domain: series.map(\.label),
            range: series.map { Color.primary.opacity($0.shade) }
        )
        .chartLegend(.hidden)
        // The axis draws the values this chart measured its label column from,
        // so the scale has to end where they do.
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
        .accessibilityChartDescriptor(DailyUsageChartDescriptor(days: days, series: series))
    }
}

/// VoiceOver's model of the chart — the audio graph and per-point readout that
/// replaces the per-cell labels the "This Mac" table used to carry.
///
/// Not decorative: a chart left as an image would silently drop every number
/// the table used to announce, which is a regression rather than a redesign.
struct DailyUsageChartDescriptor: AXChartDescriptorRepresentable {
    let days: [Date]
    let series: [DailyUsageSeries]

    /// Short, spoken-friendly day labels (`Sep 13`).
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    func makeChartDescriptor() -> AXChartDescriptor {
        let categories = days.map { Self.dayFormatter.string(from: $0) }
        let xAxis = AXCategoricalDataAxisDescriptor(
            title: "Day",
            categoryOrder: categories
        )

        // The bands stack, so the axis has to reach the tallest *day*, not the
        // tallest single band — otherwise VoiceOver's audio graph scales every
        // reading against a ceiling the chart visibly exceeds.
        let dayCount = series.map(\.points.count).max() ?? 0
        let highest = (0..<dayCount).map { day in
            series.reduce(0) { $0 + (day < $1.points.count ? $1.points[day].totalTokens : 0) }
        }.max() ?? 0
        let yAxis = AXNumericDataAxisDescriptor(
            title: "Tokens",
            range: 0...Double(max(highest, 1)),
            gridlinePositions: []
        ) { value in
            // The framework calls this with values of its own choosing, which
            // can include a non-finite probe — `Int(Double)` traps on those, so
            // this must not convert blind.
            guard value.isFinite else { return "unknown" }
            return "\(DisplayFormat.tokens(Int(value.clampedToRepresentableCount()))) tokens"
        }

        let descriptors = series.map { band in
            AXDataSeriesDescriptor(
                name: band.label,
                isContinuous: true,
                dataPoints: zip(categories, band.points).map { category, point in
                    AXDataPoint(x: category, y: Double(point.totalTokens))
                }
            )
        }

        return AXChartDescriptor(
            title: "Token usage by source, last \(days.count) days",
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
