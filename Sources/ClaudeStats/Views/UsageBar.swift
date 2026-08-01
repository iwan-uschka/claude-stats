import ClaudeStatsCore
import SwiftUI

/// A single horizontal fill indicator: faint track, opaque fill.
///
/// Deliberately monochrome and dependency-free (no charting library) — it is one
/// rounded rectangle inside another, sized off the available width.
struct UsageBar: View {
    var fraction: Double
    var height: CGFloat = 6
    var trackOpacity: Double = 0.12
    var fillOpacity: Double = 0.75
    /// Set when this bar isn't already wrapped by a labelled, combined
    /// accessibility element (e.g. a caller using it standalone). Callers like
    /// `WindowBarView`/`EntrypointRow` that already combine+label the whole row
    /// should leave this `nil` so they aren't overridden with an empty label.
    var accessibilityLabel: String? = nil

    private var clampedFraction: Double {
        DisplayFormat.clamped01(fraction)
    }

    var body: some View {
        let bar = GeometryReader { proxy in
            ZStack(alignment: .leading) {
                shape.fill(Color.primary.opacity(trackOpacity))
                shape
                    .fill(Color.primary.opacity(fillOpacity))
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

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
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
#endif
