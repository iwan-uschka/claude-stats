import XCTest
@testable import ClaudeStatsCore

/// Covers the non-visual logic behind the popover and the menu bar glyph:
/// duration/age wording, compact number formatting, and bar-fraction clamping.
final class DisplayFormatTests: XCTestCase {
    // MARK: - duration

    func testDurationShowsTwoLargestUnits() {
        XCTAssertEqual(DisplayFormat.duration(2 * 3600 + 14 * 60), "2h 14m")
        XCTAssertEqual(DisplayFormat.duration(4 * 86_400 + 6 * 3600), "4d 6h")
    }

    func testDurationDropsZeroSmallerUnit() {
        XCTAssertEqual(DisplayFormat.duration(3 * 3600), "3h")
        XCTAssertEqual(DisplayFormat.duration(2 * 86_400), "2d")
    }

    func testDurationRoundsTheSmallestShownUnitToNearest() {
        // 1d 2h 59m 59s → hours round up; minutes and seconds are not shown.
        XCTAssertEqual(DisplayFormat.duration(86_400 + 2 * 3600 + 59 * 60 + 59), "1d 3h")
        XCTAssertEqual(DisplayFormat.duration(86_400 + 2 * 3600 + 20 * 60), "1d 2h")
        // 1h 5m 59s → minutes round up; seconds are not shown.
        XCTAssertEqual(DisplayFormat.duration(3600 + 5 * 60 + 59), "1h 6m")
        XCTAssertEqual(DisplayFormat.duration(3600 + 5 * 60 + 10), "1h 5m")
        // A countdown one second short of the mockup's value still reads 2h 14m
        // rather than dropping to 2h 13m the instant the popover opens.
        XCTAssertEqual(DisplayFormat.duration(2 * 3600 + 14 * 60 - 1), "2h 14m")
        XCTAssertEqual(DisplayFormat.duration(4 * 86_400 + 6 * 3600 - 1), "4d 6h")
    }

    func testDurationRoundingCarriesIntoTheNextUnit() {
        // Must not print "60m" / "24h" / "60s".
        XCTAssertEqual(DisplayFormat.duration(3_599), "1h")
        XCTAssertEqual(DisplayFormat.duration(86_399), "1d")
        XCTAssertEqual(DisplayFormat.duration(86_400 + 3_599), "1d 1h")
    }

    func testDurationBelowOneMinuteUsesSeconds() {
        XCTAssertEqual(DisplayFormat.duration(40), "40s")
        XCTAssertEqual(DisplayFormat.duration(59.9), "59s")
        XCTAssertEqual(DisplayFormat.duration(60), "1m")
    }

    func testDurationRejectsNonPositiveAndNonFiniteValues() {
        XCTAssertEqual(DisplayFormat.duration(0), "0s")
        XCTAssertEqual(DisplayFormat.duration(-90), "0s")
        XCTAssertEqual(DisplayFormat.duration(.infinity), "0s")
        XCTAssertEqual(DisplayFormat.duration(.nan), "0s")
    }

    // MARK: - resetCountdown

    func testResetCountdownWording() {
        XCTAssertEqual(
            DisplayFormat.resetCountdown(2 * 3600 + 14 * 60),
            "2h 14m"
        )
    }

    func testResetCountdownFallsBackWhenUnknownOrElapsed() {
        XCTAssertEqual(DisplayFormat.resetCountdown(nil), "pending")
        XCTAssertEqual(DisplayFormat.resetCountdown(0), "pending")
        XCTAssertEqual(DisplayFormat.resetCountdown(-5), "pending")
    }

