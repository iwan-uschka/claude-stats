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

    private var clampedFraction: Double {
        DisplayFormat.clamped01(fraction)
    }

    var body: some View {
        GeometryReader { proxy in
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
