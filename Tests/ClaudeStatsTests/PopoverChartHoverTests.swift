import AppKit
import XCTest
@testable import ClaudeStats
@testable import ClaudeStatsCore

/// Coverage for the hover readout: which day the pointer lands on, what happens
/// when the window moves under it, and whether the row that reads it back has
/// the width to do so without truncating — and, by the same measurement, the
/// reserved columns of the quota rows above it.
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

    func testAPointerExactlyBetweenTwoDaysSnapsToTheEarlierOne() {
        let window = days(30)
        // Noon is exactly equidistant from the midnights either side of it.
        // Nothing about the pixel says which day it means, so the rule is the
        // one the strict comparison in `nearestDay` gives: the first day at
        // that distance wins, and the readout never flickers between the two.
        let midpoint = Date(timeInterval: 12 * 3600, since: window[2])

        XCTAssertEqual(PopoverChartHover.nearestDay(to: midpoint, in: window), window[2])
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

    func testADayIsNamedByMonthAndDayOnly() throws {
        // `label(for:)` formats in the machine's own time zone, so the day it
        // names has to be built there too: a UTC midnight is the evening of the
        // day before in every negative-offset zone, and the day-of-month
        // asserted below would be off by one there.
        let day = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 1)))
        let nextDay = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: day))
        let label = PopoverChartHover.label(for: day)

        XCTAssertTrue(label.contains("1"), "\(label) should name the day of the month")
        XCTAssertFalse(label.contains("2026"), "\(label) spends width on a year the window can't span")
        XCTAssertNotEqual(label, PopoverChartHover.label(for: nextDay))
    }

    // MARK: - Room to read it back

    /// Widths measured the way ``PopoverMetrics`` documents them, so the
    /// reserved columns are checked against the fonts that actually render.
    private func width(_ string: String, _ font: NSFont) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: font]).width
    }

    /// What a popover row has to fit into.
    private static let contentWidth = PopoverMetrics.popoverWidth - 2 * PopoverMetrics.contentPadding

    private let bodyFont = NSFont.systemFont(ofSize: 11)
    private let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private let captionFont = NSFont.systemFont(ofSize: 10)

    func testTheTokenColumnHoldsAWindowsCounts() {
        // A thirty-day sum on a cache-read-heavy corpus reaches the hundreds of
        // millions; `G` is shorter than `M`, so `298.5M` is the widest string
        // the formatter produces before the numbers stop being plausible.
        for count in [0, 840, 12_400, 40_600, 298_500, 1_100_000, 12_400_000, 298_500_000] {
            let text = DisplayFormat.tokens(count)
            XCTAssertLessThanOrEqual(
                width(text, valueFont),
                PopoverMetrics.tableTokenColumnWidth,
                "\(text) overflows the table's token column"
            )
        }
    }

    /// The heading the caption row draws over that column has to fit it too —
    /// the figures below it are the narrower of the two.
    func testTheTokenColumnHoldsItsHeading() {
        XCTAssertLessThanOrEqual(
            width("Tokens", captionFont),
            PopoverMetrics.tableTokenColumnWidth,
            "the heading would truncate"
        )
    }

    /// The column is sized by its *heading*, which is the point: `Estimated` is
    /// the word qualifying every figure under it — a local estimate from
    /// published per-token prices, on a subscription spend that was never
    /// charged — so the column widened rather than the word shrinking to `Est.`.
    func testTheCostColumnHoldsTheSpelledOutHeadingAndAFourDigitFigure() {
        XCTAssertLessThanOrEqual(
            width("Estimated cost", captionFont),
            PopoverMetrics.tableCostColumnWidth,
            "the heading would truncate, which is what an abbreviation would be hiding"
        )
        // A heavy cache-read day can push one band's estimate past $1000.
        XCTAssertLessThanOrEqual(width(DisplayFormat.cost(1_234.56), valueFont), PopoverMetrics.tableCostColumnWidth)
    }

    /// Both splits' widest label, against the row that has to hold it beside a
    /// dot and two fixed columns.
    func testATableRowFitsThePopoverWithoutTruncating() {
        let labels = Entrypoint.displayOrder.map(\.displayName)
            + ModelFamily.displayOrder.map(\.displayName)
            + [DailyUsageSeries.otherBandLabel, "Total"]
        let widest = labels.map { width($0, bodyFont) }.max() ?? 0

        // dot, label, the minimum gap before the columns, and both columns —
        // with four `legendSwatchSpacing` gaps between the five elements.
        let row = PopoverMetrics.legendSwatchSize
            + widest
            + PopoverMetrics.rowSpacing
            + PopoverMetrics.tableTokenColumnWidth
            + PopoverMetrics.tableCostColumnWidth
            + 4 * PopoverMetrics.legendSwatchSpacing

        XCTAssertLessThanOrEqual(row, Self.contentWidth, "a table row has to truncate to fit")
    }

    // MARK: - Room on a quota row

    /// The quota rows' three columns, measured the way the table's are. Each is
    /// documented in ``PopoverMetrics`` by a single hand-measured point value
    /// with a few points of margin, and every one of those rows pins its text
    /// to one line — so a string that outgrows its column truncates silently.
    func testTheLabelColumnHoldsEveryQuotaRowLabel() {
        let labels = [
            QuotaWindowKind.fiveHour.title,
            QuotaWindowKind.sevenDay.title,
            "Usage credits",
            // Scoped weekly rows take their label from the payload; these are
            // the families the payload actually names.
            "Sonnet weekly",
            "Opus weekly",
            "Haiku weekly",
        ]
        for label in labels {
            XCTAssertLessThanOrEqual(
                width(label, bodyFont),
                PopoverMetrics.labelColumnWidth,
                "\(label) truncates in the quota rows' label column"
            )
        }
    }

    func testThePercentColumnHoldsEveryReadingItCanShow() {
        // `99.9%` is the widest: the one-decimal band above 99 is a character
        // longer than `100%`, and the em dash of an unreported window is short.
        let readings = [
            DisplayFormat.unknownWindowPercent,
            DisplayFormat.percent(percentValue: 0),
            DisplayFormat.percent(percentValue: 99.94),
            DisplayFormat.percent(percentValue: 100),
        ]
        for reading in readings {
            XCTAssertLessThanOrEqual(
                width(reading, valueFont),
                PopoverMetrics.percentColumnWidth,
                "\(reading) overflows the percent column"
            )
        }
    }

    func testTheCountdownColumnHoldsThePlaceholdersAndTheLongestCountdown() {
        let readings = [
            DisplayFormat.unknownWindowCountdown,
            DisplayFormat.resetCountdown(nil),
            DisplayFormat.resetCountdown(6 * 86_400 + 23 * 3600),
            DisplayFormat.resetCountdown(2 * 3600 + 14 * 60),
        ]
        for reading in readings {
            XCTAssertLessThanOrEqual(
                width(reading, captionFont),
                PopoverMetrics.countdownColumnWidth,
                "\(reading) overflows the countdown column"
            )
        }
    }

    /// The bar is whatever the row's three fixed columns and the two gaps
    /// around it don't take — ``UsageBar`` is greedy — so a column widened for
    /// its own sake is width taken off the bar. ``PopoverMetrics/quotaBarWidth``
    /// is that leftover, and this is what keeps the constant, the docs and the
    /// row that actually lays out agreeing.
    func testTheBarGetsWhatTheQuotaRowsFixedColumnsLeave() {
        let fixed = PopoverMetrics.labelColumnWidth
            + PopoverMetrics.percentColumnWidth
            + PopoverMetrics.countdownColumnWidth
            // Two gaps, not three: the percentage and the countdown sit flush
            // against each other, which is where the bar's extra width came
            // from.
            + 2 * PopoverMetrics.rowSpacing

        XCTAssertEqual(Self.contentWidth - fixed, PopoverMetrics.quotaBarWidth, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(
            PopoverMetrics.quotaBarWidth,
            123,
            "the quota bars lost width to a column beside them"
        )
    }

    /// Where the percentages' right edge lands, which is the *point* of the
    /// column widths above rather than a consequence of them: 261 pt from the
    /// row's leading edge, the position marked on the annotated screenshot this
    /// layout was fitted to. Asserted as the sum the row actually lays out, so
    /// a column that grows or shrinks without the bar absorbing the difference
    /// is caught here rather than by eye.
    func testThePercentagesRightEdgeSitsWhereTheLayoutWasFittedTo() {
        let percentRightEdge = PopoverMetrics.labelColumnWidth
            + PopoverMetrics.rowSpacing
            + PopoverMetrics.quotaBarWidth
            + PopoverMetrics.rowSpacing
            + PopoverMetrics.percentColumnWidth

        XCTAssertEqual(percentRightEdge, 261, accuracy: 0.001)
        // And the countdown column is exactly the rest of the row, so the
        // countdowns still end flush with the content's trailing edge.
        XCTAssertEqual(
            percentRightEdge + PopoverMetrics.countdownColumnWidth,
            Self.contentWidth,
            accuracy: 0.001
        )
    }

    /// The usage-credits row's bar is the same width as the quota bars above
    /// it, which is why ``PopoverMetrics/percentAndCountdownColumnWidth``
    /// includes the gap in front of it: that row lays the bar and the value out
    /// with no `rowSpacing` between them (see ``PopoverView``'s
    /// `usageCreditsRow`), so the two ways of spending the trailing 101 pt
    /// leave the bar at the same x.
    func testTheCreditsRowsBarIsAsWideAsTheQuotaBars() {
        let creditsBar = Self.contentWidth
            - PopoverMetrics.labelColumnWidth
            - PopoverMetrics.rowSpacing
            - PopoverMetrics.percentAndCountdownColumnWidth

        XCTAssertEqual(creditsBar, PopoverMetrics.quotaBarWidth, accuracy: 0.001)
    }

    /// Breathing room between the bar and the reading beside it: the bar's own
    /// gap plus the slack in front of a right-aligned percentage. It used to be
    /// 21.8 pt for an ordinary `62%`, which read as the number crowding the bar.
    func testThePercentageKeepsClearSpaceAfterTheBar() {
        for reading in ["0%", "62%", "100%"] {
            let gap = PopoverMetrics.rowSpacing
                + PopoverMetrics.percentColumnWidth
                - width(reading, valueFont)
            XCTAssertGreaterThanOrEqual(gap, 18, "\(reading) sits too close to the bar")
        }

        // The percentage keeps clear space on its *other* side too. This used
        // to assert the countdown was the further of the two from the bar —
        // that the row read bar → percentage → countdown rather than
        // bar+percentage → countdown. It no longer holds and is no longer the
        // rule: the percentage was moved deliberately to 261 pt (see
        // ``testThePercentagesRightEdgeSitsWhereTheLayoutWasFittedTo``), which
        // spent the countdown column's slack on the bar, so the two readings
        // now sit closer to each other than the percentage does to the bar.
        // What still has to hold is that they don't *touch*: every string the
        // countdown column can show is right-aligned in it, so the air in front
        // of it is the column width less the string.
        // Measured in the font the column is *drawn* in — monospacing widens
        // some digits, and `11d 11h` is the widest string it holds.
        for countdown in ["11d 11h", "6d 23h", "2h 14m", "88m", "pending", "no data"] {
            let gap = PopoverMetrics.countdownColumnWidth
                - width(countdown, PopoverMetrics.captionValueNSFont)
            XCTAssertGreaterThanOrEqual(gap, 10, "\(countdown) crowds the reading beside it")
        }
    }

    func testTheMergedColumnHoldsACreditsValueInAWideLocale() {
        // The value that sized the merged column, in the locale that spends the
        // most width on it: comma separator, trailing symbol, space before it.
        let text = DisplayFormat.moneySpend(
            used: MoneyAmount(amountMinor: 2_087, currency: "EUR"),
            limit: MoneyAmount(amountMinor: 3_300, currency: "EUR"),
            locale: Locale(identifier: "de_DE")
        )

        XCTAssertLessThanOrEqual(
            width(text, valueFont),
            PopoverMetrics.percentAndCountdownColumnWidth,
            "\(text) overflows the merged credits column"
        )
    }

    /// The caption row carries the whole hover disclosure — the window at rest,
    /// the day under the pointer — so neither state may truncate.
    func testTheCaptionRowFitsInBothOfItsStates() {
        let captions = ["Last 30 days", "Last 8 days"] + days(366).map { PopoverChartHover.label(for: $0) }
        let widest = captions.map { width($0, captionFont) }.max() ?? 0

        let row = widest
            + PopoverMetrics.rowSpacing
            + PopoverMetrics.tableTokenColumnWidth
            + PopoverMetrics.tableCostColumnWidth
            + 3 * PopoverMetrics.legendSwatchSpacing

        XCTAssertLessThanOrEqual(row, Self.contentWidth)
    }
}
