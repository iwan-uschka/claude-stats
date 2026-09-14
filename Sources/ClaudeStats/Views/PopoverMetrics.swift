import AppKit
import SwiftUI

/// Shared layout constants for the popover, so the label columns of the quota
/// rows, the "Tokens by source" legend and the "Costs by model" rows line up with each other.
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
    /// Width of the token column in the "Costs by model" section — wider than a
    /// "Tokens by source" legend number because the counts here carry a `tok` suffix
    /// and are all-time rather than windowed.
    static let modelTokenColumnWidth: CGFloat = 98
    /// Width of the cost column in the "Costs by model" section. Wide enough for
    /// 4-digit spend (`$1234.56`) — a heavy cache-read day can push a single
    /// model's estimate well past the `$3.15`-sized figures this used to be
    /// sized for.
    static let costColumnWidth: CGFloat = 76
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
    /// the legend beneath it. The chart is the only element in the popover that
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
    /// Stroke width of a single-series chart line. Heavier than a hairline so
    /// the curve reads as data rather than as a gridline at 72 pt, and lighter
    /// than 2 so a spiky day keeps its shape instead of blurring into a wedge.
    static let chartLineWidth: CGFloat = 1.5
    /// Diameter of a legend swatch — the dot that ties a legend row to its band
    /// in the chart.
    static let legendSwatchSize: CGFloat = 6
    /// Gap between a legend swatch and its label.
    static let legendSwatchSpacing: CGFloat = 4
    /// Area of the dot marking the hovered day on a single-line chart. Small:
    /// it has to read as "this point", not as a marker the chart always had.
    static let chartHoverPointSize: CGFloat = 16
    /// Floor under a "Tokens by source" legend number *while hovering*, so a
    /// pointer travelling across the chart doesn't make the row reflow under
    /// every day it crosses.
    ///
    /// 42, which holds the widest count the formatter produces at a length
    /// that matters — `298.5M` measures 41.0 pt in the monospaced-digit
    /// ``valueFont``, `40.6k` 30.3, `1.1M` 27.0. No floor at rest, where the
    /// five-hour counts are narrower and the row also carries its `5h` caption.
    ///
    /// It is the whole width budget: three names (124 pt), three swatches with
    /// their gaps (42) and three of these columns come to 292 of the 312 pt
    /// content width, leaving the two gaps between chips their minimum and
    /// nothing else. That is why the hovered date sits opposite the section
    /// title instead of at the end of this row.
    static let legendTokenColumnWidth: CGFloat = 42
    static let rowSpacing: CGFloat = 8
    static let sectionSpacing: CGFloat = 10
    /// Gap between an account's active/inactive icon and its name.
    static let accountMarkerSpacing: CGFloat = 4
    /// Vertical gap between the rows inside one section.
    static let quotaRowSpacing: CGFloat = 6
    /// Gap above each *other*-account disclosure group, and between two of
    /// them. Deliberately double ``quotaRowSpacing``: the groups carry no
    /// divider of their own any more (a `Divider()` there read as a top-level
    /// section break, the same rule that separates "Tokens by source" from "Costs by model"),
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
    /// ``chartBandColors``, which are shades of exactly these two literals.
    static let brandColor = Color(brandNSColor)

    /// ``brandColor`` before SwiftUI wraps it, so a measuring test can resolve
    /// it against a named `NSAppearance`.
    static let brandNSColor = NSColor(name: nil) { appearance in
        appearance.isDarkPopover
            ? NSColor(srgbHex: 0xE88A5C)
            : NSColor(srgbHex: 0xA85E3E)
    }

    /// Ink for the stacked charts' bands, strongest first — five shades, which
    /// is what the model chart needs (four families plus "Other"; the source
    /// chart needs four).
    ///
    /// Shades of one hue, never five hues. Colour in this popover means
    /// ``brandColor``, so a chart painted in five unrelated colours would both
    /// break that rule and make the plots shout louder than the quota bars
    /// above them. The band a reader looks at first — the bottom of the stack,
    /// and the ink the cost line and the hover dots borrow — *is* the brand
    /// colour; each further band steps one notch towards its own background.
    ///
    /// The ramp is bounded at both ends rather than running to white or black:
    /// the darkest shade still has to read against the dark popover and the
    /// lightest against the light one. Measured as WCAG contrast against the
    /// same two backgrounds the figures above use — white, and the ≈`#232323`
    /// dark popover — the five steps come to 4.84 / 3.77 / 2.94 / 2.31 / 1.80
    /// in light and 6.15 / 4.79 / 3.75 / 2.92 / 2.29 in dark. That is one
    /// factor of ≈1.28 per step, enough to tell two touching bands apart, and
    /// the pale end lands where the monochrome ramp this replaced ended
    /// (`Color.primary` at 0.24 opacity measured 1.78:1 on white).
    ///
    /// Hue and saturation are not constant down the ramp: at a fixed 46% / 75%
    /// saturation the darker dark-mode steps came out a vivid orange rather
    /// than terracotta, so saturation eases off as the shade moves away from
    /// the brand colour.
    static let chartBandColors: [Color] = chartBandNSColors.map(Color.init)

    /// ``chartBandColors`` before SwiftUI wraps them — see ``brandNSColor``.
    static let chartBandNSColors: [NSColor] = [
        (light: 0xA85E3E, dark: 0xE88A5C),
        (light: 0xBC704F, dark: 0xD87240),
        (light: 0xC6886D, dark: 0xBF6233),
        (light: 0xD1A08A, dark: 0xA05733),
        (light: 0xDCBAAB, dark: 0x844C30),
    ].map { pair in
        NSColor(name: nil) { appearance in
            NSColor(srgbHex: appearance.isDarkPopover ? pair.dark : pair.light)
        }
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
