import AppKit
import XCTest
@testable import ClaudeStats

/// Coverage for the popover's colour system: the one brand colour and the
/// shade-by-position band ramp derived from it.
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

    /// HSL, measured here rather than taken off `NSColor` — which reports HSB,
    /// a different saturation figure. The ramp is defined in HSL, so that is
    /// the space the muting has to be checked in.
    private static func hsl(red: CGFloat, green: CGFloat, blue: CGFloat) -> (hue: CGFloat, saturation: CGFloat, lightness: CGFloat) {
        let high = max(red, green, blue)
        let low = min(red, green, blue)
        let chroma = high - low
        let lightness = (high + low) / 2
        guard chroma > 0 else { return (0, 0, lightness) }
        let saturation = chroma / (1 - abs(2 * lightness - 1))
        let sector: CGFloat
        if high == red {
            sector = ((green - blue) / chroma).truncatingRemainder(dividingBy: 6)
        } else if high == green {
            sector = (blue - red) / chroma + 2
        } else {
            sector = (red - green) / chroma + 4
        }
        return ((sector * 60 + 360).truncatingRemainder(dividingBy: 360), saturation, lightness)
    }

    private static func hsl(of color: NSColor) -> (hue: CGFloat, saturation: CGFloat, lightness: CGFloat) {
        hsl(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
    }

    /// The same, for one of the unmuted `0xRRGGBB` literals the ramp is built
    /// from — the thing the painted colour is compared against.
    private static func hsl(ofHex hex: Int) -> (hue: CGFloat, saturation: CGFloat, lightness: CGFloat) {
        hsl(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255
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

    /// The contrast of every band of a `count`-band stack against its own card.
    private func bandContrasts(
        _ count: Int,
        _ name: NSAppearance.Name,
        against background: NSColor
    ) throws -> [CGFloat] {
        try (0..<count).map { contrast(try resolved(PopoverMetrics.chartBandNSColor($0, of: count), name), background) }
    }

    /// The two appearances with the card each is measured against.
    private var cards: [(NSAppearance.Name, NSColor)] {
        [(.aqua, Self.lightBackground), (.darkAqua, Self.darkBackground)]
    }

    /// The stack heights the popover can actually ask for: one band up to the
    /// model block's four families plus "Other".
    private static let drawnBandCounts = 1...5

    // MARK: - Brand colour

    func testTheBrandColourIsTheTwoDocumentedLiterals() throws {
        // `#CA7C5E` — one literal for both appearances — measured 3.17:1 on a
        // light card, under the 4.5:1 AA floor for caption-size text. `#A85E3E`
        // and `#E88A5C` replaced it; these two are those, muted by
        // ``PopoverMetrics/saturationReduction``.
        XCTAssertEqual(hex(try resolved(PopoverMetrics.brandNSColor, .aqua)), "9B634B")
        XCTAssertEqual(hex(try resolved(PopoverMetrics.brandNSColor, .darkAqua)), "D6906E")
    }

    func testTheTerracottaIsTheBrandHueAtThreeQuartersSaturation() throws {
        // The muting is a property of the *colour*, not of the two hex strings
        // above: hue and lightness are the literals', saturation is exactly
        // `1 - saturationReduction` of theirs. Measured in HSL, which is the
        // space the ramp interpolates in — the reduction is defined there, and
        // the HSB figure `NSColor` reports moves by a different factor.
        XCTAssertEqual(PopoverMetrics.saturationReduction, 0.25)
        for (name, literal) in [(NSAppearance.Name.aqua, 0xA85E3E), (.darkAqua, 0xE88A5C)] {
            let painted = Self.hsl(of: try resolved(PopoverMetrics.brandNSColor, name))
            let unmuted = Self.hsl(ofHex: literal)
            XCTAssertEqual(painted.hue, unmuted.hue, accuracy: 0.5, "hue moved in \(name.rawValue)")
            XCTAssertEqual(
                painted.lightness,
                unmuted.lightness,
                accuracy: 0.005,
                "lightness moved in \(name.rawValue)"
            )
            XCTAssertEqual(
                painted.saturation,
                unmuted.saturation * (1 - PopoverMetrics.saturationReduction),
                accuracy: 0.005,
                "\(name.rawValue) is not the brand hue at three quarters saturation"
            )
        }
    }

    func testEveryBandIsMutedByTheSameFactorAsTheBrandColour() throws {
        // One reduction for the whole system, applied where the ramp's ends are
        // read — so no band, no bar and no dot can keep the unmuted hue while
        // its neighbours lose it. Measured against the ramp's own ends, since
        // every shade between them is an interpolation of the two.
        for (name, ends) in [
            (NSAppearance.Name.aqua, (strong: 0xA85E3E, pale: 0xDCBAAB)),
            (.darkAqua, (strong: 0xE88A5C, pale: 0x844C30)),
        ] {
            let expected = 1 - PopoverMetrics.saturationReduction
            let strong = Self.hsl(of: try resolved(PopoverMetrics.chartBandNSColor(0, of: 2), name))
            let pale = Self.hsl(of: try resolved(PopoverMetrics.chartBandNSColor(1, of: 2), name))
            XCTAssertEqual(
                strong.saturation / Self.hsl(ofHex: ends.strong).saturation,
                expected,
                accuracy: 0.01,
                "the strong end of the \(name.rawValue) ramp"
            )
            XCTAssertEqual(
                pale.saturation / Self.hsl(ofHex: ends.pale).saturation,
                expected,
                accuracy: 0.01,
                "the pale end of the \(name.rawValue) ramp"
            )
        }
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

    func testTheDevBuildDotPaintsItselfInTheBrandColour() throws {
        // The dot is an overlay on the status-item button, never composited
        // into ``MenuBarGlyph``'s image, so this is the only place that can
        // catch it drifting back to `.systemOrange`. Checked per appearance
        // because `.cgColor` resolves a dynamic colour at the call site.
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let dot = DevBuildDotView(frame: CGRect(x: 0, y: 0, width: 4, height: 4))
            dot.appearance = appearance
            dot.wantsLayer = true
            dot.updateBackgroundColor()

            let painted = try XCTUnwrap(NSColor(cgColor: try XCTUnwrap(dot.layer?.backgroundColor)))
            XCTAssertEqual(
                hex(try XCTUnwrap(painted.usingColorSpace(.sRGB))),
                hex(try resolved(PopoverMetrics.brandNSColor, name)),
                name.rawValue
            )
        }
    }

    // MARK: - Band ramp

    func testEveryStackIsLedByTheBrandColourItself() throws {
        // Band 0 *is* the brand colour, at every stack height — which is what
        // lets anything say "the same ink as the first band" by construction,
        // and what stops the ramp drifting off its own anchor when the number
        // of bands changes. The literals round-trip through HSL exactly, so
        // this is an equality rather than a near-match.
        for count in Self.drawnBandCounts {
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                XCTAssertEqual(
                    hex(try resolved(PopoverMetrics.chartBandNSColor(0, of: count), name)),
                    hex(try resolved(PopoverMetrics.brandNSColor, name)),
                    "band 0 of \(count) in \(name.rawValue)"
                )
            }
        }
    }

    func testEveryStackReachesTheSameBoundedEnds() throws {
        // The ramp is bounded rather than run to white or black: the strong end
        // has to read against the dark popover and the pale end against the
        // light one. Those bounds are a property of the *ramp*, not of a
        // particular stack height, so two bands and five bands end in the same
        // place — only the spacing between them changes.
        for count in Self.drawnBandCounts where count > 1 {
            XCTAssertEqual(
                try XCTUnwrap(try bandContrasts(count, .aqua, against: Self.lightBackground).last),
                1.79,
                accuracy: 0.02,
                "the pale end of \(count) light bands"
            )
            XCTAssertEqual(
                try XCTUnwrap(try bandContrasts(count, .darkAqua, against: Self.darkBackground).last),
                2.26,
                accuracy: 0.02,
                "the dark end of \(count) dark bands"
            )
        }
        // A stack of one is the brand colour, not the middle of the ramp:
        // nothing to be told apart from, and "band 0" must keep its meaning.
        XCTAssertEqual(try bandContrasts(1, .aqua, against: Self.lightBackground), [4.90], accuracy: 0.02)
        XCTAssertEqual(try bandContrasts(1, .darkAqua, against: Self.darkBackground), [6.05], accuracy: 0.02)
    }

    func testTheRampMeasuresWhatItsDocumentationClaims() throws {
        // The table in ``PopoverMetrics/chartBandColor(_:of:)``, measured.
        let light: [Int: [CGFloat]] = [
            2: [4.90, 1.79],
            3: [4.90, 2.87, 1.79],
            4: [4.90, 3.41, 2.44, 1.79],
            5: [4.90, 3.72, 2.87, 2.25, 1.79],
        ]
        let dark: [Int: [CGFloat]] = [
            2: [6.05, 2.26],
            3: [6.05, 3.89, 2.26],
            4: [6.05, 4.54, 3.26, 2.26],
            5: [6.05, 4.89, 3.89, 2.98, 2.26],
        ]
        for (count, expected) in light {
            XCTAssertEqual(try bandContrasts(count, .aqua, against: Self.lightBackground), expected, accuracy: 0.02)
        }
        for (count, expected) in dark {
            XCTAssertEqual(try bandContrasts(count, .darkAqua, against: Self.darkBackground), expected, accuracy: 0.02)
        }
    }

    func testFewerBandsSitFurtherApartThanMoreBandsDo() throws {
        // The whole reason the ramp is a function of `count` rather than a
        // fixed palette: a three-band block used to take three adjacent steps
        // of five and land ≈1.28 apart. Spreading it over the same bounds puts
        // the same three bands much further apart, and a five-band block no
        // worse off than the palette left it.
        for (name, background) in cards {
            let three = try bandContrasts(3, name, against: background)
            let five = try bandContrasts(5, name, against: background)
            XCTAssertGreaterThan(
                three[0] / three[1],
                five[0] / five[1],
                "three bands are no better spread than five in \(name.rawValue)"
            )
            XCTAssertGreaterThan(three[0] / three[1], 1.4, "three bands still step like a fixed palette in \(name.rawValue)")
        }
    }

    func testEveryStepIsWeakerThanTheOneBeforeItByAVisibleMargin() throws {
        // Two touching bands of a stack are only told apart by this step. 1.2
        // is the floor, and it holds for every stack the popover can draw; the
        // tightest is a five-band dark stack at ≈1.24. A sixth band would fall
        // below the floor — the honest cost of spreading — and nothing can ask
        // for one.
        for count in Self.drawnBandCounts {
            for (name, background) in cards {
                let contrasts = try bandContrasts(count, name, against: background)
                for index in 1..<contrasts.count {
                    XCTAssertGreaterThanOrEqual(
                        contrasts[index - 1] / contrasts[index],
                        1.2,
                        "bands \(index - 1) and \(index) of \(count) are too close to tell apart in \(name.rawValue)"
                    )
                }
            }
        }
    }

    func testThePaleEndStaysVisibleAgainstItsOwnBackground() throws {
        // The bound the ramp exists for: shades stop short of the card rather
        // than running to white or black. The monochrome ramp two designs ago
        // ended at 1.78:1 (`Color.primary` at 0.24 opacity on white), so that
        // is the precedent for how faint a band may get.
        for count in Self.drawnBandCounts {
            for (name, background) in cards {
                let last = try XCTUnwrap(try bandContrasts(count, name, against: background).last)
                XCTAssertGreaterThanOrEqual(
                    last,
                    1.78,
                    "the palest of \(count) bands vanishes into the \(name.rawValue) card"
                )
            }
        }
    }

    func testSaturationMovesWithLightnessDownTheRamp() throws {
        // Two dimensions, not one: consecutive bands differ in how deep they
        // are as well as how light, which is what makes two neighbours
        // separable at a glance rather than by measurement. Deep and saturated
        // at the brand end, pale and washed at the far one — in *both*
        // appearances, where "pale" means towards white in one card and towards
        // black in the other.
        for (name, _) in cards {
            let saturations = try (0..<5).map {
                try resolved(PopoverMetrics.chartBandNSColor($0, of: 5), name).saturationComponent
            }
            let lightnesses = try (0..<5).map { index -> CGFloat in
                let color = try resolved(PopoverMetrics.chartBandNSColor(index, of: 5), name)
                return (max(color.redComponent, color.greenComponent, color.blueComponent)
                    + min(color.redComponent, color.greenComponent, color.blueComponent)) / 2
            }
            for index in 1..<5 {
                XCTAssertNotEqual(
                    saturations[index],
                    saturations[index - 1],
                    accuracy: 0.001,
                    "bands \(index - 1) and \(index) differ in lightness alone in \(name.rawValue)"
                )
            }
            // Monotone in lightness, either up (light card) or down (dark one).
            let rising = lightnesses[4] > lightnesses[0]
            for index in 1..<5 {
                XCTAssertEqual(
                    lightnesses[index] > lightnesses[index - 1],
                    rising,
                    "the ramp doubles back on itself in \(name.rawValue)"
                )
            }
        }
    }

    func testEveryShadeIsTerracottaRatherThanAGrey() throws {
        // A ramp is a ramp of *one hue*: the popover's rule is brand terracotta
        // or ink, and a step that has desaturated into grey has left the ramp.
        for count in Self.drawnBandCounts {
            for (name, _) in cards {
                for index in 0..<count {
                    let color = try resolved(PopoverMetrics.chartBandNSColor(index, of: count), name)
                    let where_ = "band \(index) of \(count) in \(name.rawValue)"
                    XCTAssertGreaterThan(color.redComponent, color.greenComponent, where_)
                    XCTAssertGreaterThan(color.greenComponent, color.blueComponent, where_)
                    // HSB saturation, which reads lower than the HSL figure the
                    // ramp is interpolated in: the palest light shade is 31%
                    // there and 0.17 here. The floor is 0.15 rather than the
                    // 0.2 it was before ``PopoverMetrics/saturationReduction``
                    // muted the hue — 0.17 is what the ramp's palest step now
                    // measures, and it is the closest any shade comes to grey.
                    XCTAssertGreaterThan(color.saturationComponent, 0.15, "\(where_) is a grey")
                }
            }
        }
    }

    func testAnIndexPastTheStackClampsRatherThanWrapping() {
        // Wrapping would paint a band in the first band's ink and tie its table
        // dot to the wrong stripe; repeating the palest shade only makes two
        // faint bands hard to tell apart.
        XCTAssertEqual(DailyUsageSeries.bandColor(0, of: 4), PopoverMetrics.chartBandColor(0, of: 4))
        XCTAssertEqual(DailyUsageSeries.bandColor(9, of: 4), PopoverMetrics.chartBandColor(3, of: 4))
        XCTAssertEqual(DailyUsageSeries.bandColor(-1, of: 4), PopoverMetrics.chartBandColor(0, of: 4))
    }
}

private func XCTAssertEqual(
    _ measured: [CGFloat],
    _ expected: [CGFloat],
    accuracy: CGFloat,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(measured.count, expected.count, file: file, line: line)
    for (index, pair) in zip(measured, expected).enumerated() {
        XCTAssertEqual(pair.0, pair.1, accuracy: accuracy, "band \(index)", file: file, line: line)
    }
}
