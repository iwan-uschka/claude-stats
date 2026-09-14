import Accessibility
import Charts
import ClaudeStatsCore
import SwiftUI

/// A 30-day line of estimated daily spend, sized for the popover.
///
/// A line, not the stacked area the "Tokens by source" chart above it draws.
/// The shape is the point: this is one series with nothing under it, and a
/// filled band would read as a fourth source rather than as a different
/// question. The exact figure for today stays in the row beneath the plot, the
/// same division of labour the `5h` legend has on the source chart.
///
/// Interpolated `.monotone` for the reason the stacked chart is: a spline
/// through spiky daily spend overshoots, and an overshoot below the baseline
/// here draws *negative dollars* — a day Anthropic paid you. Monotone keeps
/// every segment inside its own two points, and ``Chart/chartYScale`` pins zero
/// into the domain so a flat stretch still sits visibly above the axis.
struct DailyCostChart: View {
    /// Local midnights, oldest first — the same x positions the source chart
    /// uses, so the two plots line up day for day.
    let days: [Date]

    /// One point per day of ``days``, same order.
    let points: [DailyUsagePoint]

    /// The day the pointer is on, drawn as a rule plus a dot on the curve.
    /// Ignored when it is not a day this chart plots — see
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

    /// See ``PopoverChartAxis/tickDays(in:)``. Shared with the source chart
    /// above, so two plots in the same column tick on the same days.
    var tickDays: [Date] { PopoverChartAxis.tickDays(in: days) }

    /// The dollar figures the y-axis labels, lowest first; the last is the top
    /// of the scale. See ``PopoverChartAxis/yValues(upTo:count:)``.
    var yValues: [Double] { PopoverChartAxis.yValues(upTo: points.map(\.estimatedCostUSD).max() ?? 0) }

    /// The y-axis labels, in ``yValues`` order. One unit and one decimal count
    /// for the whole column — see ``DisplayFormat/costAxisLabels(_:)``.
    var yLabels: [String] { DisplayFormat.costAxisLabels(yValues) }

    /// What this chart's own y-labels need, before the popover widens the
    /// column to whatever the chart above it needs.
    var naturalYLabelWidth: CGFloat { PopoverChartAxis.yLabelWidth(of: yLabels) }

    /// Flattened for `Chart`, which wants one record per mark.
    private struct Record: Identifiable {
        let id: Int
        let day: Date
        let cost: Double
    }

    private var records: [Record] {
        zip(days, points).enumerated().map { index, pair in
            Record(id: index, day: pair.0, cost: pair.1.estimatedCostUSD)
        }
    }

    var body: some View {
        Chart {
            ForEach(records) { record in
                // A plain date, deliberately not `unit: .day`: binning draws
                // the mark at the centre of its bin, half a day right of the
                // tick that names the day — the data is already one point per
                // local midnight with no gaps, so binning buys nothing and
                // costs the alignment. Pinned by ``PopoverChartAlignmentTests``.
                LineMark(
                    x: .value("Day", record.day),
                    y: .value("Estimated cost", record.cost)
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: PopoverMetrics.chartLineWidth, lineJoin: .round))
                // The same ink as the source chart's top band: one visual weight
                // for "this is the popover's own data", not a second palette.
                .foregroundStyle(Color.primary.opacity(DailyUsageSeries.shades[0]))
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
                        y: .value("Estimated cost", value)
                    )
                    .lineStyle(StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.secondary)
                }

            if let index = highlightedIndex {
                // Both marks carry values the chart already plots — the day is
                // one of `days`, the dollar figure is one of `points` — so
                // neither widens a scale. Nothing about the plot's geometry may
                // depend on hover: a y-scale that grew under a stationary
                // pointer would redraw the curve beneath it, and would widen
                // the y-labels with it — which slides the plot's leading edge
                // sideways, changing the day the pointer is on under the
                // user's own hand.
                RuleMark(x: .value("Day", days[index]))
                    .lineStyle(StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.primary.opacity(0.25))
                PointMark(
                    x: .value("Day", days[index]),
                    y: .value("Estimated cost", points[index].estimatedCostUSD)
                )
                .symbolSize(PopoverMetrics.chartHoverPointSize)
                .foregroundStyle(Color.primary.opacity(DailyUsageSeries.shades[0]))
            }
        }
        // Pinned to the top of ``yValues`` rather than left automatic: the axis
        // draws the values this chart measured its label column from, so the
        // scale has to end where they do. Zero is still in the domain, which is
        // what keeps a flat quiet stretch visibly above the axis.
        .chartYScale(domain: 0...(yValues.last ?? 1))
        .chartXScale(range: .plotDimension(
            startPadding: PopoverMetrics.chartXScaleEdgePadding,
            endPadding: PopoverMetrics.chartXScaleEdgePadding
        ))
        .chartXAxis {
            AxisMarks(values: tickDays) { _ in
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
        .accessibilityChartDescriptor(DailyCostChartDescriptor(days: days, points: points))
    }
}

/// VoiceOver's model of the cost chart.
///
/// A chart left as an image would announce nothing at all, and this one carries
/// a reading — thirty days of spend — that exists nowhere else in the popover;
/// the row below it gives today only.
struct DailyCostChartDescriptor: AXChartDescriptorRepresentable {
    let days: [Date]
    let points: [DailyUsagePoint]

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

        let highest = points.map(\.estimatedCostUSD).max() ?? 0
        let yAxis = AXNumericDataAxisDescriptor(
            title: "Estimated cost in US dollars",
            // Never `0...0`: an empty range is a divide-by-zero waiting to
            // happen in VoiceOver's audio graph.
            range: 0...max(highest, 1),
            gridlinePositions: []
        ) { value in
            // The framework calls this with values of its own choosing,
            // including non-finite probes — see ``DisplayFormat/compactCost(_:)``.
            DisplayFormat.compactCost(value).map { "\($0) estimated" } ?? "unknown"
        }

        return AXChartDescriptor(
            title: "Estimated cost per day, last \(days.count) days",
            summary: nil,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [
                AXDataSeriesDescriptor(
                    name: "Estimated cost",
                    isContinuous: true,
                    dataPoints: zip(categories, points).map { category, point in
                        AXDataPoint(x: category, y: point.estimatedCostUSD)
                    }
                )
            ]
        )
    }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
        // Every value here is derived from `days` and `points`, so SwiftUI
        // rebuilding this struct with new data is the whole update path.
    }
}
