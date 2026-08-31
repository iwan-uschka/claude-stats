import AppKit
import ClaudeStatsCore
import SwiftUI

/// Draws the status item's glyph: the Claude mark, then three to four thin
/// vertical bars — 5-hour, 7-day, and the highest scoped weekly limit, plus a
/// hatched usage-credits bar when the account has any.
///
/// The first three are always drawn: with no scoped-limit reading, the third
/// bar is simply empty (0% fill), exactly like an absent snapshot draws the
/// first two as empty tracks rather than omitting them. The fourth is the
/// exception — usage credits are transient, and an always-drawn empty bar would
/// imply a monthly spend cap the account may not have. So the glyph is three
/// bars wide normally and four wide while credits are reported; the width is a
/// function of the bar count rather than a constant.
///
/// Rendered into a *template* `NSImage` rather than hosted as a SwiftUI view.
/// Template images are the only thing that gets the menu bar's full treatment
/// for free: automatic light/dark tint, correct inversion while the item is
/// highlighted (popover open), and the reduced-contrast tint when the app is in
/// the background. A hosted `NSHostingView` would have to re-derive all of that
/// from `NSStatusBarButton.isHighlighted` and the effective appearance.
///
/// Fill level is encoded purely in alpha (opaque = used, faint = remaining), so
/// the glyph stays monochrome — no colour shift as a window fills up.
enum MenuBarGlyph {
    /// Height of the drawn glyph; a little under the 24pt menu bar so the icon
    /// doesn't touch the edges.
    static let height: CGFloat = 18
    static let markSize: CGFloat = 11.9 // 15% smaller than the original 14.
    /// Gap between the mark and the first bar.
    static let markToBarsGap: CGFloat = 3.5
    static let barWidth: CGFloat = 3
    static let barHeight: CGFloat = height
    static let barSpacing: CGFloat = 2.5
    static let barCornerRadius: CGFloat = 1
    /// Alpha of the unused portion of a bar.
    static let trackAlpha: CGFloat = 0.3
    /// Stripe pitch and thickness for a hatched bar. Coarser relative to the
    /// bar than the popover's, because at 3 pt wide only two or three stripes
    /// fit at all — any finer and they blur into a flat mid-grey.
    static let hatchSpacing: CGFloat = 2.6
    static let hatchLineWidth: CGFloat = 0.8

    /// Bars always drawn: 5-hour, 7-day, and scoped weekly — unconditionally,
    /// same as each other. There is no narrower glyph to fall back to.
    static let baseBarCount = 3
    /// With usage credits reported, a fourth (hatched) bar joins them. That one
    /// *is* conditional: credits are transient and absent far more often than
    /// not, and an always-drawn empty fourth bar would imply the account has a
    /// spend cap it may well not have.
    static let maxBarCount = 4

    /// Width of a glyph with `barCount` bars — 2, 3 (the usual) or 4.
    ///
    /// A function rather than a constant because the credits bar comes and goes
    /// with the payload; ``width`` remains the no-credits width, which is what
    /// static layout (the dev-build dot) is positioned against.
    static func width(barCount: Int) -> CGFloat {
        let bars = min(max(barCount, 0), maxBarCount)
        guard bars > 0 else { return markSize }
        return markSize + markToBarsGap
            + barWidth * CGFloat(bars) + barSpacing * CGFloat(bars - 1)
    }

    /// Width with no usage-credits bar — the common case.
    static let width: CGFloat = width(barCount: baseBarCount)

