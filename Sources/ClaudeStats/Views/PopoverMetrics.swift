import AppKit
import SwiftUI

/// Shared layout constants for the popover, so the label columns of the quota
/// rows and the tables under the "By source" and "By model" charts line up with each other.
enum PopoverMetrics {
    static let popoverWidth: CGFloat = 340
    static let contentPadding: CGFloat = 14
    /// Width of the leading label column shared by every row type.
    ///
    /// 80, sized to the widest label that is not the app's own: the scoped
    /// weekly rows are labelled from the payload, and `"Sonnet weekly"`
    /// measures 76.2 pt at ``bodyFont`` (`"Usage credits"` 72.4, the two fixed
    /// window labels far less). It was 92 while those rows read
    /// `"Sonnet (weekly)"` and the fixed ones said `"5-hour window"`; dropping
    /// the parentheses and the word "window" bought the bars 12 pt. A longer
    /// model name truncates (``WindowBarView`` pins its label to one line)
    /// rather than growing the row to two lines.
    static let labelColumnWidth: CGFloat = 80
    /// Width of the percentage column on a quota row — widest label `99.9%`,
    /// which measures 34.6 pt in the monospaced-digit ``valueFont``.
    static let percentColumnWidth: CGFloat = 38
    /// Width of the trailing reset-countdown column. Sized to the widest
    /// string it ever holds, the `reset pending` placeholder (66.5 pt at
    /// ``captionFont``); the countdowns themselves (`2h 14m`, `6d 23h`) are
    /// under 45 pt. It was 92 while the column read `resets in 2h 14m`; the
    /// width saved went to the bars. Not lower: the merged
    /// ``percentAndCountdownColumnWidth`` must still hold a usage-credits
    /// value such as `20,87 € of 33,00 €` (99.8 pt at ``valueFont``) on one
    /// line — at 38 + 8 + 70 it has 116 pt for it.
    static let countdownColumnWidth: CGFloat = 70
    /// The two trailing quota columns merged into one, for a row whose value is
    /// wider than a percentage and has no countdown to show — the usage-credits
    /// row's `€0.00 of €33.00`. Spans exactly the same pixels, so its value
    /// still ends flush with the countdowns above it.
    static let percentAndCountdownColumnWidth: CGFloat =
        percentColumnWidth + rowSpacing + countdownColumnWidth
    /// Width of the token column in a chart's table, both blocks sharing it.
    ///
    /// 48: the widest count a thirty-day sum plausibly reaches is `298.5M`
    /// (41.0 pt in the monospaced-digit ``valueFont``), and the `Tokens`
    /// heading above it measures 33.9 at ``captionFont``. The old per-model
    /// column was 98 because every cell carried a `tok` suffix — the heading
    /// says it once instead, and the 50 pt that frees is what pays for the
    /// column beside it.
    static let tableTokenColumnWidth: CGFloat = 48
    /// Width of the cost column in a chart's table.
    ///
    /// 74, and sized by the *heading* rather than by the numbers for once:
    /// `Estimated cost` measures 71.7 pt at ``captionFont``, against 52.3 for
    /// the widest 4-digit figure (`$1234.56`) at ``valueFont``. Widened rather
    /// than abbreviated to `Est.` — that word is the whole qualification, and
    /// the row had 102 pt of slack to spend on it (dot, widest label
    /// `SDK/agents`, both columns and their gaps come to 209 of 312 pt).
    static let tableCostColumnWidth: CGFloat = 74
    /// Vertical gap between the rows of a chart's table, caption row included.
    /// Tighter than ``quotaRowSpacing``: these rows are one reading each, with
    /// no bar to separate, and two tables of them sit in one popover.
    static let tableRowSpacing: CGFloat = 4
    /// Overall height of a popover chart, axis labels included. The plot
    /// itself gets what is left after the x-axis labels, so this is larger
    /// than the 44 pt the chart ran at while its axes were hidden.
    ///
    /// Tall enough that a quiet day is still visibly above zero and that three
    /// y-ticks don't collide, short enough that the section plus the quota rows
    /// still fit without the popover needing to scroll.
    static let chartHeight: CGFloat = 72
    /// Spacing between a chart's x-axis tick labels, in days. Seven keeps the
    /// labels a week apart — five of them across a 30-day window, which is as
    /// many `Aug 16`-sized labels as fit without overlapping.
    static let chartXAxisStrideDays = 7
    /// How many steps the y-axis aims to take from zero to the top of the
    /// scale — so three or four labelled values, since the top is rounded up
    /// past the data. Three is what a 72 pt chart can label without the numbers
    /// touching. See ``PopoverChartAxis/yValues(upTo:count:)``.
    static let chartYAxisTickCount = 3
    /// Length of an x-axis tick — the only ticks a popover chart draws, since
    /// the y-axis has gridlines that reach its labels already. Short: the tick
    /// only has to attach the label to the axis, and the default reads as a
    /// gridline at this chart's size.
    static let chartTickLength: CGFloat = 3
    /// Breathing room above and below a chart — under its section title, over
    /// the table beneath it. The chart is the only element in the popover that
    /// is a *picture* rather than a row of text, and run flush against those it
    /// reads as part of them.
    ///
    /// Vertical only: the plot spans the popover's full content width like
    /// every other row, so insetting it sideways would pull its axis out of the
    /// alignment the rows above and below keep.
    static let chartMargin: CGFloat = 6
    /// How many days at the end of the window get no x-axis tick.
    ///
    /// A tick's label starts at the tick and runs to the right of it — Swift
    /// Charts anchors a dated label to the interval it opens — and is truncated
    /// at the chart's trailing edge, so a tick in the last few days renders as
    /// `1…` however the plot is inset: the label has nowhere to sit. Four days
    /// is about a `16. Aug.`-sized label at this chart's scale. Nothing is lost:
    /// the right edge of a trailing window is always today.
    static let chartXAxisEdgeMarginDays = 4
    /// Gutter the x scale keeps at each end of the plot.
    ///
    /// The days are plotted on their own midnights, so the first and last of
    /// them land on the plot's own edges — and the dot marking a hovered day is
    /// centred on its mark, which leaves half of it outside the plot on the day
    /// most likely to be hovered: today. Wide enough for that dot's radius
    /// (``chartHoverPointSize`` is an area, so about 2.3 pt) with a little over.
    ///
    /// The scale's range, not the chart's padding: insetting the plot itself
    /// would move the axis away from the alignment the rows above and below
    /// keep, and this has to inset marks and ticks by the same amount or it
    /// would reintroduce the offset it is sitting next to.
    static let chartXScaleEdgePadding: CGFloat = 3
    /// Diameter of a table swatch — the dot that ties a table row to its band
    /// in the chart above it.
    static let legendSwatchSize: CGFloat = 6
    /// Gap between a table swatch and its label.
    static let legendSwatchSpacing: CGFloat = 4
    /// Area of a dot marking the hovered day on a band's top edge. Small: it
    /// has to read as "this point", not as a marker the chart always had.
    static let chartHoverPointSize: CGFloat = 16
    static let rowSpacing: CGFloat = 8
    static let sectionSpacing: CGFloat = 10
    /// Gap between an account's active/inactive icon and its name.
    static let accountMarkerSpacing: CGFloat = 4
    /// Vertical gap between the rows inside one section.
    static let quotaRowSpacing: CGFloat = 6
    /// Gap above each *other*-account disclosure group, and between two of
    /// them. Deliberately double ``quotaRowSpacing``: the groups carry no
    /// divider of their own any more (a `Divider()` there read as a top-level
    /// section break, the same rule that separates "By source" from "By model"),
    /// so whitespace is the only thing left saying a collapsed row belongs to
    /// neither the bars above it nor the group below it.
    static let accountGroupSpacing: CGFloat = 12