    func testResetCountdownUsesTheWindowsOwnDeadline() {
        let now = Date()
        let window = QuotaWindow(
            percentUsed: 62,
            resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60)
        )
        XCTAssertEqual(
            DisplayFormat.resetCountdown(window.timeUntilReset(from: now)),
            "2h 14m"
        )
    }

    // MARK: - unreported windows

    /// No source reported the window at all: an em dash, not 0% — the whole
    /// point of ``QuotaSnapshot``'s optional windows.
    func testWindowColumnsForAnUnreportedWindow() {
        XCTAssertEqual(DisplayFormat.windowPercent(nil), "—")
        XCTAssertEqual(DisplayFormat.windowCountdown(nil, from: Date()), "no data")
        // Even the row that suppresses the `pending` placeholder still says
        // "no data": the absence of the window outranks the absence of its
        // reset stamp.
        XCTAssertEqual(
            DisplayFormat.windowCountdown(nil, from: Date(), showsPendingResetPlaceholder: false),
            "no data"
        )
    }

    func testWindowColumnsForAReportedWindow() {
        let now = Date()
        let window = QuotaWindow(
            percentUsed: 62.4,
            resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60)
        )

        XCTAssertEqual(DisplayFormat.windowPercent(window), "62%")
        XCTAssertEqual(DisplayFormat.windowCountdown(window, from: now), "2h 14m")
    }

    /// A window that exists but reports no reset: "pending" for the two
    /// account-wide bars, an empty column for a scoped row whose missing
    /// `resets_at` means "not reported" — see ``QuotaScopedLimit``.
    func testWindowCountdownWithoutAResetStamp() {
        let now = Date()
        let window = QuotaWindow(percentUsed: 0)

        XCTAssertEqual(DisplayFormat.windowCountdown(window, from: now), "pending")
        XCTAssertEqual(
            DisplayFormat.windowCountdown(window, from: now, showsPendingResetPlaceholder: false),
            ""
        )
        // An elapsed deadline is the same case as no deadline.
        let elapsed = QuotaWindow(percentUsed: 0, resetsAt: now.addingTimeInterval(-5))
        XCTAssertEqual(DisplayFormat.windowCountdown(elapsed, from: now), "pending")
        XCTAssertEqual(
            DisplayFormat.windowCountdown(elapsed, from: now, showsPendingResetPlaceholder: false),
            ""
        )
    }

    /// 0% is a reading and must not borrow the unknown row's rendering.
    func testZeroPercentWindowIsNotRenderedAsUnknown() {
        XCTAssertEqual(DisplayFormat.windowPercent(QuotaWindow(percentUsed: 0)), "0%")
    }

    // MARK: - sourceTag

    /// Only the backup source is named: both carry Anthropic's numbers, so
    /// "official" said nothing, while "cached" warns the reading may be old.
    /// No age, no "stale" suffix — freshness is not part of the tag.
    func testSourceTagNamesOnlyTheCachedSource() {
        XCTAssertNil(DisplayFormat.sourceTag(confidence: .official))
        XCTAssertEqual(DisplayFormat.sourceTag(confidence: .cachedOfficial), "cached")
        XCTAssertNil(QuotaConfidence.official.tagLabel)
        XCTAssertEqual(QuotaConfidence.cachedOfficial.tagLabel, "cached")
    }

    func testSourceTagReadsFromASnapshot() {
        let snapshot = MockQuotaProvider.sampleSnapshot(now: Date())
        XCTAssertNil(DisplayFormat.sourceTag(confidence: snapshot.confidence))
    }

    // MARK: - tokens

    func testTokenCountsMatchTheMockup() {
        XCTAssertEqual(DisplayFormat.tokens(2_100_000), "2.1M")
        XCTAssertEqual(DisplayFormat.tokens(180_000), "180.0k")
        XCTAssertEqual(DisplayFormat.tokens(640_000), "640.0k")
        XCTAssertEqual(DisplayFormat.tokens(90_000), "90.0k")
    }

    func testTokenCountsAlwaysKeepOneDecimal() {
        XCTAssertEqual(DisplayFormat.tokens(12_400), "12.4k")
        XCTAssertEqual(DisplayFormat.tokens(12_000), "12.0k")
        XCTAssertEqual(DisplayFormat.tokens(1_000_000), "1.0M")
        XCTAssertEqual(DisplayFormat.tokens(1_050_000), "1.1M")
        // The ladder has to roll over, or a busy corpus reads `2000M`.
        XCTAssertEqual(DisplayFormat.tokens(2_000_000_000), "2.0G")
        XCTAssertEqual(DisplayFormat.tokens(2_140_000_000), "2.1G")
        XCTAssertEqual(DisplayFormat.tokens(999_900_000), "999.9M")
        XCTAssertEqual(DisplayFormat.tokens(3_500_000_000_000), "3.5T")
    }

    func testTokenCountsBelowAThousandStayExact() {
        XCTAssertEqual(DisplayFormat.tokens(0), "0")
        XCTAssertEqual(DisplayFormat.tokens(1), "1")
        XCTAssertEqual(DisplayFormat.tokens(999), "999")
    }

    func testTokenCountsHandleNegatives() {
        XCTAssertEqual(DisplayFormat.tokens(-5_400), "-5.4k")
    }

    // MARK: - token splits

    func testTokenSplitListsEveryKind() {
        let usage = TokenUsage(
            inputTokens: 9_900,
            outputTokens: 4_700_000,
            cacheCreationInputTokens: 36_300_000,
            cacheReadInputTokens: 453_000_000
        )
        XCTAssertEqual(
            DisplayFormat.tokenSplit(usage),
            "in 9.9k · out 4.7M · cache write 36.3M · cache read 453.0M"
        )
    }

    func testCacheReadNoteAppearsOnlyWhenCacheReadsDominate() {
        let dominated = TokenUsage(inputTokens: 10_000, cacheReadInputTokens: 90_000)
        XCTAssertEqual(
            DisplayFormat.cacheReadNote(dominated),
            "90% cache reads — billed at 1/10 the input rate"
        )

        // Exactly at the threshold, and below it: the raw total speaks for itself.
        XCTAssertNil(DisplayFormat.cacheReadNote(
            TokenUsage(inputTokens: 50_000, cacheReadInputTokens: 50_000)
        ))
        XCTAssertNil(DisplayFormat.cacheReadNote(TokenUsage(inputTokens: 1_000)))
        XCTAssertNil(DisplayFormat.cacheReadNote(.zero))
    }

    /// Mirrors the "By model" table's `shownUsage`: the note under the block is
    /// computed from every band summed for the shown window or day, not from
    /// any single model — a row that alone stays under the threshold can still
    /// push the total over it once combined.
    func testCacheReadNoteOverSummedModelRows() {
        let rows = [
            ModelUsage(
                modelID: "claude-sonnet-5",
                usage: TokenUsage(inputTokens: 30_000, cacheReadInputTokens: 20_000),
                estimatedCostUSD: 0
            ),
            ModelUsage(
                modelID: "claude-opus-5",
                usage: TokenUsage(inputTokens: 10_000, cacheReadInputTokens: 60_000),
                estimatedCostUSD: 0
            ),
        ]
        let total = rows.reduce(TokenUsage.zero) { $0 + $1.usage }

        XCTAssertEqual(total, TokenUsage(inputTokens: 40_000, cacheReadInputTokens: 80_000))
        XCTAssertEqual(
            DisplayFormat.cacheReadNote(total),
            "67% cache reads — billed at 1/10 the input rate"
        )
    }

    /// The share is rounded to a whole percent, both ways — the caption is a
    /// characterisation of the total, not a measurement to a tenth.
    func testCacheReadNoteRoundsTheShareToAWholePercent() {
        // 81.4% → 81%.
        XCTAssertEqual(
            DisplayFormat.cacheReadNote(
                TokenUsage(inputTokens: 18_600, cacheReadInputTokens: 81_400)
            ),
            "81% cache reads — billed at 1/10 the input rate"
        )
        // 81.5% → 82%, and a total that is only just over the threshold still
        // reads as 51% rather than "50%", which would contradict the guard.
        XCTAssertEqual(
            DisplayFormat.cacheReadNote(
                TokenUsage(inputTokens: 18_500, cacheReadInputTokens: 81_500)
            ),
            "82% cache reads — billed at 1/10 the input rate"
        )
        XCTAssertEqual(
            DisplayFormat.cacheReadNote(
                TokenUsage(inputTokens: 49_000, cacheReadInputTokens: 51_000)
            ),
            "51% cache reads — billed at 1/10 the input rate"
        )
        // A hair over the threshold on a small total — 151/300 is 50.33%, which
        // rounds to the threshold itself. The floor keeps it off that number,
        // since a note reading "50%" would contradict the guard that drew it.
        XCTAssertEqual(
            DisplayFormat.cacheReadNote(
                TokenUsage(inputTokens: 149, cacheReadInputTokens: 151)
            ),
            "51% cache reads — billed at 1/10 the input rate"
        )
        // All cache reads: 100%, not 99 or 101.
        XCTAssertEqual(
            DisplayFormat.cacheReadNote(TokenUsage(cacheReadInputTokens: 12_345)),
            "100% cache reads — billed at 1/10 the input rate"
        )
    }

    func testCostFormatting() {
        XCTAssertEqual(DisplayFormat.cost(4.82), "$4.82")
        XCTAssertEqual(DisplayFormat.cost(0), "$0.00")
        XCTAssertEqual(DisplayFormat.cost(3.1), "$3.10")
    }

    // MARK: - compactCost
    //
    // The "Estimated cost" chart's y-axis. Ticks land on round numbers, so the cases
    // that matter are the round ones — `$50.00` is what this exists to avoid.

    func testCompactCostDropsDecimalsAtAndAboveTenDollars() {
        XCTAssertEqual(DisplayFormat.compactCost(50), "$50")
        XCTAssertEqual(DisplayFormat.compactCost(10), "$10")
        XCTAssertEqual(DisplayFormat.compactCost(48.4), "$48")
        XCTAssertEqual(DisplayFormat.compactCost(48.6), "$49")
    }

    func testCompactCostKeepsDecimalsBelowTenDollarsButNotTrailingZeros() {
        // A $2 tick and a $2.50 tick are different readings of the same day,
        // so the decimals have to survive down here — but `$2.00` does not.
        XCTAssertEqual(DisplayFormat.compactCost(2), "$2")
        XCTAssertEqual(DisplayFormat.compactCost(2.5), "$2.5")
        XCTAssertEqual(DisplayFormat.compactCost(0.75), "$0.75")
        XCTAssertEqual(DisplayFormat.compactCost(0.05), "$0.05")
        XCTAssertEqual(DisplayFormat.compactCost(0), "$0")
    }

    func testCompactCostAbbreviatesThousands() {
        XCTAssertEqual(DisplayFormat.compactCost(1_000), "$1k")
        XCTAssertEqual(DisplayFormat.compactCost(1_234), "$1.2k")
    }

    func testCompactCostSignsNegatives() {
        // A cost axis should never see one, but `.automatic` domains and axis
        // probes both can — a bare `$2` for minus two dollars would be a lie.
        XCTAssertEqual(DisplayFormat.compactCost(-2.5), "-$2.5")
        XCTAssertEqual(DisplayFormat.compactCost(-50), "-$50")
    }

    func testCompactCostRefusesValuesAnAxisCannotMean() {
        // Chart frameworks probe a formatter with values of their own choosing.
        // `%f` on these is a 300-digit label, which renders — worse than a nil.
        XCTAssertNil(DisplayFormat.compactCost(.nan))
        XCTAssertNil(DisplayFormat.compactCost(.infinity))
        XCTAssertNil(DisplayFormat.compactCost(-.infinity))
        XCTAssertNil(DisplayFormat.compactCost(.greatestFiniteMagnitude))
        // The cutoff itself: a trillion is out, everything under it still
        // formats — unreadably wide, but a number rather than a refusal.
        XCTAssertNil(DisplayFormat.compactCost(1e12))
        XCTAssertEqual(DisplayFormat.compactCost(999_999_999_999), "$1000000000k")
    }

    // MARK: - money
    //
    // Every case pins the locale: these assert the *currency* handling, and a
    // machine set to de_DE would otherwise fail on `33,00 €`. The locale is a
    // parameter precisely so the app can keep using the user's own.

    private let enUS = Locale(identifier: "en_US")

    func testMoneyFormatsMinorUnitsUsingTheReportedExponent() {
        XCTAssertEqual(
            DisplayFormat.money(MoneyAmount(amountMinor: 0, currency: "EUR", exponent: 2), locale: enUS),
            "€0.00"
        )
        XCTAssertEqual(
            DisplayFormat.money(MoneyAmount(amountMinor: 3_300, currency: "EUR", exponent: 2), locale: enUS),
            "€33.00"
        )
        XCTAssertEqual(
            DisplayFormat.money(MoneyAmount(amountMinor: 3_300, currency: "USD", exponent: 2), locale: enUS),
            "$33.00"
        )
    }

    /// A zero-decimal currency reports `exponent: 0`, so its minor units *are*
    /// whole yen — dividing by a hardcoded 100 would show ¥33 for ¥3,300.
    func testMoneyFormatsAZeroDecimalCurrencyWithoutDecimals() {
        XCTAssertEqual(
            DisplayFormat.money(MoneyAmount(amountMinor: 3_300, currency: "JPY", exponent: 0), locale: enUS),
            "¥3,300"
        )
    }

    func testMoneyGroupsLargeAmounts() {
        XCTAssertEqual(
            DisplayFormat.money(
                MoneyAmount(amountMinor: 1_234_567, currency: "EUR", exponent: 2),
                locale: enUS
            ),
            "€12,345.67"
        )
    }

    /// The credits row's tooltip sentence: money spent and the limit it's
    /// measured against, spoken in full since neither appears together on the
    /// row itself.
    func testMoneySpendReadsUsedOfLimit() {
        XCTAssertEqual(
            DisplayFormat.moneySpend(
                used: MoneyAmount(amountMinor: 0, currency: "EUR", exponent: 2),
                limit: MoneyAmount(amountMinor: 3_300, currency: "EUR", exponent: 2),
                locale: enUS
            ),
            "€0.00 of €33.00"
        )
        XCTAssertEqual(
            DisplayFormat.moneySpend(
                used: MoneyAmount(amountMinor: 1_200, currency: "JPY", exponent: 0),
                limit: MoneyAmount(amountMinor: 50_000, currency: "JPY", exponent: 0),
                locale: enUS
            ),
            "¥1,200 of ¥50,000"
        )
    }

    /// The credits row's own trailing caption: the limit alone, prefixed so
    /// it reads as a continuation of the percentage beside it.
    func testCreditsLimitCaptionReadsOfLimit() {
        XCTAssertEqual(
            DisplayFormat.creditsLimitCaption(
                MoneyAmount(amountMinor: 3_300, currency: "EUR", exponent: 2),
                locale: enUS
            ),
            "of €33.00"
        )
    }

    /// The locale decides placement and separators; the payload decides the
    /// currency and the number of decimals.
    func testMoneyFollowsTheGivenLocalesConventions() {
        let formatted = DisplayFormat.money(
            MoneyAmount(amountMinor: 3_300, currency: "EUR", exponent: 2),
            locale: Locale(identifier: "de_DE")
        )
        // German puts the symbol last, behind a no-break space — but which
        // no-break space (U+00A0, U+202F, ...) is CLDR/ICU-version-specific,
        // so normalize before comparing rather than pinning one byte.
        let normalized = formatted
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
        XCTAssertEqual(normalized, "33,00 €")
    }

    // MARK: - percent

    func testPercentFromFraction() {
        XCTAssertEqual(DisplayFormat.percent(fraction: 0.62), "62%")
        XCTAssertEqual(DisplayFormat.percent(fraction: 0), "0%")
        XCTAssertEqual(DisplayFormat.percent(fraction: 1), "100%")
    }

    func testPercentClampsOutOfRangeValues() {
        XCTAssertEqual(DisplayFormat.percent(fraction: 1.8), "100%")
        XCTAssertEqual(DisplayFormat.percent(fraction: -0.4), "0%")
        XCTAssertEqual(DisplayFormat.percent(percentValue: 118), "100%")
        XCTAssertEqual(DisplayFormat.percent(percentValue: -3), "0%")
    }

    func testPercentFromPercentValue() {
        XCTAssertEqual(DisplayFormat.percent(percentValue: 31), "31%")
        XCTAssertEqual(DisplayFormat.percent(percentValue: 62.4), "62%")
        XCTAssertEqual(DisplayFormat.percent(percentValue: 62.6), "63%")
    }

    func testPercentShowsOneDecimalFrom99Percent() {
        XCTAssertEqual(DisplayFormat.percent(percentValue: 99.4), "99.4%")
        XCTAssertEqual(DisplayFormat.percent(percentValue: 99.96), "100%")
        XCTAssertEqual(DisplayFormat.percent(percentValue: 99), "99%")
        XCTAssertEqual(DisplayFormat.percent(percentValue: 98.96), "99%")
        XCTAssertEqual(DisplayFormat.percent(percentValue: 100), "100%")
        XCTAssertEqual(DisplayFormat.percent(percentValue: 104), "100%")
    }

    // MARK: - clamping / bar geometry

    func testClamped01() {
        XCTAssertEqual(DisplayFormat.clamped01(0.42), 0.42)
        XCTAssertEqual(DisplayFormat.clamped01(0), 0)
        XCTAssertEqual(DisplayFormat.clamped01(1), 1)
        XCTAssertEqual(DisplayFormat.clamped01(1.5), 1)
        XCTAssertEqual(DisplayFormat.clamped01(-2), 0)
    }

    func testClamped01SurvivesNonFiniteInput() {
        // A bar width multiplied by nan makes SwiftUI log layout errors, so this
        // has to collapse to zero rather than propagate.
        XCTAssertEqual(DisplayFormat.clamped01(.nan), 0)
        XCTAssertEqual(DisplayFormat.clamped01(.infinity), 0)
        XCTAssertEqual(DisplayFormat.clamped01(-.infinity), 0)
    }

    func testBarFraction() {
        XCTAssertEqual(DisplayFormat.barFraction(value: 25, total: 100), 0.25)
        XCTAssertEqual(DisplayFormat.barFraction(value: 100, total: 100), 1)
        XCTAssertEqual(DisplayFormat.barFraction(value: 150, total: 100), 1)
    }

    func testBarFractionAvoidsDivisionByZero() {
        XCTAssertEqual(DisplayFormat.barFraction(value: 10, total: 0), 0)
        XCTAssertEqual(DisplayFormat.barFraction(value: 10, total: -5), 0)
        XCTAssertEqual(DisplayFormat.barFraction(value: 0, total: 0), 0)
        XCTAssertEqual(DisplayFormat.barFraction(value: -10, total: 100), 0)
    }

    /// Every entrypoint keeps a row, including the ones with nothing in the
    /// window — an absent row would read as an entrypoint this Mac has never
    /// used rather than an idle one. No view reads this breakdown any more (the
    /// popover's "By source" block is built from `DailyUsageHistory`, which
    /// keeps the same rule), so this pins the data layer's own contract.
    func testEmptyBreakdownStillHasARowPerEntrypoint() {
        let rows = EntrypointBreakdown.empty(window: .fiveHour).orderedRows
        XCTAssertEqual(rows.map(\.entrypoint), Entrypoint.displayOrder)
        XCTAssertTrue(rows.allSatisfy { $0.usage.totalTokens == 0 })
    }

    // MARK: - Axis labels

    func testATokenAxisIsLabelledInOneUnit() {
        // The reading this fixes: `1.5G / 1G / 500M / 0` makes the eye convert
        // `500M` into `0.5G` before the steps look even.
        XCTAssertEqual(
            DisplayFormat.tokenAxisLabels([0, 500_000_000, 1_000_000_000, 1_500_000_000]),
            ["", "0.5G", "1.0G", "1.5G"]
        )
        // Round steps keep their decimals off — the column is narrow.
        XCTAssertEqual(DisplayFormat.tokenAxisLabels([0, 1_000_000, 2_000_000, 3_000_000]), ["", "1M", "2M", "3M"])
        // The unit comes from the largest value, so a quarter-million step is
        // still labelled in `k` rather than being pushed up to `0.25M`.
        XCTAssertEqual(DisplayFormat.tokenAxisLabels([0, 250_000, 500_000, 750_000]), ["", "250k", "500k", "750k"])
        // Below a thousand there is no unit to share.
        XCTAssertEqual(DisplayFormat.tokenAxisLabels([0, 400, 800]), ["", "400", "800"])
    }

    func testACostAxisKeepsMoneysDecimals() {
        // Two decimals or none: `$2.5` is not how money is written, and every
        // label on the axis carries the same number of them.
        XCTAssertEqual(DisplayFormat.costAxisLabels([0, 2.5, 5]), ["", "$2.50", "$5.00"])
        XCTAssertEqual(DisplayFormat.costAxisLabels([0, 0.5, 1]), ["", "$0.50", "$1.00"])
        XCTAssertEqual(DisplayFormat.costAxisLabels([0, 2, 4, 6]), ["", "$2", "$4", "$6"])
        // `k` carries one decimal, as `compactCost` does — `$1.50k` reads as a
        // typo where `$1.5k` reads as a number.
        XCTAssertEqual(DisplayFormat.costAxisLabels([0, 500, 1_000, 1_500]), ["", "$0.5k", "$1.0k", "$1.5k"])
    }

    func testZeroGoesUnlabelledOnEveryAxis() {
        // Both charts scale from zero, so the bottom line is zero by
        // construction — the label only restates it, in the narrowest column
        // the popover has. Empty rather than dropped, so the labels stay
        // index-for-index with the values they came from.
        XCTAssertEqual(DisplayFormat.tokenAxisLabels([0, 1_500_000_000]), ["", "1.5G"])
        XCTAssertEqual(DisplayFormat.costAxisLabels([0, 1_500]), ["", "$1.5k"])
        XCTAssertEqual(DisplayFormat.tokenAxisLabels([]), [])
    }
}
