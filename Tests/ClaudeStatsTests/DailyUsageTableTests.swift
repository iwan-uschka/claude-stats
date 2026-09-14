import SwiftUI
import XCTest
@testable import ClaudeStats
@testable import ClaudeStatsCore

/// Coverage for the numbers under each chart: which rows exist and in what
/// order, what they read at rest and under the pointer, and that the `Total`
/// row is the history's own total rather than the bands added up.
final class DailyUsageTableTests: XCTestCase {

    private static let referenceNow = SessionLogParser.parseTimestamp("2026-07-15T12:00:00.000Z")!

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Three days, two sources and two models, plus one event of each kind this
    /// version doesn't recognise on the last day — so both splits grow their
    /// "Other" band and neither can quietly drop anything.
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
                UsageEvent(
                    timestamp: try XCTUnwrap(SessionLogParser.parseTimestamp("2026-07-15T10:00:00.000Z")),
                    entrypoint: nil,
                    modelID: "some-model-from-the-future",
                    usage: TokenUsage(inputTokens: 500)
                ),
            ],
            calendar: Self.utcCalendar,
            now: { now }
        )
        return try store.dailyUsage(days: 30)
    }

    private func sourceTable(_ history: DailyUsageHistory, hoveredDay: Date? = nil) -> DailyUsageTable {
        DailyUsageTable(
            series: DailyUsageSeries.sources(from: history),
            total: history.total,
            days: history.days,
            hoveredDay: hoveredDay,
            restingCaption: "Last \(history.days.count) days"
        )
    }

    private func modelTable(_ history: DailyUsageHistory, hoveredDay: Date? = nil) -> DailyUsageTable {
        DailyUsageTable(
            series: DailyUsageSeries.models(from: history),
            total: history.total,
            days: history.days,
            hoveredDay: hoveredDay,
            restingCaption: "Last \(history.days.count) days"
        )
    }

    // MARK: - Rows

    func testRowsFollowTheChartsStackOrderBottomBandFirst() throws {
        let history = try makeHistory()

        // Table order *is* stack order, so the eye reading the plot downwards
        // meets the rows in the same sequence — and the dot two rows down means
        // the band two steps up in either block.
        XCTAssertEqual(
            sourceTable(history).bandRows.map(\.label),
            DailyUsageSeries.sources(from: history).map(\.label)
        )
        XCTAssertEqual(
            modelTable(history).bandRows.map(\.label),
            DailyUsageSeries.models(from: history).map(\.label)
        )
        XCTAssertEqual(sourceTable(history).bandRows.last?.label, DailyUsageSeries.otherBandLabel)
        XCTAssertEqual(modelTable(history).bandRows.last?.label, DailyUsageSeries.otherBandLabel)
    }

    func testEveryBandRowCarriesItsOwnShadeAndTheTotalRowCarriesNone() throws {
        let table = sourceTable(try makeHistory())

        // The dot is the only thing tying a row to an area in the plot; the
        // total is the stack's outline, not a band in it, so it has no dot.
        XCTAssertEqual(
            table.bandRows.compactMap(\.color),
            table.bandRows.indices.map { DailyUsageSeries.bandColor($0, of: table.bandRows.count) }
        )
        XCTAssertNil(table.totalRow.color)
        XCTAssertEqual(table.totalRow.label, "Total")
    }

    // MARK: - Totals

    func testTheTotalRowIsTheHistorysOwnTotalAndTheBandsAddUpToIt() throws {
        let history = try makeHistory()

        for table in [sourceTable(history), modelTable(history)] {
            let expected = history.total.summed()
            XCTAssertEqual(table.totalRow.usage, expected.usage)
            XCTAssertEqual(table.totalRow.cost, expected.estimatedCostUSD, accuracy: 1e-9)

            // Summed from `total` rather than from the rows above it, so a
            // split that dropped something shows as a mismatch here instead of
            // hiding behind a total that agrees with itself.
            XCTAssertEqual(
                table.bandRows.map(\.usage.totalTokens).reduce(0, +),
                table.totalRow.usage.totalTokens
            )
            XCTAssertEqual(table.bandRows.map(\.cost).reduce(0, +), table.totalRow.cost, accuracy: 1e-9)
        }
    }

    func testTheTwoBlocksTotalsAgreeWithEachOther() throws {
        let history = try makeHistory()

        // Two splits of the same window: a reader comparing the two `Total`
        // rows has to find the same number, or one of the blocks is lying about
        // what it is a split of.
        XCTAssertEqual(sourceTable(history).totalRow.usage, modelTable(history).totalRow.usage)
        XCTAssertEqual(
            sourceTable(history).totalRow.cost,
            modelTable(history).totalRow.cost,
            accuracy: 1e-9
        )
    }

    // MARK: - Hover

    func testHoveringSwapsEveryValueAndTheCaptionTogether() throws {
        let history = try makeHistory()
        let day = try XCTUnwrap(history.days.last)
        let resting = sourceTable(history)
        let hovered = sourceTable(history, hoveredDay: day)

        // Label and values move together, or a figure is shown under the wrong
        // date — which is the whole reason the caption is the disclosure.
        XCTAssertEqual(resting.caption, "Last \(history.days.count) days")
        XCTAssertEqual(hovered.caption, PopoverChartHover.label(for: day))

        let index = history.days.count - 1
        XCTAssertEqual(hovered.totalRow.usage, history.total[index].usage)
        for (row, band) in zip(hovered.bandRows, DailyUsageSeries.sources(from: history)) {
            XCTAssertEqual(row.usage, band.points[index].usage)
            XCTAssertEqual(row.cost, band.points[index].estimatedCostUSD, accuracy: 1e-9)
        }
        // The same for the model split, whose bands come out of a different
        // dictionary in a different order — shared row code, but nothing says
        // the two splits index their points the same way unless it is checked.
        let hoveredModels = modelTable(history, hoveredDay: day)
        for (row, band) in zip(hoveredModels.bandRows, DailyUsageSeries.models(from: history)) {
            XCTAssertEqual(row.usage, band.points[index].usage)
            XCTAssertEqual(row.cost, band.points[index].estimatedCostUSD, accuracy: 1e-9)
        }
        XCTAssertNotEqual(hovered.totalRow.usage, resting.totalRow.usage)
    }

    func testADayFromAWindowThatHasMovedFallsBackToResting() throws {
        let history = try makeHistory()
        let dropped = Self.utcCalendar.date(byAdding: .day, value: -90, to: Self.referenceNow)
        let table = sourceTable(history, hoveredDay: dropped)

        // A poll — or midnight sliding the window — must drop the readout back
        // to the whole window rather than strand a number from a window that
        // has moved on.
        XCTAssertNil(table.hoveredIndex)
        XCTAssertEqual(table.caption, "Last \(history.days.count) days")
        XCTAssertEqual(table.totalRow.usage, history.total.summed().usage)
    }

    func testTheCaptionCountsTheDaysTheChartActuallyPlots() throws {
        // A Mac whose logs are younger than the window charts fewer days, and
        // the caption is the one place saying which window the numbers are for.
        let history = try makeHistory()
        XCTAssertEqual(history.days.count, 3)
        XCTAssertEqual(sourceTable(history).caption, "Last 3 days")
    }

    // MARK: - Cache-read note

    func testTheNoteIsComputedFromWhateverTheTableIsShowing() throws {
        let now = Self.referenceNow
        let store = LocalLogUsageStore(
            events: [
                // A quiet day of fresh work, then a cache-read-dominated one.
                UsageEvent(
                    timestamp: try XCTUnwrap(SessionLogParser.parseTimestamp("2026-07-14T09:00:00.000Z")),
                    entrypoint: .cli,
                    modelID: "claude-sonnet-5",
                    usage: TokenUsage(inputTokens: 1_000)
                ),
                UsageEvent(
                    timestamp: try XCTUnwrap(SessionLogParser.parseTimestamp("2026-07-15T09:00:00.000Z")),
                    entrypoint: .cli,
                    modelID: "claude-sonnet-5",
                    usage: TokenUsage(inputTokens: 100, cacheReadInputTokens: 9_900)
                ),
            ],
            calendar: Self.utcCalendar,
            now: { now }
        )
        let history = try store.dailyUsage(days: 30)

        // Hovering has to re-state the share for the day under the pointer, or
        // a thirty-day percentage sits over one day's numbers.
        XCTAssertEqual(
            DisplayFormat.cacheReadNote(modelTable(history).shownUsage),
            DisplayFormat.cacheReadNote(history.total.summed().usage)
        )
        let hovered = modelTable(history, hoveredDay: history.days.last)
        XCTAssertEqual(hovered.shownUsage, try XCTUnwrap(history.total.last).usage)
        XCTAssertEqual(DisplayFormat.cacheReadNote(hovered.shownUsage), "99% cache reads — billed at 1/10 the input rate")

        // The quiet day has no note at all: below the threshold, the raw number
        // needs no qualifying.
        XCTAssertNil(DisplayFormat.cacheReadNote(modelTable(history, hoveredDay: history.days.first).shownUsage))
    }

    // MARK: - Empty window

    func testAnEmptyHistoryStillProducesAZeroedTotalRow() {
        let table = DailyUsageTable(
            series: DailyUsageSeries.sources(from: .empty),
            total: [],
            days: [],
            hoveredDay: nil,
            restingCaption: "Last 0 days"
        )

        // Not rendered in that state — the section draws "No local usage yet"
        // instead — but the rows must not trap on an empty window either.
        XCTAssertEqual(table.totalRow.usage, .zero)
        XCTAssertEqual(table.totalRow.cost, 0)
        XCTAssertTrue(table.bandRows.allSatisfy { $0.usage == .zero })
    }
}