    static let bodyFont = Font.system(size: 11)
    static let valueFont = Font.system(size: 11).monospacedDigit()
    static let sectionTitleFont = Font.system(size: 11, weight: .semibold)
    static let captionFontSize: CGFloat = 10
    static let captionFont = Font.system(size: captionFontSize)
    /// The caption font as an `NSFont`, for measuring a label before SwiftUI
    /// has laid it out — see ``PopoverChartAxis/yLabelWidth(of:)``. Built from
    /// the same size as ``captionFont`` so the two can't drift apart.
    static let captionNSFont = NSFont.systemFont(ofSize: captionFontSize)

    /// Claude's brand terracotta — the app's *only* colour.
    ///
    /// Everything that isn't monochrome is this one value at full strength:
    /// the promo link, the Claude mark in the popover header, the account
    /// markers, the staleness warning, the sample-data and error lines, and
    /// the menu bar's dev-build dot. Not `.accentColor` (which follows the
    /// user's system accent, usually blue, and reads as an unrelated OS
    /// affordance rather than Claude's own), and no longer the system's
    /// `.orange`/`.red`: a warning in orange, an error in red and a link in
    /// terracotta put three hues on a card whose whole colour vocabulary is
    /// "Claude" versus "ink". The severity is carried by the words, which say
    /// what happened, rather than by a hue that has to be learned.
    ///
    /// Two literals switched on appearance, not one fixed color: `#CA7C5E`
    /// measured ≈3.17:1 against a light popover background, below the 4.5:1
    /// WCAG 2.2 AA minimum for this caption-size text. `#A85E3E` clears 4.5:1
    /// on white (≈4.84:1); `#E88A5C` clears it against the dark popover
    /// background (≈6.2:1).
    ///
    /// The only thing allowed to use anything else is a chart band — see
    /// ``chartBandColor(_:of:)``, which shades exactly these two literals.
    static let brandColor = Color(brandNSColor)

