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
            // The longest countdown the formatter can make, which is what the
            // column was sized to.
            DisplayFormat.resetCountdown(11 * 86_400 + 11 * 3600),
            DisplayFormat.resetCountdown(6 * 86_400 + 23 * 3600),
            DisplayFormat.resetCountdown(2 * 3600 + 14 * 60),
        ]
        for reading in readings {
            XCTAssertLessThanOrEqual(
                // ``WindowBarView`` draws this column in the monospaced-digit
                // caption font, and monospacing widens the narrow digits — a
                // proportional measurement would under-read the very strings
                // this guard exists to keep inside the column actually applied,
                // ``trailingValueColumnWidth`` (wider than
                // ``PopoverMetrics/countdownColumnWidth`` itself, which is the
                // tighter, hypothetical bound this asserts against — every
                // countdown that fits 51 pt fits the real 59 pt column with
                // room to spare).
                width(reading, PopoverMetrics.captionValueNSFont),
                PopoverMetrics.countdownColumnWidth,
                "\(reading) overflows the countdown column"
            )
        }
    }

    /// The bar is whatever the row's fixed columns and the one gap before it
    /// don't take — ``UsageBar`` is greedy — so a column widened for its own
    /// sake is width taken off the bar. ``PopoverMetrics/quotaBarWidth`` is
    /// that leftover, and this is what keeps the constant and the docs
    /// agreeing.
    ///
    /// The equality below restates ``PopoverMetrics/quotaBarWidth``'s own
    /// formula, so it checks *internal consistency* — that the leftover is
    /// still spelled out of the same columns and the same one gap — rather
    /// than a rendered row: the constant is deliberately not applied, so no
    /// SwiftUI layout runs here. The bound under it is the part that catches a
    /// column growing at the bar's expense.
    func testTheBarGetsWhatTheQuotaRowsFixedColumnsLeave() {
        let fixed = PopoverMetrics.labelColumnWidth
            + PopoverMetrics.percentColumnWidth
            + PopoverMetrics.trailingValueColumnWidth
            // One gap, not two: the bar, the percentage and the trailing
            // reading all sit flush against each other — only the label has a
            // real gap before what follows it.
            + PopoverMetrics.rowSpacing

        XCTAssertEqual(Self.contentWidth - fixed, PopoverMetrics.quotaBarWidth, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(
            PopoverMetrics.quotaBarWidth,
            123,
            "the quota bars lost width to a column beside them"
        )
    }

    /// Where the percentages' right edge lands, and — the point of this test —
    /// the *same* edge on every row, credits row included: 253 pt from the
    /// row's leading edge. Asserted as the sum the row actually lays out, so a
    /// column that grows or shrinks without the bar absorbing the difference
    /// is caught here rather than by eye.
    func testThePercentagesRightEdgeSitsWhereTheLayoutWasFittedTo() {
        let percentRightEdge = PopoverMetrics.labelColumnWidth
            + PopoverMetrics.rowSpacing
            + PopoverMetrics.quotaBarWidth
            + PopoverMetrics.percentColumnWidth

        XCTAssertEqual(percentRightEdge, 253, accuracy: 0.001)
        // And the trailing column is exactly the rest of the row, so the
        // countdowns (and the credits row's caption) still end flush with the
        // content's trailing edge.
        XCTAssertEqual(
            percentRightEdge + PopoverMetrics.trailingValueColumnWidth,
            Self.contentWidth,
            accuracy: 0.001
        )
    }

    /// The usage-credits row's bar is the same width as the quota bars above
    /// it — same formula, same ``PopoverMetrics/trailingValueColumnWidth`` —
    /// because ``PopoverView``'s `usageCreditsRow` lays its bar, percent and
    /// caption out in the exact same zero-spacing shape ``WindowBarView`` uses
    /// for its bar, percent and countdown.
    func testTheCreditsRowsBarIsAsWideAsTheQuotaBars() {
        let creditsBar = Self.contentWidth
            - PopoverMetrics.labelColumnWidth
            - PopoverMetrics.rowSpacing
            - PopoverMetrics.percentColumnWidth
            - PopoverMetrics.trailingValueColumnWidth

        XCTAssertEqual(creditsBar, PopoverMetrics.quotaBarWidth, accuracy: 0.001)
    }

    /// Breathing room between the bar and the reading beside it — the slack in
    /// front of a right-aligned percentage sitting flush against the bar, with
    /// no gap of its own to help. It used to be 21.8 pt for an ordinary `62%`,
    /// back when a real ``PopoverMetrics/rowSpacing`` sat between the bar and
    /// this column too; removing that gap (so every row's percent lines up on
    /// one x — see ``PopoverMetrics/trailingValueColumnWidth``) cost this
    /// column its half of it.
    func testThePercentageKeepsClearSpaceAfterTheBar() {
        for reading in ["0%", "62%", "100%"] {
            let gap = PopoverMetrics.percentColumnWidth - width(reading, valueFont)
            // 10 rather than 18: `100%` is the tightest of these three at 31.2
            // of the column's 42 pt, so the real margin is 10.8 pt and a floor
            // of 10 leaves 0.8 pt of headroom — close enough that a font-metric
            // change between macOS versions could fail this without the layout
            // having moved. `99.9%`, wider still, is excluded: that string is
            // what sized the column in the first place (see
            // ``PopoverMetrics/percentColumnWidth``), not a reading expected to
            // clear it.
            XCTAssertGreaterThanOrEqual(gap, 10, "\(reading) sits too close to the bar")
        }

        // The trailing reading keeps clear space on its *other* side too:
        // every string it can show is right-aligned in
        // ``PopoverMetrics/trailingValueColumnWidth``, so the air in front of
        // it is that column's width less the string. Measured in the font the
        // column is *drawn* in — monospacing widens some digits, and
        // `11d 11h` is the widest string it holds.
        //
        // `59m` is the minutes-only maximum the formatter can reach, not a
        // two-digit number picked for width: ``DisplayFormat/duration(_:)``
        // only returns a bare `\(minutes)m` once the hours are zero, and the
        // minutes it takes from the remainder are `0...59` there. Anything
        // longer comes back as `2h 14m`, which is already in this list.
        for countdown in ["11d 11h", "6d 23h", "2h 14m", "59m", "pending", "no data"] {
            let gap = PopoverMetrics.trailingValueColumnWidth
                - width(countdown, PopoverMetrics.captionValueNSFont)
            // `11d 11h` is still the binding string among these at 40.9 of the
            // column's 59 pt, leaving ~18.1 pt of real margin; a floor of 17
            // leaves ~1.1 pt of headroom, in line with this file's other
            // floors (see the `100%` case above) rather than the ~0.1 pt an
            // unrecalibrated floor of 9.5 — carried over from the narrower
            // 51 pt column this measured before — would leave now.
            XCTAssertGreaterThanOrEqual(gap, 17, "\(countdown) crowds the reading beside it")
        }
    }

    /// The credits row's caption holds a three-digit, two-decimal limit —
    /// the case ``PopoverMetrics/trailingValueColumnWidth`` documents itself
    /// against — in the locale that spends the most width on one: comma
    /// separator, trailing symbol, space before it.
    func testTheCreditsLimitCaptionHoldsAThreeDigitAmountInAWideLocale() {
        let text = DisplayFormat.creditsLimitCaption(
            MoneyAmount(amountMinor: 99_900, currency: "EUR"),
            locale: Locale(identifier: "de_DE")
        )

        XCTAssertLessThanOrEqual(
            width(text, PopoverMetrics.captionValueNSFont),
            PopoverMetrics.trailingValueColumnWidth,
            "\(text) overflows the credits row's caption column"
        )
    }

    /// The caption row carries the whole hover disclosure — the window at rest,
    /// the day under the pointer — so neither state may truncate.
    func testTheCaptionRowFitsInBothOfItsStates() {
        let captions = ["Last 30 days", "Last 8 days"] + days(366).map { PopoverChartHover.label(for: $0) }
        // Both states are half number, so ``DailyUsageTable``'s caption draws
        // monospaced — measured in the proportional font this would under-read
        // every caption that carries digits.
        let widest = captions.map { width($0, PopoverMetrics.captionValueNSFont) }.max() ?? 0

        let row = widest
            + PopoverMetrics.rowSpacing
            + PopoverMetrics.tableTokenColumnWidth
            + PopoverMetrics.tableCostColumnWidth
            + 3 * PopoverMetrics.legendSwatchSpacing

        XCTAssertLessThanOrEqual(row, Self.contentWidth)
    }
}
