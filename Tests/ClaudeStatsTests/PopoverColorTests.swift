import AppKit
import XCTest
@testable import ClaudeStats

/// Coverage for the popover's colour system: the one brand colour and the
/// five-step band ramp derived from it.
///
/// These are measurements, not preferences. Both values are dynamic
/// `NSColor`s that resolve differently per appearance, and the whole point of
/// the ramp is a contrast range that holds in *both* — a literal edited by eye
/// in one theme is the failure this guards.
final class PopoverColorTests: XCTestCase {

    // MARK: - Measuring

    /// The two backgrounds the colours are documented against: white for the
    /// light popover, and the dark popover's own ≈`#232323`.
    private static let lightBackground = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    private static let darkBackground = NSColor(srgbRed: 0x23 / 255, green: 0x23 / 255, blue: 0x23 / 255, alpha: 1)

    /// What a dynamic colour actually paints in one appearance.
    private func resolved(_ color: NSColor, _ name: NSAppearance.Name) throws -> NSColor {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        var result: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB)
        }
        return try XCTUnwrap(result)
    }

    private func hex(_ color: NSColor) -> String {
        String(
            format: "%02X%02X%02X",
            Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded())
        )
    }

    /// WCAG 2.2 relative luminance.
    private func luminance(_ color: NSColor) -> CGFloat {
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.redComponent)
            + 0.7152 * channel(color.greenComponent)
            + 0.0722 * channel(color.blueComponent)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let (high, low) = luminance(a) > luminance(b) ? (a, b) : (b, a)
        return (luminance(high) + 0.05) / (luminance(low) + 0.05)
    }

    private func bandContrasts(_ name: NSAppearance.Name, against background: NSColor) throws -> [CGFloat] {
        try PopoverMetrics.chartBandNSColors.map { contrast(try resolved($0, name), background) }
    }

    // MARK: - Brand colour

    func testTheBrandColourIsTheTwoDocumentedLiterals() throws {
        // `#CA7C5E` — one literal for both appearances — measured 3.17:1 on a
        // light card, under the 4.5:1 AA floor for caption-size text. These two
        // are what replaced it, and the numbers below are why.
        XCTAssertEqual(hex(try resolved(PopoverMetrics.brandNSColor, .aqua)), "A85E3E")
        XCTAssertEqual(hex(try resolved(PopoverMetrics.brandNSColor, .darkAqua)), "E88A5C")
    }

    func testTheBrandColourClearsAAContrastInBothAppearances() throws {
        XCTAssertGreaterThanOrEqual(
            contrast(try resolved(PopoverMetrics.brandNSColor, .aqua), Self.lightBackground),
            4.5,
            "brand text on the light popover falls below WCAG AA"
        )
        XCTAssertGreaterThanOrEqual(
            contrast(try resolved(PopoverMetrics.brandNSColor, .darkAqua), Self.darkBackground),
            4.5,
            "brand text on the dark popover falls below WCAG AA"
        )
    }

    // MARK: - Band ramp

    func testTheRampHasFiveShadesLedByTheBrandColour() throws {
        // Five because the model chart has four families plus "Other"; the
        // source chart takes the first four. The leading shade is the brand
        // colour itself, which is what lets the cost line say "the same ink as
        // the first band" by construction.
        XCTAssertEqual(PopoverMetrics.chartBandNSColors.count, 5)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            XCTAssertEqual(
                hex(try resolved(PopoverMetrics.chartBandNSColors[0], name)),
                hex(try resolved(PopoverMetrics.brandNSColor, name))
            )
        }
        XCTAssertEqual(PopoverMetrics.chartBandColors.count, PopoverMetrics.chartBandNSColors.count)
    }

    func testTheRampMeasuresWhatItsDocumentationClaims() throws {
        let light = try bandContrasts(.aqua, against: Self.lightBackground)
        let dark = try bandContrasts(.darkAqua, against: Self.darkBackground)

        for (measured, expected) in zip(light, [4.84, 3.77, 2.94, 2.31, 1.80] as [CGFloat]) {
            XCTAssertEqual(measured, expected, accuracy: 0.02)
        }
        for (measured, expected) in zip(dark, [6.15, 4.79, 3.75, 2.92, 2.29] as [CGFloat]) {
            XCTAssertEqual(measured, expected, accuracy: 0.02)
        }
    }

    func testEveryStepIsWeakerThanTheOneBeforeItByAVisibleMargin() throws {
        // Two touching bands of a stack are only told apart by this step. 1.2
        // is the floor; the ramp is built on ≈1.28.
        for (name, background) in [(NSAppearance.Name.aqua, Self.lightBackground), (.darkAqua, Self.darkBackground)] {
            let contrasts = try bandContrasts(name, against: background)
            for index in 1..<contrasts.count {
                XCTAssertGreaterThanOrEqual(
                    contrasts[index - 1] / contrasts[index],
                    1.2,
                    "bands \(index - 1) and \(index) are too close to tell apart in \(name.rawValue)"
                )
            }
        }
    }

    func testThePaleEndStaysVisibleAgainstItsOwnBackground() throws {
        // The bound the ramp exists for: shades stop short of the card rather
        // than running to white or black. The monochrome ramp this replaced
        // ended at 1.78:1 (`Color.primary` at 0.24 opacity on white), so that
        // is the precedent for how faint a band may get.
        for (name, background) in [(NSAppearance.Name.aqua, Self.lightBackground), (.darkAqua, Self.darkBackground)] {
            let last = try XCTUnwrap(try bandContrasts(name, against: background).last)
            XCTAssertGreaterThanOrEqual(last, 1.78, "the palest band vanishes into the \(name.rawValue) card")
        }
    }

    func testEveryShadeIsTerracottaRatherThanAGrey() throws {
        // A ramp is a ramp of *one hue*: the popover's rule is brand terracotta
        // or ink, and a step that has desaturated into grey has left the ramp.
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            for (index, band) in PopoverMetrics.chartBandNSColors.enumerated() {
                let color = try resolved(band, name)
                XCTAssertGreaterThan(color.redComponent, color.greenComponent, "band \(index) in \(name.rawValue)")
                XCTAssertGreaterThan(color.greenComponent, color.blueComponent, "band \(index) in \(name.rawValue)")
                // HSB saturation, which reads lower than the HSL figure the
                // ramp was designed in: the palest light shade `#DCBAAB` is 42%
                // there and 0.22 here.
                XCTAssertGreaterThan(color.saturationComponent, 0.2, "band \(index) in \(name.rawValue) is a grey")
            }
        }
    }

    func testAnIndexPastTheRampClampsRatherThanWrapping() {
        // Wrapping would paint a sixth band in the first band's ink and tie its
        // legend dot to the wrong stripe; repeating the palest shade only makes
        // two faint bands hard to tell apart.
        XCTAssertEqual(DailyUsageSeries.bandColor(0), PopoverMetrics.chartBandColors[0])
        XCTAssertEqual(DailyUsageSeries.bandColor(4), PopoverMetrics.chartBandColors[4])
        XCTAssertEqual(DailyUsageSeries.bandColor(9), PopoverMetrics.chartBandColors[4])
    }
}