    /// ``brandColor`` before SwiftUI wraps it, so a measuring test can resolve
    /// it against a named `NSAppearance`.
    static let brandNSColor = NSColor(name: nil) { appearance in
        appearance.isDarkPopover
            ? NSColor(srgbHex: 0xE88A5C)
            : NSColor(srgbHex: 0xA85E3E)
    }

    /// How strongly a stacked chart paints its bands and the strokes that close
    /// the seams between them.
    ///
    /// Not opaque, because the y-axis lines are drawn *behind* the stack now:
    /// at 0.85 they read faintly through a band, which is what a gridline is
    /// for — a reader picks a value off the plot by following one, and a line
    /// that stops at the stack's outline can only be followed in the empty
    /// region above it. 0.85 rather than less: the bands' own ramp (see
    /// ``chartBandColor(_:of:)``) is what has to stay legible, and every step
    /// of it is measured against an opaque card.
    ///
    /// The table dots keep the band colour at full strength — a 6 pt circle has
    /// no gridline to show through it, and thinning it would only make the two
    /// palest rows harder to tell apart.
    static let chartBandOpacity: Double = 0.85

    /// Width of the stroke a band draws along its own cumulative top edge.
    ///
    /// One point, which is what it takes to cover a seam: each band is a
    /// separate anti-aliased path, so at a shared boundary both paths cover
    /// their edge pixel about half and the card behind shows through as a dark
    /// hairline. The stroke is the band's own ink at the same
    /// ``chartBandOpacity``, so it reads as part of the band rather than as an
    /// outline around it.
    static let chartBandSeamWidth: CGFloat = 1

