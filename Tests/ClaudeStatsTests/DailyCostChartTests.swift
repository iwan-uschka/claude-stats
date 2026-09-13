import Accessibility
import XCTest
@testable import ClaudeStats
@testable import ClaudeStatsCore

/// Coverage for the "Est. cost" chart — its accessibility descriptor, and the
/// x-axis it has to share with the "Tokens by source" chart above it.
final class DailyCostChartTests: XCTestCase {

    private static let referenceNow = SessionLogParser.parseTimestamp("2026-07-15T12:00:00.000Z")!

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func days(_ count: Int) -> [Date] {
        let start = Self.utcCalendar.startOfDay(for: Self.referenceNow)
        return (0..<count)
            .compactMap { Self.utcCalendar.date(byAdding: .day, value: -$0, to: start) }
            .reversed()
    }

    private func points(_ costs: [Double]) -> [DailyUsagePoint] {
        zip(days(costs.count), costs).map { DailyUsagePoint(day: $0, estimatedCostUSD: $1) }
    }

    // MARK: - X-axis

    func testBothPopoverChartsTickOnTheSameDays() {
        // Two dated plots stacked in one column: ticks that disagree would make
        // the same x position mean two different days.
        let days = self.days(30)
        let cost = DailyCostChart(days: days, points: points(Array(repeating: 1, count: 30)))
        let source = DailyUsageChart(days: days, series: [])

        XCTAssertEqual(cost.tickDays, source.tickDays)
        XCTAssertFalse(cost.tickDays.isEmpty)
    }

    // MARK: - Accessibility

    func testDescriptorCarriesEveryDayAsOneSeries() {
        let costs = [1.0, 4.5, 0, 12.25]
        let descriptor = DailyCostChartDescriptor(
            days: days(costs.count),
            points: points(costs)
        ).makeChartDescriptor()

        // One line, so one series — and a quiet day is a zero point, not an
        // absent one, the same rule the plotted series follows.
        XCTAssertEqual(descriptor.series.count, 1)
        XCTAssertEqual(descriptor.series.first?.dataPoints.count, costs.count)
        XCTAssertEqual(descriptor.series.first?.dataPoints.compactMap { $0.yValue?.__number }, costs)
        XCTAssertTrue(descriptor.title?.contains("\(costs.count) days") ?? false)
    }

    func testDescriptorYAxisCoversTheDearestDay() throws {
        let descriptor = DailyCostChartDescriptor(
            days: days(4),
            points: points([1.0, 4.5, 0, 12.25])
        ).makeChartDescriptor()

        let yAxis = try XCTUnwrap(descriptor.yAxis)
        XCTAssertEqual(yAxis.range.lowerBound, 0)
        XCTAssertEqual(yAxis.range.upperBound, 12.25, accuracy: 0.001)
    }

    func testDescriptorNeverHasAnEmptyRange() throws {
        // An all-zero window, and an empty one: `0...0` is a divide-by-zero
        // waiting to happen in VoiceOver's audio graph.
        for points in [self.points([0, 0, 0]), []] {
            let descriptor = DailyCostChartDescriptor(
                days: days(points.count),
                points: points
            ).makeChartDescriptor()
            let yAxis = try XCTUnwrap(descriptor.yAxis)
            XCTAssertGreaterThan(yAxis.range.upperBound, yAxis.range.lowerBound)
        }
    }

    func testDescriptorDescribesProbeValuesWithoutTrappingOrLying() throws {
        let descriptor = DailyCostChartDescriptor(
            days: days(2),
            points: points([1, 2])
        ).makeChartDescriptor()
        let yAxis = try XCTUnwrap(descriptor.yAxis)
        let describe = try XCTUnwrap(yAxis.valueDescriptionProvider)

        XCTAssertEqual(describe(.nan), "unknown")
        XCTAssertEqual(describe(.infinity), "unknown")
        XCTAssertEqual(describe(.greatestFiniteMagnitude), "unknown")
        // Never bare numbers: VoiceOver reads these out of any visual context,
        // so the estimate has to say it is one.
        XCTAssertEqual(describe(12.25), "$12 estimated")
        XCTAssertEqual(describe(0), "$0 estimated")
    }
}
