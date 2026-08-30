import ClaudeStatsCore
import XCTest

@testable import ClaudeStats

/// Geometry and accessibility only — the drawing itself is checked by eye
/// against the `#Preview` in `MenuBarGlyph.swift`, since a rendered template
/// image has nothing stable to assert on.
@MainActor
final class MenuBarGlyphTests: XCTestCase {
    private let capturedAt = Date(timeIntervalSince1970: 1_787_935_500)

    private func snapshot(scopedWeekly: [QuotaScopedLimit]) -> QuotaSnapshot {
        QuotaSnapshot(
            fiveHour: QuotaWindow(percentUsed: 62),
            sevenDay: QuotaWindow(percentUsed: 31),
            confidence: .cachedOfficial,
            capturedAt: capturedAt,
            scopedWeekly: scopedWeekly
        )
    }

    // MARK: - Width

    func testWidthGrowsByExactlyOneBarForTheThirdBar() {
        let two = MenuBarGlyph.width(barCount: 2)
        let three = MenuBarGlyph.width(barCount: 3)

        XCTAssertEqual(
            two,
            MenuBarGlyph.markSize + MenuBarGlyph.markToBarsGap
                + MenuBarGlyph.barWidth * 2 + MenuBarGlyph.barSpacing,
            accuracy: 0.001
        )
        XCTAssertEqual(
            three - two,
            MenuBarGlyph.barWidth + MenuBarGlyph.barSpacing,
            accuracy: 0.001
        )
    }

    /// The two-bar width is the default, so the dev-build dot and any other
    /// caller of the bare property keep their previous geometry.
    func testBareWidthPropertyIsTheTwoBarWidth() {
        XCTAssertEqual(MenuBarGlyph.width, MenuBarGlyph.width(barCount: 2), accuracy: 0.001)
    }

    // MARK: - Bar count

    func testBarCountIsTwoWithoutScopedLimitsAndThreeWithThem() {
        XCTAssertEqual(MenuBarGlyph.barCount(for: nil), 2)
        XCTAssertEqual(MenuBarGlyph.barCount(for: snapshot(scopedWeekly: [])), 2)
        XCTAssertEqual(
            MenuBarGlyph.barCount(for: snapshot(scopedWeekly: [
                QuotaScopedLimit(label: "Fable", percentUsed: 0),
            ])),
            3
        )
        // However many scopes the payload carries, the glyph shows one — the
        // popover is where the full list lives.
        XCTAssertEqual(
            MenuBarGlyph.barCount(for: snapshot(scopedWeekly: [
                QuotaScopedLimit(label: "Sonnet", percentUsed: 42),
                QuotaScopedLimit(label: "Opus", percentUsed: 12),
                QuotaScopedLimit(label: "Fable", percentUsed: 0),
            ])),
            3
        )
    }

    // MARK: - Rendered image

    func testImageIsOneBarWiderWhenASnapshotCarriesAScopedLimit() {
        let plain = MenuBarGlyph.image(for: snapshot(scopedWeekly: []))
        let scoped = MenuBarGlyph.image(for: snapshot(scopedWeekly: [
            QuotaScopedLimit(label: "Fable", percentUsed: 0),
        ]))

        XCTAssertEqual(plain.size.width, MenuBarGlyph.width(barCount: 2), accuracy: 0.001)
        XCTAssertEqual(scoped.size.width, MenuBarGlyph.width(barCount: 3), accuracy: 0.001)
        XCTAssertEqual(plain.size.height, MenuBarGlyph.height, accuracy: 0.001)
        XCTAssertEqual(scoped.size.height, MenuBarGlyph.height, accuracy: 0.001)
    }

    /// The bar takes the highest-percentage scope, which is
    /// ``QuotaSnapshot/scopedWeekly``'s first element by construction.
    func testAccessibilityDescriptionNamesTheHighestScope() throws {
        let image = MenuBarGlyph.image(for: snapshot(scopedWeekly: [
            QuotaScopedLimit(label: "Sonnet", percentUsed: 42),
            QuotaScopedLimit(label: "Fable", percentUsed: 0),
        ]))

        let description = try XCTUnwrap(image.accessibilityDescription)
        XCTAssertTrue(description.hasSuffix("62% five-hour, 31% seven-day usage, 42% Sonnet weekly"),
                      "unexpected description: \(description)")
    }

    func testAccessibilityDescriptionKeepsTwoWindowsWithoutAScopedLimit() throws {
        let image = MenuBarGlyph.image(for: snapshot(scopedWeekly: []))

        let description = try XCTUnwrap(image.accessibilityDescription)
        XCTAssertTrue(description.hasSuffix("62% five-hour, 31% seven-day usage"),
                      "unexpected description: \(description)")
        XCTAssertFalse(description.contains("weekly"))
    }
}