    /// Ink for stack position `index` of a stack `count` bands tall, strongest
    /// first.
    ///
    /// Shades of one hue, never several hues. Colour in this popover means
    /// ``brandColor``, so a chart painted in unrelated colours would both break
    /// that rule and make the plots shout louder than the quota bars above
    /// them. Position 0 — the first table row, the *top* band of the stack, and
    /// the ink anything saying "the same colour as the first band" borrows — is
    /// the brand colour itself; the last band sits at the far end of the ramp.
    ///
    /// **Shade by position, not a fixed palette.** The ramp this replaced was
    /// five literals a chart took the first `count` of, so a three-band stack
    /// used three adjacent steps of five and its bands were a factor of ≈1.28
    /// apart. Spreading `count` bands across the *whole* bounded range instead
    /// puts three of them 1.68 / 1.60 apart — the fewer the bands, the further
    /// apart they sit, which is the opposite of what a fixed palette does.
    ///
    /// The ends are bounded rather than run to white or black: the strong end
    /// still has to read against the dark popover and the pale end against the
    /// light one. They are exactly the old ramp's first and last steps, so the
    /// measured bounds are unchanged — WCAG contrast against white and against
    /// the ≈`#232323` dark card, 4.84 → 1.80 in light and 6.15 → 2.29 in dark.
    /// The pale end lands where the monochrome ramp before that ended
    /// (`Color.primary` at 0.24 opacity measured 1.78:1 on white).
    ///
    /// Measured for the stack heights the popover can actually draw — the
    /// source chart tops out at four bands (three entrypoints plus "Other"),
    /// the model chart at five (four families plus "Other"):
    ///
    /// | bands | light, on white | dark, on `#232323` |
    /// | --- | --- | --- |
    /// | 2 | 4.84 / 1.80 | 6.15 / 2.29 |
    /// | 3 | 4.84 / 2.88 / 1.80 | 6.15 / 4.05 / 2.29 |
    /// | 4 | 4.84 / 3.40 / 2.45 / 1.80 | 6.15 / 4.70 / 3.35 / 2.29 |
    /// | 5 | 4.84 / 3.69 / 2.88 / 2.27 / 1.80 | 6.15 / 5.03 / 4.05 / 3.04 / 2.29 |
    ///
    /// The smallest step in that table is 1.22, against the 1.28 the fixed ramp
    /// managed at *any* count. A sixth band would fall to ≈1.18, which is the
    /// honest cost of spreading: more bands, smaller steps. Nothing in the
    /// popover can ask for one.
    ///
    /// **Saturation moves with lightness**, so two neighbours differ in two
    /// dimensions rather than one: interpolated in HSL between the two end
    /// literals, the ramp runs 46% → 41% saturation as it lightens in the light
    /// appearance (which is 0.63 → 0.22 measured as HSB, the figure `NSColor`
    /// reports) and 75% → 47% as it darkens in the dark one. Held at the brand
    /// value instead, the darker dark-mode steps came out a vivid orange rather
    /// than terracotta.
    static func chartBandColor(_ index: Int, of count: Int) -> Color {
        Color(chartBandNSColor(index, of: count))
    }

    /// ``chartBandColor(_:of:)`` before SwiftUI wraps it — see ``brandNSColor``.
    ///
    /// A dynamic `NSColor` like the brand colour, resolved against the *AppKit*
    /// appearance rather than SwiftUI's `colorScheme`, so the same band is one
    /// literal on the light card and another on the dark one.
    ///
    /// **The same call returns the same instance**, which is not an
    /// optimisation. A dynamic `NSColor` — and the SwiftUI `Color` wrapping one
    /// — compares by *identity*, so a shade built fresh on each access is never
    /// `==` to the one the last render used: ``DailyUsageSeries`` is `Equatable`
    /// off its colour, and every band would read as changed on every pass.
    static func chartBandNSColor(_ index: Int, of count: Int) -> NSColor {
        let bands = Swift.max(count, 1)
        let position = Swift.min(Swift.max(index, 0), bands - 1)
        guard bands <= bandRampCacheLimit else { return makeChartBandNSColor(position, of: bands) }
        return cachedBandColors[bands][position]
    }

    /// Stack heights ``chartBandNSColor(_:of:)`` is precomputed for — eight,
    /// comfortably past the five bands the popover can draw (four model
    /// families plus "Other"). A taller stack still gets the right colour; it
    /// just builds it each time, and nothing asks for one.
    private static let bandRampCacheLimit = 8

    private static let cachedBandColors: [[NSColor]] = (0...bandRampCacheLimit).map { count in
        (0..<count).map { makeChartBandNSColor($0, of: count) }
    }

    /// One shade, built rather than looked up. `index` and `count` are already
    /// clamped by the caller.
    ///
    /// A single band is the brand colour, not the middle of the ramp: one band
    /// has nothing to be told apart from, and "the same ink as band 0" has to
    /// keep meaning the brand colour.
    private static func makeChartBandNSColor(_ index: Int, of count: Int) -> NSColor {
        let position = count > 1 ? Double(index) / Double(count - 1) : 0
        return NSColor(name: nil) { appearance in
            let ramp = appearance.isDarkPopover ? BandRamp.dark : BandRamp.light
            return ramp.color(at: position)
        }
    }
}

