import AppKit
import ClaudeStatsCore
import SwiftUI

/// Draws the status item's glyph: the Claude mark, then two thin vertical bars
/// for the 5-hour and 7-day windows.
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
    static let markSize: CGFloat = 14
    /// Gap between the mark and the first bar.
    static let markToBarsGap: CGFloat = 3.5
    static let barWidth: CGFloat = 3
    static let barHeight: CGFloat = 13
    static let barSpacing: CGFloat = 2.5
    static let barCornerRadius: CGFloat = 1
    /// Alpha of the unused portion of a bar.
    static let trackAlpha: CGFloat = 0.3

    static var width: CGFloat {
        markSize + markToBarsGap + barWidth * 2 + barSpacing
    }

    /// Template image for the given window fills (each 0...1, clamped).
    static func image(fiveHourFraction: Double, sevenDayFraction: Double) -> NSImage {
        let fractions = [
            DisplayFormat.clamped01(fiveHourFraction),
            DisplayFormat.clamped01(sevenDayFraction),
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
        image.accessibilityDescription = "Claude usage"
        return image
    }

    /// Snapshot-driven convenience; an absent snapshot draws empty bars.
    static func image(for snapshot: QuotaSnapshot?) -> NSImage {
        image(
            fiveHourFraction: snapshot?.fiveHour.fractionUsed ?? 0,
            sevenDayFraction: snapshot?.sevenDay.fractionUsed ?? 0
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
            // as "two bars" rather than as a missing element.
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
    let samples: [(String, Double, Double)] = [
        ("empty", 0, 0),
        ("mock", 0.62, 0.31),
        ("high", 0.94, 0.71),
        ("full", 1, 1),
    ]

    return VStack(spacing: 0) {
        ForEach([false, true], id: \.self) { dark in
            HStack(spacing: 18) {
                ForEach(samples, id: \.0) { sample in
                    VStack(spacing: 4) {
                        Image(nsImage: MenuBarGlyph.image(
                            fiveHourFraction: sample.1,
                            sevenDayFraction: sample.2
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
