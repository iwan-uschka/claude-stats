import AppKit
import SwiftUI
import XCTest
@testable import ClaudeStats

/// Coverage for the one typographic rule the popover has: **a number is set in
/// monospaced digits, a word is not.**
///
/// Every figure on the card sits in a right-aligned column of fixed width — the
/// percentages, the countdowns, both chart axes, both table columns — and a
/// proportional `1` is narrower than a proportional `8`, so a column of
/// proportional figures doesn't line up on its digits and a ticking one
/// visibly reflows. The labels and headings beside them stay proportional:
/// only digits gain from a fixed advance, and widening the letters of
/// `Estimated cost` would cost the column the width it was measured for.
final class PopoverFontTests: XCTestCase {

    private func width(_ string: String, _ font: NSFont) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: font]).width
    }

    private let digits = (0...9).map(String.init)

    // MARK: - The fonts themselves

    func testTheValueFontsAreTheMonospacedDigitVariantsOfTheirLabelFonts() {
        // Same family and same size as the font the label beside them is set
        // in — the two differ in digit advance and in nothing else, so a
        // numeric caption still reads as a caption.
        XCTAssertEqual(PopoverMetrics.valueFont, Font.system(size: 11).monospacedDigit())
        XCTAssertEqual(
            PopoverMetrics.captionValueFont,
            Font.system(size: PopoverMetrics.captionFontSize).monospacedDigit()
        )
        XCTAssertNotEqual(PopoverMetrics.valueFont, PopoverMetrics.bodyFont)
        XCTAssertNotEqual(PopoverMetrics.captionValueFont, PopoverMetrics.captionFont)
    }

    func testEveryDigitHasTheSameAdvanceInTheValueFonts() {
        // What "monospaced digit" buys, measured: `111` and `888` occupy the
        // same width, so a column of figures aligns on its digits and a
        // countdown ticking from `2h 14m` to `2h 9m` doesn't shuffle.
        for font in [
            PopoverMetrics.captionValueNSFont,
            NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
        ] {
            let widths = digits.map { width($0, font) }
            for (digit, advance) in zip(digits, widths) {
                XCTAssertEqual(advance, widths[0], accuracy: 0.001, "\(digit) is a different width in \(font.fontName)")
            }
        }
    }

    func testTheProportionalFontsTheyReplaceDoNotAlignTheirDigits() {
        // The other half of the claim: this is a real difference, not two
        // spellings of the same font. If the system font ever did align its
        // digits, every assertion above would be vacuous.
        XCTAssertNotEqual(
            Set(digits.map { width($0, PopoverMetrics.captionNSFont) }).count,
            1,
            "the proportional caption font already aligns its digits"
        )
    }

    // MARK: - The columns they are drawn in

    func testTheCountdownColumnStillHoldsItsWidestStringsInTheMonospacedFont() {
        // Monospacing the countdowns widens some of their digits, and since the
        // placeholders were shortened (`pending`, `no data`) it is a *countdown*
        // that is the widest string in this column — `11d 11h`, at 40.9 of the
        // column's 51 pt. So this is the measurement that sizes it, not a
        // re-check of one taken in the proportional font.
        for text in ["pending", "no data", "2h 14m", "6d 23h", "11d 11h", "88m"] {
            XCTAssertLessThanOrEqual(
                width(text, PopoverMetrics.captionValueNSFont),
                PopoverMetrics.countdownColumnWidth,
                "\(text) overflows the countdown column"
            )
        }
    }

    func testTheChartsLabelColumnIsMeasuredInTheFontItIsDrawnIn() {
        // The shared y-label column is measured, not reserved — and it is the
        // axis's own monospaced font that has to do the measuring, or the two
        // plots start at an x neither of their labels actually ends at.
        let labels = ["$12.5k", "$1.0k", "$0.5k"]
        XCTAssertEqual(
            PopoverChartAxis.yLabelWidth(of: labels),
            labels.map { width($0, PopoverMetrics.captionValueNSFont) }.max() ?? 0,
            accuracy: 0.001
        )
    }
}