/// The two ends of one appearance's band ramp, and the shades between them.
///
/// HSL rather than HSB or sRGB: lightness is the axis the ramp is *about*, and
/// interpolating it carries saturation along with it for free — a straight sRGB
/// lerp between the same two literals runs through muddier, greyer middles.
private struct BandRamp {
    /// Light appearance: the brand terracotta, paling towards the white card
    /// but stopping at 1.80:1 against it.
    static let light = BandRamp(strong: 0xA85E3E, pale: 0xDCBAAB)
    /// Dark appearance: the brand terracotta, darkening towards the ≈`#232323`
    /// card but stopping at 2.29:1 against it.
    static let dark = BandRamp(strong: 0xE88A5C, pale: 0x844C30)

    private let strong: HSL
    private let pale: HSL

    init(strong: UInt32, pale: UInt32) {
        self.strong = HSL(srgbHex: strong)
        self.pale = HSL(srgbHex: pale)
    }

    /// The shade at `position`, `0` being the brand colour itself.
    ///
    /// Both ends round-trip to the literals they were measured as, which is
    /// what lets ``PopoverMetrics/chartBandColor(_:of:)`` promise that band 0
    /// *is* ``PopoverMetrics/brandColor`` rather than something close to it.
    func color(at position: Double) -> NSColor {
        strong.blended(toward: pale, amount: position).nsColor
    }
}

/// Just enough HSL for the band ramp: the sRGB literals in, a shade out.
private struct HSL {
    /// Degrees, `0..<360`.
    var hue: Double
    var saturation: Double
    var lightness: Double

    init(srgbHex hex: UInt32) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        let high = Swift.max(red, green, blue)
        let low = Swift.min(red, green, blue)
        let chroma = high - low
        lightness = (high + low) / 2
        guard chroma > 0 else {
            hue = 0
            saturation = 0
            return
        }
        saturation = chroma / (1 - abs(2 * lightness - 1))
        let sector: Double
        if high == red {
            sector = ((green - blue) / chroma).truncatingRemainder(dividingBy: 6)
        } else if high == green {
            sector = (blue - red) / chroma + 2
        } else {
            sector = (red - green) / chroma + 4
        }
        hue = (sector * 60 + 360).truncatingRemainder(dividingBy: 360)
    }

    private init(hue: Double, saturation: Double, lightness: Double) {
        self.hue = hue
        self.saturation = saturation
        self.lightness = lightness
    }

    /// Linear in all three axes, hue the short way round the wheel. Both ends
    /// of this ramp sit at ≈18–20°, so the wrap never fires in practice; it is
    /// here so a future pair of literals can't interpolate the long way through
    /// green.
    func blended(toward other: HSL, amount: Double) -> HSL {
        var turn = other.hue - hue
        if turn > 180 { turn -= 360 }
        if turn < -180 { turn += 360 }
        return HSL(
            hue: (hue + turn * amount + 360).truncatingRemainder(dividingBy: 360),
            saturation: saturation + (other.saturation - saturation) * amount,
            lightness: lightness + (other.lightness - lightness) * amount
        )
    }

    var nsColor: NSColor {
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let sector = hue / 60
        let second = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let (red, green, blue): (Double, Double, Double)
        switch sector {
        case ..<1: (red, green, blue) = (chroma, second, 0)
        case ..<2: (red, green, blue) = (second, chroma, 0)
        case ..<3: (red, green, blue) = (0, chroma, second)
        case ..<4: (red, green, blue) = (0, second, chroma)
        case ..<5: (red, green, blue) = (second, 0, chroma)
        default: (red, green, blue) = (chroma, 0, second)
        }
        let base = lightness - chroma / 2
        return NSColor(
            srgbRed: red + base,
            green: green + base,
            blue: blue + base,
            alpha: 1
        )
    }
}

private extension NSAppearance {
    /// Whether this appearance paints the dark popover. `bestMatch` rather than
    /// a name compare, so a vibrant or high-contrast variant resolves to the
    /// side of the pair it actually looks like.
    var isDarkPopover: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

private extension NSColor {
    /// An opaque sRGB colour from a `0xRRGGBB` literal, so a ramp reads as the
    /// hex values it was measured as.
    convenience init(srgbHex hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
