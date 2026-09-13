import Accessibility
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

    /// Ordered bands for the "By source" chart: display order, darkest band
    /// first, including sources that did nothing in the window.
    static func sources(from history: DailyUsageHistory) -> [DailyUsageSeries] {
        let shades: [Double] = [0.62, 0.40, 0.24]
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
/// Axes are hidden: at ~44 pt tall there is no room for tick labels, and the
/// section title already says which window this is. The numbers themselves live
/// in the legend below the chart, which is what the reader gets exact values
/// from.
struct DailyUsageChart: View {
    /// Local midnights, oldest first — the x positions every series shares.
    let days: [Date]

    /// Stack order, bottom band first.
    let series: [DailyUsageSeries]

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

    var body: some View {
        Chart(records) { record in
            AreaMark(
                x: .value("Day", record.day, unit: .day),
                y: .value("Tokens", record.tokens)
            )
            .foregroundStyle(by: .value("Source", record.series))
            // Monotone, not `catmullRom`: a spline through spiky daily counts
            // overshoots, and on a stacked band an overshoot dips below the band
            // underneath it — drawing usage that never happened. Monotone keeps
            // every segment within its own two points.
            .interpolationMethod(.monotone)
        }
        .chartForegroundStyleScale(
            domain: series.map(\.label),
            range: series.map { Color.primary.opacity($0.shade) }
        )
        .chartLegend(.hidden)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: PopoverMetrics.chartHeight)
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
