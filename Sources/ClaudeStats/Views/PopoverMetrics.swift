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
    /// Width of the percentage column on a quota row — widest reading `99.9%`,
    /// which measures 34.6 pt in the monospaced-digit ``valueFont``.
    ///
    /// 42 rather than the 38 it was measured at, and the extra 4 pt is the
    /// point of it: the reading is right-aligned, so a column wider than the
    /// number is clear space between the bar's trailing edge and the first
    /// digit.
    ///
    /// The column sits flush against the bar on every row — no
    /// ``rowSpacing`` between them — so this column's own slack is the *only*
    /// clearance a wide reading gets; see ``trailingValueColumnWidth`` for why
    /// there's no real gap there to help. Its right edge is
    /// `labelColumnWidth + rowSpacing + quotaBarWidth + percentColumnWidth`
    /// (253 pt from the content's leading edge) — the one ``rowSpacing`` in
    /// that sum is the gap before the bar, not after it.
    static let percentColumnWidth: CGFloat = 42
    /// The longest reset-countdown string the formatter can produce, `11d 11h`
    /// (40.9 pt at ``captionValueFont``) — the tightest content any row's
    /// trailing reading has to hold. Not itself a column width any row
    /// applies; see ``trailingValueColumnWidth``, which is.
    ///
    /// It was 70 while the pending-reset placeholder read `reset pending`
    /// (66.5 pt) and 92 before that, while the column read `resets in 2h 14m`.
    ///
    /// **Both placeholders were shortened to get here** — `reset pending` to
    /// `pending` (39.0 pt) and `no reading` to `no data` (36.2 pt), see
    /// ``DisplayFormat/resetCountdown(_:)`` and
    /// ``DisplayFormat/unknownWindowCountdown``. Nothing else on the row had
    /// slack left to give: the label column is pinned by `Sonnet weekly`
    /// (76.2 of its 80 pt) and the percent column by `99.9%`. `no data` is the
    /// binding one for the *gap* rather than the width — it shares its row with
    /// the em dash, so a longer placeholder here does not truncate, it collides
    /// with the reading beside it (`no reading` would have left 0.8 pt of air).
    ///
    /// The 19 pt this freed went to ``quotaBarWidth``, whole.
    static let countdownColumnWidth: CGFloat = 51
    /// The trailing reading column every row actually draws in — a countdown
    /// on the three window rows, `of €33.00` on the usage-credits row.
    ///
    /// **``rowSpacing`` plus ``countdownColumnWidth``.** Every row lays its
    /// bar, its percent and this column out in one nested zero-spacing
    /// stack — bar, percent and trailing reading all flush against each
    /// other, with the row's only real ``rowSpacing`` sitting *before* the
    /// bar, between it and the label. That is what keeps every row's percent
    /// column starting at the same x regardless of what follows it: a real
    /// gap here, sized per row, would shift each row's percent by a different
    /// amount depending on how wide its own trailing reading needed to be.
    /// Removing it and folding its width into this column instead means the
    /// column's width is the only thing that varies, never the percent's
    /// position.
    ///
    /// That buys 59 pt against the 51 pt of ``countdownColumnWidth`` alone —
    /// more than any countdown string needs, but exactly enough for a
    /// three-digit, two-decimal usage-credits limit in the widest
    /// currency/locale this formats (`of 999,00 €`, 57.2 pt at
    /// ``captionValueFont``; `of 33,00 €`, the common case, leaves 8.3 pt of
    /// air). A four-digit limit (`of 1.000,00 €`, 66.7 pt) does not fit and
    /// truncates.
    static let trailingValueColumnWidth: CGFloat = rowSpacing + countdownColumnWidth
    /// What a quota row's bar is left with: the content width less the label
    /// column, the one real gap before the bar, the percent column and
    /// ``trailingValueColumnWidth``. 123 pt, up from 104 — the whole of what
    /// ``countdownColumnWidth`` gave up when it widened into
    /// ``trailingValueColumnWidth``, and nothing of it spent on the columns
    /// beside it.
    ///
    /// Derived, and deliberately not applied — ``UsageBar`` stays greedy, so
    /// every row's bar ends at the same x whatever the columns beside it are
    /// sized to. This exists so the figure the docs quote is measured rather
    /// than remembered, and so a column widened for its own sake can't quietly
    /// take the bar's width without a test noticing.
    static let quotaBarWidth: CGFloat =
        popoverWidth - 2 * contentPadding
            - labelColumnWidth - rowSpacing
            - percentColumnWidth - trailingValueColumnWidth
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
    /// Vertical gap between the rows inside one section.
    static let quotaRowSpacing: CGFloat = 6

    static let bodyFont = Font.system(size: 11)
    /// Every number the popover sets at body size: the percentages, the token
    /// counts, the money. Monospaced digits, so a column of figures is tabular
    /// — digits keep one advance whatever they are, and a row that ticks from
    /// `61%` to `62%` doesn't reflow the text beside it.
    static let valueFont = Font.system(size: 11).monospacedDigit()
    static let sectionTitleFont = Font.system(size: 11, weight: .semibold)
    static let captionFontSize: CGFloat = 10
    static let captionFont = Font.system(size: captionFontSize)
    /// ``captionFont`` for the caption-size text that is a *number*: the reset
    /// countdowns, both chart axes, and the tables' window caption (a date
    /// while a day is shown).
    ///
    /// The same rule ``valueFont`` follows one size down — the fonts differ
    /// only in digit advance, so a numeric caption still reads as a caption
    /// beside a label set in ``captionFont``. Labels and column headings keep
    /// the proportional font: only digits gain from a fixed advance, and
    /// widening the letters of `Estimated cost` would cost the column the
    /// width it was measured for.
    static let captionValueFont = Font.system(size: captionFontSize).monospacedDigit()
    /// The proportional caption font as an `NSFont`, kept as the measuring
    /// counterpart of ``captionFont`` — and as what ``PopoverFontTests``
    /// compares ``captionValueNSFont`` against, since the whole rule is that
    /// the two differ. Built from the same size as ``captionFont`` so they
    /// can't drift apart.
    ///
    /// Nothing in the popover measures in it: the one column that is measured
    /// before layout is the chart's y-labels, and those draw monospaced — see
    /// ``captionValueNSFont`` and ``PopoverChartAxis/yLabelWidth(of:)``.
    static let captionNSFont = NSFont.systemFont(ofSize: captionFontSize)
    /// ``captionValueFont`` as an `NSFont`, and the one the chart axis measures
    /// its labels in — the axis draws them monospaced, so measuring them
    /// proportionally would size the shared y-label column from a string
    /// narrower than the one on screen.
    static let captionValueNSFont = NSFont.monospacedDigitSystemFont(
        ofSize: captionFontSize,
        weight: .regular
    )

    /// Claude's brand terracotta — the app's *only* colour.
    ///
    /// Everything that isn't monochrome is this one value at full strength:
    /// the promo link, the Claude mark in the popover header, the staleness
    /// warning, the sample-data and error lines, and the menu bar's dev-build
    /// dot. Not `.accentColor` (which follows the
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
    /// on white; `#E88A5C` clears it against the dark popover background.
    ///
    /// Both are then **muted by ``saturationReduction``** — see that constant —
    /// so what actually paints is `#9B634B` light (≈4.90:1 on white) and
    /// `#D6906E` dark (≈6.05:1 on the card). Same hue, same lightness, so the
    /// AA headroom the two literals were picked for survives the muting.
    ///
    /// The only thing allowed to use anything else is a chart band — see
    /// ``chartBandColor(_:of:)``, which shades exactly these two literals.
    static let brandColor = Color(brandNSColor)

    /// ``brandColor`` before SwiftUI wraps it, so a measuring test can resolve
    /// it against a named `NSAppearance`.
    ///
    /// Taken off the band ramp's strong end rather than from its own literal:
    /// band 0 *is* the brand colour (``chartBandColor(_:of:)``), and two
    /// separately-muted copies of one hex could drift apart.
    static let brandNSColor = NSColor(name: nil) { appearance in
        (appearance.isDarkPopover ? BandRamp.dark : BandRamp.light).strongColor
    }

    /// How much of the terracotta's saturation is taken out before anything is
    /// painted with it — 25%, i.e. the hue and the lightness of every literal
    /// below are kept and the saturation is multiplied by 0.75.
    ///
    /// Applied once, in HSL, at the ramp's two ends (``BandRamp``), which is
    /// the only place the literals are read: the brand colour, every quota
    /// bar, every chart band and every table dot are all derived from those,
    /// so nothing takes the unmuted hue and no call site is tuned by hand.
    ///
    /// The measured cost is small and goes the right way for text: the light
    /// brand ink moves 4.84:1 → 4.90:1 on white and the dark one 6.15:1 → 6.05:1
    /// on the card, both still clear of the 4.5:1 AA floor. What it does spend
    /// is the ramp's distance from grey — the palest light band reads 0.17 HSB
    /// saturation where it read 0.22 — which is why
    /// ``PopoverColorTests`` measures that end rather than trusting it.
    static let saturationReduction: Double = 0.25

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
    /// light one. They are the old ramp's first and last steps, muted by
    /// ``saturationReduction`` like everything else — WCAG contrast against
    /// white and against the ≈`#232323` dark card, 4.90 → 1.79 in light and
    /// 6.05 → 2.26 in dark. The pale end lands where the monochrome ramp before
    /// that ended (`Color.primary` at 0.24 opacity measured 1.78:1 on white).
    ///
    /// Measured for the stack heights the popover can actually draw — the
    /// source chart tops out at four bands (three entrypoints plus "Other"),
    /// the model chart at five (four families plus "Other"):
    ///
    /// | bands | light, on white | dark, on `#232323` |
    /// | --- | --- | --- |
    /// | 2 | 4.90 / 1.79 | 6.05 / 2.26 |
    /// | 3 | 4.90 / 2.87 / 1.79 | 6.05 / 3.89 / 2.26 |
    /// | 4 | 4.90 / 3.41 / 2.44 / 1.79 | 6.05 / 4.54 / 3.26 / 2.26 |
    /// | 5 | 4.90 / 3.72 / 2.87 / 2.25 / 1.79 | 6.05 / 4.89 / 3.89 / 2.98 / 2.26 |
    ///
    /// The smallest step in that table is 1.24, against the 1.28 the fixed ramp
    /// managed at *any* count. A sixth band would fall below 1.2, which is the
    /// honest cost of spreading: more bands, smaller steps. Nothing in the
    /// popover can ask for one.
    ///
    /// **Saturation moves with lightness**, so two neighbours differ in two
    /// dimensions rather than one: interpolated in HSL between the two end
    /// literals, the ramp runs 35% → 31% saturation as it lightens in the light
    /// appearance (which is 0.51 → 0.17 measured as HSB, the figure `NSColor`
    /// reports) and 56% → 35% as it darkens in the dark one. Held at the brand
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
    /// but stopping at 1.79:1 against it.
    static let light = BandRamp(strong: 0xA85E3E, pale: 0xDCBAAB)
    /// Dark appearance: the brand terracotta, darkening towards the ≈`#232323`
    /// card but stopping at 2.26:1 against it.
    static let dark = BandRamp(strong: 0xE88A5C, pale: 0x844C30)

    private let strong: HSL
    private let pale: HSL

    /// The literals are the *unmuted* terracotta, and are muted here — the one
    /// place they are read. Doing it at construction rather than per shade
    /// keeps `color(at:)` a straight interpolation, and since HSL saturation is
    /// interpolated linearly, muting the two ends is the same colour as muting
    /// every shade between them.
    init(strong: UInt32, pale: UInt32) {
        self.strong = HSL(srgbHex: strong).desaturated(by: PopoverMetrics.saturationReduction)
        self.pale = HSL(srgbHex: pale).desaturated(by: PopoverMetrics.saturationReduction)
    }

    /// The strong end on its own — what ``PopoverMetrics/brandNSColor`` paints,
    /// so the brand colour and band 0 are the same value by construction.
    var strongColor: NSColor { strong.nsColor }

    /// The shade at `position`, `0` being the brand colour itself.
    ///
    /// Both ends round-trip to the muted literals they were measured as, and
    /// position 0 is ``strongColor`` itself — which is what lets
    /// ``PopoverMetrics/chartBandColor(_:of:)`` promise that band 0 *is*
    /// ``PopoverMetrics/brandColor`` rather than something close to it.
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

    /// The same hue and lightness at a fraction less saturation — see
    /// ``PopoverMetrics/saturationReduction``, the one caller.
    func desaturated(by amount: Double) -> HSL {
        HSL(hue: hue, saturation: saturation * (1 - amount), lightness: lightness)
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
