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
            "resets in 2h 14m"
        )
    }

    func testResetCountdownFallsBackWhenUnknownOrElapsed() {
        XCTAssertEqual(DisplayFormat.resetCountdown(nil), "reset pending")
        XCTAssertEqual(DisplayFormat.resetCountdown(0), "reset pending")
        XCTAssertEqual(DisplayFormat.resetCountdown(-5), "reset pending")
    }

    func testResetCountdownUsesTheWindowsOwnDeadline() {
        let now = Date()
        let window = QuotaWindow(
            percentUsed: 62,
            resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60)
        )
        XCTAssertEqual(
            DisplayFormat.resetCountdown(window.timeUntilReset(from: now)),
            "resets in 2h 14m"
        )
    }

    // MARK: - age

    func testAgeWording() {
        XCTAssertEqual(DisplayFormat.age(40), "40s ago")
        XCTAssertEqual(DisplayFormat.age(5 * 60 + 30), "5m ago")
        XCTAssertEqual(DisplayFormat.age(2 * 3600), "2h ago")
        XCTAssertEqual(DisplayFormat.age(3 * 86_400 + 3600), "3d ago")
    }

    func testAgeCollapsesSubSecondAndNegativeToJustNow() {
        XCTAssertEqual(DisplayFormat.age(0), "just now")
        XCTAssertEqual(DisplayFormat.age(0.4), "just now")
        XCTAssertEqual(DisplayFormat.age(-30), "just now")
        XCTAssertEqual(DisplayFormat.age(.nan), "just now")
    }

    func testSourceTagMatchesTheMockupLine() {
        XCTAssertEqual(
            DisplayFormat.sourceTag(confidence: .official, age: 40),
            "source: official · 40s ago"
        )
        XCTAssertEqual(
            DisplayFormat.sourceTag(confidence: .official, age: 12 * 60),
            "source: official · 12m ago"
        )
    }

    func testSourceTagReadsFromASnapshot() {
        let now = Date()
        let snapshot = MockQuotaProvider.sampleSnapshot(now: now)
        XCTAssertEqual(
            DisplayFormat.sourceTag(
                confidence: snapshot.confidence,
                age: snapshot.age(asOf: now)
            ),
            "source: official · 40s ago"
        )
    }

    // MARK: - tokens

    func testTokenCountsMatchTheMockup() {
        XCTAssertEqual(DisplayFormat.tokens(2_100_000), "2.1M")
        XCTAssertEqual(DisplayFormat.tokens(180_000), "180k")
        XCTAssertEqual(DisplayFormat.tokens(640_000), "640k")
        XCTAssertEqual(DisplayFormat.tokens(90_000), "90k")
    }

    func testTokenCountsTrimTrailingZeroDecimal() {
        XCTAssertEqual(DisplayFormat.tokens(12_400), "12.4k")
        XCTAssertEqual(DisplayFormat.tokens(12_000), "12k")
        XCTAssertEqual(DisplayFormat.tokens(1_000_000), "1M")
        XCTAssertEqual(DisplayFormat.tokens(1_050_000), "1.1M")
    }

    func testTokenCountsBelowAThousandStayExact() {
        XCTAssertEqual(DisplayFormat.tokens(0), "0")
        XCTAssertEqual(DisplayFormat.tokens(1), "1")
        XCTAssertEqual(DisplayFormat.tokens(999), "999")
    }

    func testTokenCountsHandleNegatives() {
        XCTAssertEqual(DisplayFormat.tokens(-5_400), "-5.4k")
    }

    func testBurnRateWording() {
        XCTAssertEqual(DisplayFormat.burnRate(12_400), "12.4k tok/hr")
        XCTAssertEqual(DisplayFormat.burnRate(0), "0 tok/hr")
    }

    func testCostFormatting() {
        XCTAssertEqual(DisplayFormat.cost(4.82), "$4.82")
        XCTAssertEqual(DisplayFormat.cost(0), "$0.00")
        XCTAssertEqual(DisplayFormat.cost(3.1), "$3.10")
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

    func testBreakdownRowsScaleAgainstThePeakRow() {
        let breakdown = MockUsageStore.sampleBreakdowns[.twentyFourHour]!
        let rows = breakdown.orderedRows
        let peak = rows.map(\.tokens).max() ?? 0
        let fractions = rows.map {
            DisplayFormat.barFraction(value: $0.tokens, peak: peak)
        }

        // Exactly one row is full-width, and every row is inside 0...1.
        XCTAssertEqual(fractions.filter { $0 == 1 }.count, 1)
        XCTAssertTrue(fractions.allSatisfy { $0 >= 0 && $0 <= 1 })
        // sdk-cli is the busiest entrypoint in the sample data.
        XCTAssertEqual(rows.max { $0.tokens < $1.tokens }?.entrypoint, .sdkAgent)
    }

    func testEmptyBreakdownProducesAllZeroFractions() {
        let rows = EntrypointBreakdown.empty(window: .fiveHour).orderedRows
        let peak = rows.map(\.tokens).max() ?? 0
        XCTAssertEqual(rows.count, Entrypoint.displayOrder.count)
        XCTAssertTrue(rows.allSatisfy {
            DisplayFormat.barFraction(value: $0.tokens, peak: peak) == 0
        })
    }

    // MARK: - plan

    func testPlanDescriptionForKnownTiers() {
        XCTAssertEqual(DisplayFormat.planDescription(.max20), "Max20 (auto-detected)")
        XCTAssertEqual(DisplayFormat.planDescription(.max5), "Max5 (auto-detected)")
        XCTAssertEqual(DisplayFormat.planDescription(.pro), "Pro (auto-detected)")
    }

    func testPlanDescriptionForCustomTierShowsTheEstimatedBudget() {
        XCTAssertEqual(
            DisplayFormat.planDescription(.custom(tokens: 145_000)),
            "Custom (~145k tok/5h)"
        )
    }

    func testPlanDescriptionBeforeDetection() {
        XCTAssertEqual(DisplayFormat.planDescription(nil), "detecting…")
    }
}
