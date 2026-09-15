import AppKit
import SwiftUI
import XCTest

@testable import ClaudeStats
@testable import ClaudeStatsCore

/// What the popover paints things in, measured off the rendered pixels.
///
/// A `.foregroundStyle` is not reachable from a `View` value — SwiftUI offers no
/// way to ask a view what colour it will be — so the only test of "this is
/// terracotta" and "this is not" is the one that draws it. Rendered through the
/// same offscreen path the shipping popover and the README screenshots use, so
/// what this measures is what ships; see ``PopoverPixels``.
@MainActor
final class PopoverInkTests: XCTestCase {
    private static let renderDate = Date(timeIntervalSince1970: 1_756_600_000)

    /// The two appearances with a card each is drawn on. Both, always: every
    /// colour in the popover is a dynamic `NSColor` that resolves per
    /// appearance, and a literal edited by eye in one theme is the failure
    /// these guard.
    private static let cards: [(name: String, appearance: NSAppearance.Name, card: Color)] = [
        ("light", .aqua, Color(white: 0.96)),
        ("dark", .darkAqua, Color(white: 0.07)),
    ]

    // MARK: - Quota bars

    func testAFullQuotaBarIsPaintedInTheBrandColour() throws {
        // The bars are the popover's headline reading, and they take the app's
        // one colour rather than the grey the text around them is set in. Full
        // strength, not an opacity: `Color.primary` at 0.75 is what they used to
        // be, and a dimmed terracotta reads as a disabled control.
        for (name, appearance, card) in Self.cards {
            let bitmap = try PopoverPixels.render(
                UsageBar(fraction: 1).frame(width: 100),
                width: 100,
                appearance: appearance,
                background: card
            )
            let expected = try resolvedBrand(appearance)
            let middle = bitmap.height / 2
            let sample = bitmap.rgb(bitmap.width / 2, middle)

            XCTAssertEqual(sample.red, expected.redComponent, accuracy: 0.02, "\(name) bar fill, red")
            XCTAssertEqual(sample.green, expected.greenComponent, accuracy: 0.02, "\(name) bar fill, green")
            XCTAssertEqual(sample.blue, expected.blueComponent, accuracy: 0.02, "\(name) bar fill, blue")
        }
    }

    func testAnEmptyQuotaBarsTrackTakesNoColourAtAll() throws {
        // The unfilled part of a bar is absence, not a second reading. Tinting
        // it would make a 5%-used window look half terracotta, which is the
        // number the bar exists to deny.
        for (name, appearance, card) in Self.cards {
            let bitmap = try PopoverPixels.render(
                UsageBar(fraction: 0).frame(width: 100),
                width: 100,
                appearance: appearance,
                background: card
            )
            XCTAssertEqual(
                terracottaCount(in: bitmap),
                0,
                "the \(name) bar's empty track is tinted"
            )
        }
    }

    func testTheHatchedBarIsTheSameInkAsTheSolidOne() throws {
        // The usage-credits bar differs from its neighbours in *geometry* —
        // stripes, because it measures money against a monthly cap rather than
        // a rate-limit window — and in nothing else. It went terracotta with
        // the rest: a hatched grey bar under three terracotta ones would read
        // as disabled rather than as different in kind.
        for (name, appearance, card) in Self.cards {
            let solid = try PopoverPixels.render(
                UsageBar(fraction: 1).frame(width: 100),
                width: 100,
                appearance: appearance,
                background: card
            )
            let hatched = try PopoverPixels.render(
                UsageBar(fraction: 1, fillStyle: .hatched).frame(width: 100),
                width: 100,
                appearance: appearance,
                background: card
            )
            let stripes = terracottaCount(in: hatched)
            XCTAssertGreaterThan(stripes, 0, "the \(name) hatched bar drew no brand ink")
            // Stripes with gaps, not a solid block: the geometry is the whole
            // difference and it has to survive the recolouring.
            XCTAssertLessThan(stripes, terracottaCount(in: solid) / 2, "the \(name) hatch filled solid")
        }
    }

    // MARK: - Warning, error and sample-data lines

    func testTheWarningErrorAndSampleDataLinesAreSetInTheBrandColour() throws {
        // These three were `.orange`, `.red` and `.orange` before the popover
        // went one-colour, and nothing else in the tree would fail if one of
        // them went back: a `.foregroundStyle` is unreachable from a `View`
        // value. So they are measured the way the bars are — off the pixels.
        //
        // Counted, not located: each fixture differs from the plain popover by
        // exactly one line, and everything else that takes brand ink (the mark,
        // the bars, the table dots) is drawn in the same quantity in both — a
        // line added higher up shifts the rows below it without changing what
        // they paint — so every extra pixel is the line's own. And counted
        // against the brand colour rather than ``isTerracotta``, which passes
        // anything warm: `.orange` has far more green than the brand ink and
        // `.red` far less, so a line set in either adds nothing to this count.
        let fixtures: [(what: String, model: AppModel)] = [
            ("the staleness warning", AppModel.previewStaleWarning()),
            ("an error line", AppModel.preview(error: "Quota source unavailable.")),
            ("the sample-data line", AppModel.preview(usingSampleData: true)),
        ]

        for (name, appearance, card) in Self.cards {
            let plain = try render(AppModel.preview(), appearance: appearance, card: card)
            let baseline = try brandInkCount(in: plain, appearance: appearance)

            for (what, model) in fixtures {
                let drawn = try render(model, appearance: appearance, card: card)
                XCTAssertGreaterThan(
                    try brandInkCount(in: drawn, appearance: appearance),
                    baseline,
                    "\(what) drew no brand ink on the \(name) card"
                )
            }
        }
    }

    // MARK: - Measuring

    private func render(_ model: AppModel, appearance: NSAppearance.Name, card: Color) throws -> PopoverPixels.Bitmap {
        try PopoverPixels.render(
            PopoverView(model: model, clock: PopoverClock(now: Self.renderDate)).background(card),
            width: PopoverMetrics.popoverWidth,
            appearance: appearance,
            background: card
        )
    }

    /// How many pixels of the card are terracotta rather than ink or backdrop.
    private func terracottaCount(in bitmap: PopoverPixels.Bitmap) -> Int {
        var count = 0
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width where bitmap.isTerracotta(x, y) {
                count += 1
            }
        }
        return count
    }

    /// How many pixels are the brand colour itself, rather than merely
    /// terracotta-ish: `isTerracotta` passes anything warm, including the
    /// `.orange` these lines used to be set in.
    private func brandInkCount(in bitmap: PopoverPixels.Bitmap, appearance: NSAppearance.Name) throws -> Int {
        let brand = try resolvedBrand(appearance)
        let tolerance = 0.03
        var count = 0
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width where bitmap.isTerracotta(x, y) {
                let pixel = bitmap.rgb(x, y)
                if abs(pixel.red - brand.redComponent) < tolerance,
                    abs(pixel.green - brand.greenComponent) < tolerance,
                    abs(pixel.blue - brand.blueComponent) < tolerance {
                    count += 1
                }
            }
        }
        return count
    }

    private func resolvedBrand(_ name: NSAppearance.Name) throws -> NSColor {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = PopoverMetrics.brandNSColor.usingColorSpace(.sRGB)
        }
        return try XCTUnwrap(resolved)
    }
}
