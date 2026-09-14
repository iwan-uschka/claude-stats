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

    /// The hovered day's position in ``days``, or `nil` when the pointer is
    /// out, or when a reload moved the window under it.
    var highlightedIndex: Int? { PopoverChartHover.index(of: hoveredDay, in: days) }

    /// See ``PopoverChartAxis/tickDays(in:)``. Shared with the source chart
    /// above, so two plots in the same column tick on the same days.
    var tickDays: [Date] { PopoverChartAxis.tickDays(in: days) }

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
                LineMark(
                    x: .value("Day", record.day, unit: .day),
                    y: .value("Estimated cost", record.cost)
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: PopoverMetrics.chartLineWidth, lineJoin: .round))
                // The same ink as the source chart's top band: one visual weight
                // for "this is the popover's own data", not a second palette.
                .foregroundStyle(Color.primary.opacity(DailyUsageSeries.shades[0]))
            }

            if let index = highlightedIndex {
                // Both marks carry values the chart already plots — the day is
                // one of `days`, the dollar figure is one of `points` — so
                // neither widens a scale. Nothing about the plot's geometry may
                // depend on hover: the leading edge sits wherever the widest
                // y-label ends, so a rescale would slide the curve sideways
                // under a stationary pointer and change the day it is on.
                RuleMark(x: .value("Day", days[index], unit: .day))
                    .lineStyle(StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.primary.opacity(0.25))
                PointMark(
                    x: .value("Day", days[index], unit: .day),
                    y: .value("Estimated cost", points[index].estimatedCostUSD)
                )
                .symbolSize(PopoverMetrics.chartHoverPointSize)
                .foregroundStyle(Color.primary.opacity(DailyUsageSeries.shades[0]))
            }
        }
        .chartYScale(domain: .automatic(includesZero: true))
        .chartXAxis {
            AxisMarks(values: tickDays) { _ in
                AxisTick(length: PopoverMetrics.chartTickLength, stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.secondary)
                AxisValueLabel(format: PopoverChartHover.dayLabelFormat)
                    .font(PopoverMetrics.captionFont)
                    .foregroundStyle(.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: PopoverMetrics.chartYAxisTickCount)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.primary.opacity(0.12))
                AxisTick(length: PopoverMetrics.chartTickLength, stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.secondary)
                AxisValueLabel {
                    // `compactCost`, not `cost`: `$50.00` on every tick spends a
                    // third of the popover's narrowest label on zeroes.
                    Text(value.as(Double.self).flatMap(DisplayFormat.compactCost) ?? "")
                        .font(PopoverMetrics.captionFont)
                        .foregroundStyle(.secondary)
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
