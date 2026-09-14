import ClaudeStatsCore
import SwiftUI

/// A single horizontal fill indicator: faint monochrome track, terracotta fill.
///
/// Dependency-free (no charting library) — it is one rounded rectangle inside
/// another, sized off the available width.
///
/// **The fill is ``PopoverMetrics/brandColor``, and it always is.** These bars
/// are the first thing in the popover and the reading it exists for, so they
/// take the app's one colour rather than the grey the text around them is set
/// in. The track stays `Color.primary` at ``trackOpacity``: the unused part of
/// a bar is absence, not a second reading, and tinting it would make a 5%-used
/// window look half terracotta.
///
/// **There is no over-budget or stale tint, and there must not be one.** The
/// resting fill is now the same ink a warning line is set in, so a bar that
/// went terracotta to raise an alarm would be indistinguishable from every
/// other bar on the card. The staleness warning is carried by
/// ``AppModel/quotaWarning``'s own line of text, which says what happened; an
/// over-budget window is carried by its percentage reading past 100%.
struct UsageBar: View {
    /// How the filled portion is painted. The track, the geometry and the
    /// corner radius are identical either way — only the fill differs, so the
    /// rows still read as one column of bars.
    enum FillStyle {
        /// The default: flat ``PopoverMetrics/brandColor``.
        case solid
        /// Diagonal stripes in the same brand ink, with the gaps showing the
        /// track underneath — for a bar that measures something different in
        /// kind from its neighbours (money spent against a monthly cap, not a
        /// rate-limit window). Same geometry as the solid fill, same spacing,
        /// same clip: only the ink changed when the bars took the brand colour.
        case hatched
    }

    var fraction: Double
    var height: CGFloat = 6
    var trackOpacity: Double = 0.12
    var fillStyle: FillStyle = .solid
    /// Set when this bar isn't already wrapped by a labelled, combined
    /// accessibility element (e.g. a caller using it standalone). A caller like
    /// `WindowBarView`, which already combines and labels the whole row,
    /// should leave this `nil` so it isn't overridden with an empty label.
    var accessibilityLabel: String? = nil

    private var clampedFraction: Double {
        DisplayFormat.clamped01(fraction)
    }

    var body: some View {
        let bar = GeometryReader { proxy in
            ZStack(alignment: .leading) {
                shape.fill(Color.primary.opacity(trackOpacity))
                fill
                    .frame(width: proxy.size.width * clampedFraction)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue(DisplayFormat.percent(fraction: clampedFraction))

        if let accessibilityLabel {
            bar.accessibilityLabel(accessibilityLabel)
        } else {
            bar
        }
    }

    @ViewBuilder
    private var fill: some View {
        switch fillStyle {
        case .solid:
            shape.fill(PopoverMetrics.brandColor)
        case .hatched:
            // No separate ground fill: the gaps between stripes show the
            // track underneath, same color as the bar's unfilled portion.
            DiagonalHatch(color: PopoverMetrics.brandColor)
                // Clipped to the same rounded rect the solid fill uses, so
                // the two styles are pixel-identical in outline.
                .clipShape(shape)
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
    }
}

/// 45° stripes, drawn to fill whatever space they're given.
///
/// A `Canvas` rather than a repeating image or a hard-stopped gradient: the
/// stripe spacing has to stay constant regardless of how wide the filled
/// portion is (a gradient's stops are relative to the shape, so a 10%-full bar
/// would get 10%-wide stripes), and the caller clips it to the bar's rounded
/// rect afterwards.
private struct DiagonalHatch: View {
    var color: Color
    /// Perpendicular-ish gap between stripes, in points.
    var spacing: CGFloat = 4
    var lineWidth: CGFloat = 1.0

    var body: some View {
        Canvas(opaque: false) { context, size in
            var path = Path()
            // Start a full height to the left so the first stripe still crosses
            // the top-left corner rather than beginning mid-bar.
            var x = -size.height
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += spacing
            }
            context.stroke(path, with: .color(color), lineWidth: lineWidth)
        }
    }
}

#if DEBUG
#Preview("Usage bar") {
    VStack(alignment: .leading, spacing: 10) {
        ForEach([0.0, 0.08, 0.31, 0.62, 0.94, 1.0, 1.7], id: \.self) { fraction in
            HStack {
                UsageBar(fraction: fraction)
                Text(DisplayFormat.percent(fraction: fraction))
                    .font(PopoverMetrics.valueFont)
                    .frame(width: 36, alignment: .trailing)
            }
        }
        UsageBar(fraction: 0.45, height: 4)
    }
    .padding()
    .frame(width: 280)
}

#Preview("Usage bar — hatched") {
    VStack(alignment: .leading, spacing: 10) {
        ForEach([0.0, 0.08, 0.31, 0.62, 1.0], id: \.self) { fraction in
            HStack {
                UsageBar(fraction: fraction, fillStyle: .hatched)
                Text(DisplayFormat.percent(fraction: fraction))
                    .font(PopoverMetrics.valueFont)
                    .frame(width: 36, alignment: .trailing)
            }
        }
        // Side by side with the solid style, which is the comparison that
        // matters: the two have to be distinguishable at a glance in a column.
        UsageBar(fraction: 0.62)
        UsageBar(fraction: 0.62, fillStyle: .hatched)
    }
    .padding()
    .frame(width: 280)
}
#endif
