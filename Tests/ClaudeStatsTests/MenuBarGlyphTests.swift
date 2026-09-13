import ClaudeStatsCore
import XCTest

@testable import ClaudeStats

/// Geometry and accessibility only — the drawing itself is checked by eye
/// against the `#Preview` in `MenuBarGlyph.swift`, since a rendered template
/// image has nothing stable to assert on.
@MainActor
final class MenuBarGlyphTests: XCTestCase {
    private let capturedAt = Date(timeIntervalSince1970: 1_787_935_500)

    private func snapshot(
        scopedWeekly: [QuotaScopedLimit],
        usageCredits: UsageCredits? = nil
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            fiveHour: QuotaWindow(percentUsed: 62),
            sevenDay: QuotaWindow(percentUsed: 31),
            confidence: .cachedOfficial,
            capturedAt: capturedAt,
            scopedWeekly: scopedWeekly,
            usageCredits: usageCredits
        )
    }

    private func credits(percentUsed: Double) -> UsageCredits {
        UsageCredits(
            used: MoneyAmount(amountMinor: Int(percentUsed * 33), currency: "EUR", exponent: 2),
            limit: MoneyAmount(amountMinor: 3_300, currency: "EUR", exponent: 2),
            percentUsed: percentUsed
        )
    }

    // MARK: - Width

    /// Expected width for `count` bars, spelled out independently of the
    /// implementation's own arithmetic.
    private func expectedWidth(bars count: Int) -> CGFloat {
        MenuBarGlyph.markSize + MenuBarGlyph.markToBarsGap
            + MenuBarGlyph.barWidth * CGFloat(count)
            + MenuBarGlyph.barSpacing * CGFloat(count - 1)
    }

    func testWidthScalesWithTheBarCount() {
        XCTAssertEqual(MenuBarGlyph.width(barCount: 2), expectedWidth(bars: 2), accuracy: 0.001)
        XCTAssertEqual(MenuBarGlyph.width(barCount: 3), expectedWidth(bars: 3), accuracy: 0.001)
        XCTAssertEqual(MenuBarGlyph.width(barCount: 4), expectedWidth(bars: 4), accuracy: 0.001)
        // Each extra bar costs exactly one bar plus one gap.
        XCTAssertEqual(
            MenuBarGlyph.width(barCount: 4) - MenuBarGlyph.width(barCount: 3),
            MenuBarGlyph.barWidth + MenuBarGlyph.barSpacing,
            accuracy: 0.001
        )
    }

    /// ``MenuBarGlyph/width`` stays the no-credits width — the one static
    /// layout (the dev-build dot) is positioned against it.
    func testDefaultWidthIsTheThreeBarWidth() {
        XCTAssertEqual(MenuBarGlyph.width, expectedWidth(bars: 3), accuracy: 0.001)
        XCTAssertEqual(MenuBarGlyph.baseBarCount, 3)
        XCTAssertEqual(MenuBarGlyph.maxBarCount, 4)
    }

    // MARK: - Rendered image

    /// Same width and height whether or not the snapshot carries a scoped
    /// limit — the third bar is always drawn, just empty when there's nothing
    /// to show.
    func testImageSizeDoesNotDependOnScopedLimits() {
        let plain = MenuBarGlyph.image(for: snapshot(scopedWeekly: []))
        let scoped = MenuBarGlyph.image(for: snapshot(scopedWeekly: [
            QuotaScopedLimit(label: "Fable", percentUsed: 0),
        ]))

        XCTAssertEqual(plain.size.width, MenuBarGlyph.width, accuracy: 0.001)
        XCTAssertEqual(scoped.size.width, MenuBarGlyph.width, accuracy: 0.001)
        XCTAssertEqual(plain.size.width, scoped.size.width, accuracy: 0.001)
        XCTAssertEqual(plain.size.height, MenuBarGlyph.height, accuracy: 0.001)
        XCTAssertEqual(scoped.size.height, MenuBarGlyph.height, accuracy: 0.001)
    }

    func testImageSizeDoesNotDependOnTheSnapshotBeingNil() {
        let nilImage = MenuBarGlyph.image(for: nil)
        let plainImage = MenuBarGlyph.image(for: snapshot(scopedWeekly: []))

        XCTAssertEqual(nilImage.size.width, plainImage.size.width, accuracy: 0.001)
        XCTAssertEqual(nilImage.size.height, MenuBarGlyph.height, accuracy: 0.001)
    }

    /// The bar takes the highest-percentage scope, which is
    /// ``QuotaSnapshot/scopedWeekly``'s first element by construction.
    func testAccessibilityDescriptionNamesTheHighestScope() throws {
        let image = MenuBarGlyph.image(for: snapshot(scopedWeekly: [
            QuotaScopedLimit(label: "Sonnet", percentUsed: 42),
            QuotaScopedLimit(label: "Fable", percentUsed: 0),
        ]))

        let description = try XCTUnwrap(image.accessibilityDescription)
        XCTAssertTrue(description.hasSuffix("62% five-hour, 31% seven-day, 42% Sonnet weekly usage"),
                      "unexpected description: \(description)")
    }

    /// No scoped limit still names the (empty) third bar, unlabelled — the
    /// row is always there, same as the other two.
    func testAccessibilityDescriptionNamesAnEmptyThirdBarWithoutAScopedLimit() throws {
        let image = MenuBarGlyph.image(for: snapshot(scopedWeekly: []))

        let description = try XCTUnwrap(image.accessibilityDescription)
        XCTAssertTrue(description.hasSuffix("62% five-hour, 31% seven-day, 0% weekly usage"),
                      "unexpected description: \(description)")
    }

    /// No snapshot means no reading for either account-wide window, and the
    /// description says so — "0%" would be a claim nothing made.
    func testAccessibilityDescriptionForANilSnapshotSaysUnknownNotZero() throws {
        let description = try XCTUnwrap(MenuBarGlyph.image(for: nil).accessibilityDescription)
        XCTAssertTrue(
            description.hasSuffix("five-hour unknown, seven-day unknown, 0% weekly usage"),
            "unexpected description: \(description)"
        )
    }

    /// The two windows are independent: one can be unreported while the other
    /// reads normally — the state right after the 5-hour window rolls over.
    func testAccessibilityDescriptionNamesOnlyTheUnreportedWindowAsUnknown() throws {
        let image = MenuBarGlyph.image(for: QuotaSnapshot(
            fiveHour: nil,
            sevenDay: QuotaWindow(percentUsed: 31),
            confidence: .official,
            capturedAt: capturedAt
        ))

        let description = try XCTUnwrap(image.accessibilityDescription)
        XCTAssertTrue(
            description.hasSuffix("five-hour unknown, 31% seven-day, 0% weekly usage"),
            "unexpected description: \(description)"
        )
    }

    /// The mirror case: the five-hour window reads normally while the
    /// seven-day one is unreported — the independent `sevenDayText` branch
    /// gets its own coverage instead of only ever running alongside the
    /// five-hour branch.
    func testAccessibilityDescriptionNamesOnlyTheOtherUnreportedWindowAsUnknown() throws {
        let image = MenuBarGlyph.image(for: QuotaSnapshot(
            fiveHour: QuotaWindow(percentUsed: 62),
            sevenDay: nil,
            confidence: .official,
            capturedAt: capturedAt
        ))

        let description = try XCTUnwrap(image.accessibilityDescription)
        XCTAssertTrue(
            description.hasSuffix("62% five-hour, seven-day unknown, 0% weekly usage"),
            "unexpected description: \(description)"
        )
    }

    /// An unknown window draws the same empty track a 0% one does — the glyph
    /// keeps its three bars and its width; only the VoiceOver text differs.
    func testImageSizeDoesNotDependOnAWindowBeingUnreported() {
        let unknown = MenuBarGlyph.image(for: QuotaSnapshot(
            fiveHour: nil,
            sevenDay: nil,
            confidence: .official,
            capturedAt: capturedAt
        ))
        let known = MenuBarGlyph.image(for: snapshot(scopedWeekly: []))

        XCTAssertEqual(unknown.size.width, known.size.width, accuracy: 0.001)
        XCTAssertEqual(unknown.size.width, MenuBarGlyph.width(barCount: 3), accuracy: 0.001)
        XCTAssertEqual(unknown.size.height, MenuBarGlyph.height, accuracy: 0.001)
    }

    // MARK: - Usage credits bar

    /// Unlike the scoped bar, this one is conditional: credits are transient,
    /// and an always-drawn empty fourth bar would imply a spend cap the
    /// account may not have.
    func testUsageCreditsAddAFourthBarToTheGlyphWidth() {
        let without = MenuBarGlyph.image(for: snapshot(scopedWeekly: []))
        let with = MenuBarGlyph.image(for: snapshot(
            scopedWeekly: [],
            usageCredits: credits(percentUsed: 40)
        ))

        XCTAssertEqual(without.size.width, MenuBarGlyph.width(barCount: 3), accuracy: 0.001)
        XCTAssertEqual(with.size.width, MenuBarGlyph.width(barCount: 4), accuracy: 0.001)
        XCTAssertEqual(with.size.height, MenuBarGlyph.height, accuracy: 0.001)
    }

    /// 0% of a real spend cap is a reading, not an absence — the bar is drawn.
    func testZeroPercentCreditsStillDrawTheFourthBar() {
        let image = MenuBarGlyph.image(for: snapshot(
            scopedWeekly: [],
            usageCredits: credits(percentUsed: 0)
        ))

        XCTAssertEqual(image.size.width, MenuBarGlyph.width(barCount: 4), accuracy: 0.001)
    }

    func testAccessibilityDescriptionNamesTheCreditsBarOnlyWhenItIsDrawn() throws {
        let with = try XCTUnwrap(MenuBarGlyph.image(for: snapshot(
            scopedWeekly: [QuotaScopedLimit(label: "Fable", percentUsed: 0)],
            usageCredits: credits(percentUsed: 40)
        )).accessibilityDescription)
        XCTAssertTrue(with.hasSuffix("0% Fable weekly usage, 40% usage credits"),
                      "unexpected description: \(with)")

        let without = try XCTUnwrap(MenuBarGlyph.image(for: snapshot(
            scopedWeekly: [QuotaScopedLimit(label: "Fable", percentUsed: 0)]
        )).accessibilityDescription)
        XCTAssertFalse(without.contains("usage credits"), "unexpected description: \(without)")
    }
}