    /// Template image for the given window fills (each 0...1, clamped).
    ///
    /// `scopedWeeklyFraction` defaults to 0 (an empty third bar) when there is
    /// no scoped reading, same as the other two fractions default to 0 for an
    /// absent snapshot in ``image(for:)``. `scopedWeeklyLabel` only names the
    /// bar for VoiceOver when there is one; neither says what the scoped
    /// percentage is a share of — see ``QuotaScopedLimit``.
    ///
    /// `usageCreditsFraction` is the one *optional* bar: `nil` (the common
    /// case) draws the familiar three-bar glyph, and a value draws a fourth,
    /// hatched bar. Not "0 means absent" — 0% of a real spend cap is a
    /// meaningful reading and gets drawn.
    static func image(
        fiveHourFraction: Double,
        sevenDayFraction: Double,
        scopedWeeklyFraction: Double = 0,
        scopedWeeklyLabel: String? = nil,
        usageCreditsFraction: Double? = nil
    ) -> NSImage {
        var bars: [(fraction: Double, hatched: Bool)] = [
            (DisplayFormat.clamped01(fiveHourFraction), false),
            (DisplayFormat.clamped01(sevenDayFraction), false),
            (DisplayFormat.clamped01(scopedWeeklyFraction), false),
        ]
        if let usageCreditsFraction {
            bars.append((DisplayFormat.clamped01(usageCreditsFraction), true))
        }

        let image = NSImage(
            size: NSSize(width: width(barCount: bars.count), height: height),
            flipped: true // SVG/UI y-down, so the mark path needs no flip.
        ) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(bars: bars, in: context)
            return true
        }
        image.isTemplate = true
        let devSuffix = BuildEnvironment.isDevelopmentBuild ? BuildEnvironment.devBuildSuffix : ""
        let scope = scopedWeeklyLabel.map { "\($0) " } ?? ""
        var description = "Claude Stats\(devSuffix): \(Int(bars[0].fraction * 100))% five-hour, "
            + "\(Int(bars[1].fraction * 100))% seven-day, \(Int(bars[2].fraction * 100))% \(scope)weekly usage"
        if let usageCreditsFraction {
            description += ", \(Int(DisplayFormat.clamped01(usageCreditsFraction) * 100))% usage credits"
        }
        image.accessibilityDescription = description
        return image
    }

    /// Snapshot-driven convenience; an absent snapshot draws the three
    /// always-present bars empty and no credits bar.
    ///
    /// The scoped bar takes the highest-percentage entry —
    /// ``QuotaSnapshot/scopedWeekly`` is already sorted descending, so `first`
    /// is that one, and it stays the same entry across polls. No entry at all
    /// (nil snapshot, or a snapshot with none) draws the third bar at 0%,
    /// same as the first two draw at 0% with no snapshot. The fourth bar is
    /// drawn only when the snapshot actually carries usage credits.
    static func image(for snapshot: QuotaSnapshot?) -> NSImage {
        let scoped = snapshot?.scopedWeekly.first
        return image(
            fiveHourFraction: snapshot?.fiveHour.fractionUsed ?? 0,
            sevenDayFraction: snapshot?.sevenDay.fractionUsed ?? 0,
            scopedWeeklyFraction: scoped?.window.fractionUsed ?? 0,
            scopedWeeklyLabel: scoped?.label,
            usageCreditsFraction: snapshot?.usageCredits?.window.fractionUsed
        )
    }

    private static func draw(bars: [(fraction: Double, hatched: Bool)], in context: CGContext) {
        let markRect = CGRect(
            x: 0,
            y: (height - markSize) / 2,
            width: markSize,
            height: markSize
        )
        if let markPath = ClaudeMark.path(fitting: markRect) {
            context.addPath(markPath)
            context.setFillColor(gray: 0, alpha: 1)
            context.fillPath(using: .evenOdd)
        }

        let barsOriginX = markSize + markToBarsGap
        let barTop = (height - barHeight) / 2

        for (index, bar) in bars.enumerated() {
            let fraction = bar.fraction
            let barRect = CGRect(
                x: barsOriginX + CGFloat(index) * (barWidth + barSpacing),
                y: barTop,
                width: barWidth,
                height: barHeight
            )

            // Track: the full bar at low alpha, so an empty window still reads
            // as one of three bars rather than as a missing element.
            context.addPath(
                CGPath(
                    roundedRect: barRect,
                    cornerWidth: barCornerRadius,
                    cornerHeight: barCornerRadius,
                    transform: nil
                )
            )
            context.setFillColor(gray: 0, alpha: trackAlpha)
            context.fillPath()

            let filledHeight = barRect.height * fraction
            guard filledHeight > 0.5 else { continue }

            context.saveGState()
            context.addPath(
                CGPath(
                    roundedRect: barRect,
                    cornerWidth: barCornerRadius,
                    cornerHeight: barCornerRadius,
                    transform: nil
                )
            )
            context.clip()
            // Flipped context: "bottom" of the bar is its maxY.
            let filledRect = CGRect(
                x: barRect.minX,
                y: barRect.maxY - filledHeight,
                width: barRect.width,
                height: filledHeight
            )
            if bar.hatched {
                fillHatched(filledRect, in: context)
            } else {
                context.setFillColor(gray: 0, alpha: 1)
                context.fill(filledRect)
            }
            context.restoreGState()
        }
    }

    /// The hatched fill's small-scale twin of `UsageBar.FillStyle.hatched`:
    /// opaque 45° stripes over whatever's already drawn behind the bar — no
    /// separate ground fill, so the gaps between stripes read as the same
    /// track color as the bar's unfilled portion.
    ///
    /// Drawn in the same gray-0 template ink as everything else, so the menu bar
    /// still tints and inverts it for free. Legibility at 3 pt is the open
    /// question here — it has to be checked by eye against the `#Preview`
    /// below, since a rendered template image has nothing stable to assert on.
    private static func fillHatched(_ rect: CGRect, in context: CGContext) {
        context.saveGState()
        context.clip(to: rect)

        context.setStrokeColor(gray: 0, alpha: 1)
        context.setLineWidth(hatchLineWidth)
        var x = rect.minX - rect.height
        while x <= rect.maxX {
            context.move(to: CGPoint(x: x, y: rect.maxY))
            context.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += hatchSpacing
        }
        context.strokePath()

        context.restoreGState()
    }
}

