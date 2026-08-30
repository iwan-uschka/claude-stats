import AppKit
import ClaudeStatsCore
import SwiftUI

/// Draws the status item's glyph: the Claude mark, then three thin vertical
/// bars — 5-hour, 7-day, and the highest scoped weekly limit. All three are
/// always drawn, same as the first two: with no scoped-limit reading, the
/// third bar is simply empty (0% fill), exactly like an absent snapshot draws
/// the first two as empty tracks rather than omitting them.
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
    /// Height of the drawn glyph; a little under the 22pt menu bar so the icon
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

    /// Bars always drawn: 5-hour, 7-day, and scoped weekly — unconditionally,
    /// same as the other two. There is no narrower glyph to fall back to.
    static let barCount = 3

    /// Total glyph width. Fixed: all three bars are always drawn, so there is
    /// no variable-width state to compute from a snapshot.
    static let width: CGFloat = markSize + markToBarsGap
        + barWidth * CGFloat(barCount) + barSpacing * CGFloat(barCount - 1)

    /// Template image for the given window fills (each 0...1, clamped).
    ///
    /// `scopedWeeklyFraction` defaults to 0 (an empty third bar) when there is
    /// no scoped reading, same as the other two fractions default to 0 for an
    /// absent snapshot in ``image(for:)``. `scopedWeeklyLabel` only names the
    /// bar for VoiceOver when there is one; neither says what the scoped
    /// percentage is a share of — see ``QuotaScopedLimit``.
    static func image(
        fiveHourFraction: Double,
        sevenDayFraction: Double,
        scopedWeeklyFraction: Double = 0,
        scopedWeeklyLabel: String? = nil
    ) -> NSImage {
        let fractions = [
            DisplayFormat.clamped01(fiveHourFraction),
            DisplayFormat.clamped01(sevenDayFraction),
            DisplayFormat.clamped01(scopedWeeklyFraction),
        ]

        let image = NSImage(
            size: NSSize(width: width, height: height),
            flipped: true // SVG/UI y-down, so the mark path needs no flip.
        ) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(fractions: fractions, in: context)
            return true
        }
        image.isTemplate = true
        let devSuffix = BuildEnvironment.isDevelopmentBuild ? BuildEnvironment.devBuildSuffix : ""
        let scope = scopedWeeklyLabel.map { "\($0) " } ?? ""
        image.accessibilityDescription = "Claude Stats\(devSuffix): \(Int(fractions[0] * 100))% five-hour, "
            + "\(Int(fractions[1] * 100))% seven-day, \(Int(fractions[2] * 100))% \(scope)weekly usage"
        return image
    }

    /// Snapshot-driven convenience; an absent snapshot draws all three bars
    /// empty.
    ///
    /// The scoped bar takes the highest-percentage entry —
    /// ``QuotaSnapshot/scopedWeekly`` is already sorted descending, so `first`
    /// is that one, and it stays the same entry across polls. No entry at all
    /// (nil snapshot, or a snapshot with none) draws the third bar at 0%,
    /// same as the first two draw at 0% with no snapshot.
    static func image(for snapshot: QuotaSnapshot?) -> NSImage {
        let scoped = snapshot?.scopedWeekly.first
        return image(
            fiveHourFraction: snapshot?.fiveHour.fractionUsed ?? 0,
            sevenDayFraction: snapshot?.sevenDay.fractionUsed ?? 0,
            scopedWeeklyFraction: scoped?.window.fractionUsed ?? 0,
            scopedWeeklyLabel: scoped?.label
        )
    }

    private static func draw(fractions: [Double], in context: CGContext) {
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

        for (index, fraction) in fractions.enumerated() {
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
            context.setFillColor(gray: 0, alpha: 1)
            // Flipped context: "bottom" of the bar is its maxY.
            context.fill(
                CGRect(
                    x: barRect.minX,
                    y: barRect.maxY - filledHeight,
                    width: barRect.width,
                    height: filledHeight
                )
            )
            context.restoreGState()
        }
    }
}

#if DEBUG
/// Preview harness: shows the glyph over both menu bar backgrounds at a few
/// fill levels. `swift build` can't show this, but Xcode's canvas can.
#Preview("Menu bar glyph") {
    let samples: [(String, Double, Double, Double)] = [
        // Third bar always draws, same as the first two — empty here since
        // there's no scoped reading.
        ("empty", 0, 0, 0),
        ("mock", 0.62, 0.31, 0),
        ("high", 0.94, 0.71, 0),
        ("full", 1, 1, 0),
        ("scoped", 0.62, 0.31, 0.12),
        ("scoped hi", 0.94, 0.71, 0.55),
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
                            scopedWeeklyLabel: sample.3 == 0 ? nil : "Fable"
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
    .frame(width: 340)
}
#endif
