import AppKit
import XCTest
@testable import ClaudeStats
@testable import ClaudeStatsCore

/// Coverage for the hover readout: which day the pointer lands on, what happens
/// when the window moves under it, and whether the row that reads it back has
/// the width to do so without truncating.
final class PopoverChartHoverTests: XCTestCase {

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static let firstDay = SessionLogParser.parseTimestamp("2026-07-01T00:00:00.000Z")!

    /// `count` consecutive local midnights, oldest first — the shape both
    /// charts' `days` always has.
    private func days(_ count: Int) -> [Date] {
        (0..<count).compactMap { Self.calendar.date(byAdding: .day, value: $0, to: Self.firstDay) }
    }

    private func date(_ iso: String) throws -> Date {
        try XCTUnwrap(SessionLogParser.parseTimestamp(iso))
    }

    // MARK: - Snapping

    func testAPointerInsideADaySnapsToTheNearestMidnight() throws {
        let window = days(30)

        // Every mark is drawn on its own midnight — which puts the afternoon of
        // the 3rd nearer the 4th's mark than the 3rd's. Snapping to the *mark*,
        // not to the calendar day, is what makes the rule land on the point the
        // eye is aiming at.
        XCTAssertEqual(PopoverChartHover.nearestDay(to: try date("2026-07-03T02:00:00.000Z"), in: window), window[2])
        XCTAssertEqual(PopoverChartHover.nearestDay(to: try date("2026-07-03T20:00:00.000Z"), in: window), window[3])
    }

    func testAPointerPastEitherEndSnapsToTheDayThere() throws {
        let window = days(30)

        // The overlay only covers the plot, but the proxy maps its edges to
        // dates slightly outside the data — a pointer on the last pixel must
        // still read the last day rather than nothing.
        XCTAssertEqual(PopoverChartHover.nearestDay(to: try date("2026-05-01T00:00:00.000Z"), in: window), window.first)
        XCTAssertEqual(PopoverChartHover.nearestDay(to: try date("2026-09-01T00:00:00.000Z"), in: window), window.last)
    }

    func testAnEmptyWindowHasNoNearestDay() throws {
        XCTAssertNil(PopoverChartHover.nearestDay(to: try date("2026-07-03T12:00:00.000Z"), in: []))
    }

    // MARK: - Resolving against the current window

    func testTheHoveredDayIsFoundInTheWindowItCameFrom() {
        let window = days(30)
        XCTAssertEqual(PopoverChartHover.index(of: window[17], in: window), 17)
    }

    func testADayTheWindowHasSinceDroppedResolvesToNothing() {
        let window = days(30)
        // Midnight passes, or a poll lands: the window slides forward and the
        // oldest day leaves it. The readout has to fall back to resting rather
        // than keep showing a number from a window that has moved on.
        let slid = Array(window.dropFirst()) + [Self.calendar.date(byAdding: .day, value: 30, to: Self.firstDay)!]

        XCTAssertNil(PopoverChartHover.index(of: window[0], in: slid))
        XCTAssertEqual(PopoverChartHover.index(of: window[1], in: slid), 0)
    }

    func testNoHoverResolvesToNothing() {
        XCTAssertNil(PopoverChartHover.index(of: nil, in: days(30)))
    }

    // MARK: - Labels

    func testADayIsNamedByMonthAndDayOnly() {
        let label = PopoverChartHover.label(for: Self.firstDay)

        XCTAssertTrue(label.contains("1"), "\(label) should name the day of the month")
        XCTAssertFalse(label.contains("2026"), "\(label) spends width on a year the window can't span")
        XCTAssertNotEqual(label, PopoverChartHover.label(for: days(2)[1]))
    }

    // MARK: - Room to read it back

    /// Widths measured the way ``PopoverMetrics`` documents them, so the
    /// reserved columns are checked against the fonts that actually render.
    private func width(_ string: String, _ font: NSFont) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: font]).width
    }

    /// What a popover row has to fit into.
    private static let contentWidth = PopoverMetrics.popoverWidth - 2 * PopoverMetrics.contentPadding

    private let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private let captionFont = NSFont.systemFont(ofSize: 10)

    func testTheReservedTokenColumnHoldsADaysCounts() {
        // A day is up to 4.8 five-hour windows, and cache reads push a busy
        // one into the hundreds of millions — the widest string the formatter
        // produces before the numbers stop being plausible.
        let counts = [0, 840, 12_400, 40_600, 298_500, 1_100_000, 12_400_000, 298_500_000]
        for count in counts {
            let text = DisplayFormat.tokens(count)
            XCTAssertLessThanOrEqual(
                width(text, valueFont),
                PopoverMetrics.legendTokenColumnWidth,
                "\(text) overflows the column the legend reserves for it"
            )
        }
    }

    func testTheHoveredLegendRowFitsThePopoverWithoutTruncating() {
        // The failure this guards was real: the first render of this row came
        // back as `CLI 842.…` and `VS Co…`. Every chip keeps its source name
        // while hovering, so the row has to hold three names, three swatches
        // and three day-sized counts — which is why the hovered date moved to
        // the section title and the `5h` caption steps aside.
        let bodyFont = NSFont.systemFont(ofSize: 11)
        let chips = Entrypoint.displayOrder.map { entrypoint in
            PopoverMetrics.legendSwatchSize
                + PopoverMetrics.legendSwatchSpacing
                + width(entrypoint.displayName, bodyFont)
                + PopoverMetrics.legendSwatchSpacing
                + PopoverMetrics.legendTokenColumnWidth
        }
        let row = chips.reduce(0, +) + CGFloat(chips.count - 1) * PopoverMetrics.rowSpacing

        XCTAssertLessThanOrEqual(row, Self.contentWidth, "the hovered legend has to truncate to fit")
    }

    func testTheHoveredDateFitsBesideTheSectionTitle() {
        let titleFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let widestDate = days(366).map { width(PopoverChartHover.label(for: $0), captionFont) }.max() ?? 0

        XCTAssertLessThanOrEqual(
            width("Tokens by source", titleFont) + PopoverMetrics.rowSpacing + widestDate,
            Self.contentWidth
        )
    }
}