#if DEBUG
/// Preview harness: shows the glyph over both menu bar backgrounds at a few
/// fill levels. `swift build` can't show this, but Xcode's canvas can.
#Preview("Menu bar glyph") {
    // The last four are the ones to look at for this feature: whether the
    // hatched fourth bar reads as textured rather than as a lighter solid at
    // 3 pt wide, in both appearances.
    let samples: [(String, Double, Double, Double, Double?)] = [
        // Third bar always draws, same as the first two — empty here since
        // there's no scoped reading.
        ("empty", 0, 0, 0, nil),
        ("mock", 0.62, 0.31, 0, nil),
        ("high", 0.94, 0.71, 0, nil),
        ("full", 1, 1, 0, nil),
        ("scoped", 0.62, 0.31, 0.12, nil),
        ("scoped hi", 0.94, 0.71, 0.55, nil),
        ("credits 0", 0.62, 0.31, 0.12, 0),
        ("credits", 0.62, 0.31, 0.12, 0.4),
        ("credits hi", 0.94, 0.71, 0.55, 0.85),
        ("credits full", 0.94, 0.71, 0.55, 1),
    ]

    return VStack(spacing: 0) {
        ForEach([false, true], id: \.self) { dark in
            HStack(spacing: 18) {
                ForEach(samples, id: \.0) { sample in
                    VStack(spacing: 4) {
                        Image(nsImage: MenuBarGlyph.image(
                            fiveHourFraction: sample.1,
                            sevenDayFraction: sample.2,
                            scopedWeeklyFraction: sample.3,
                            scopedWeeklyLabel: sample.3 == 0 ? nil : "Fable",
                            usageCreditsFraction: sample.4
                        ))
                        .renderingMode(.template)
                        Text(sample.0)
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(dark ? .white : .black)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(dark ? Color.black : Color.white)
        }
    }
    .frame(width: 560)
}
#endif
