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

    /// The glyph is always three bars wide — no narrower state to fall back
    /// to, so this is the only width there is.
    func testWidthIsAlwaysThreeBars() {
        XCTAssertEqual(
            MenuBarGlyph.width,
            MenuBarGlyph.markSize + MenuBarGlyph.markToBarsGap
                + MenuBarGlyph.barWidth * 3 + MenuBarGlyph.barSpacing * 2,
            accuracy: 0.001
        )
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
        XCTAssertEqual(
            MenuBarGlyph.image(for: nil).size.width,
            MenuBarGlyph.image(for: snapshot(scopedWeekly: [])).size.width,
            accuracy: 0.001
        )
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

    func testAccessibilityDescriptionForANilSnapshotIsAllZero() throws {
        let description = try XCTUnwrap(MenuBarGlyph.image(for: nil).accessibilityDescription)
        XCTAssertTrue(description.hasSuffix("0% five-hour, 0% seven-day, 0% weekly usage"),
                      "unexpected description: \(description)")
    }
}
