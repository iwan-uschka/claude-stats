import ClaudeStatsCore
import SwiftUI

/// One row of the "This Mac" breakdown: entrypoint name, a bar sized relative to
/// the busiest entrypoint in the same window, and the token count.
///
/// Bars are scaled against the window's peak rather than against a quota budget
/// — the point of this table is the *mix* of sources, and peak-relative bars keep
/// short rows visible on quiet windows.
struct EntrypointRow: View {
    var entrypoint: Entrypoint
    /// Kept split so the row can show the same input/output/cache tooltip the
    /// "By model" rows do; the headline number is ``TokenUsage/totalTokens``.
    var usage: TokenUsage
    /// Largest token count among the rows being shown.
    var peakTokens: Int

    private var tokens: Int { usage.totalTokens }

    var body: some View {
        HStack(spacing: PopoverMetrics.rowSpacing) {
            Text(entrypoint.displayName)
                .font(PopoverMetrics.bodyFont)
                .frame(width: PopoverMetrics.labelColumnWidth, alignment: .leading)

            UsageBar(
                fraction: DisplayFormat.barFraction(value: tokens, peak: peakTokens),
                height: 5
            )
            .frame(minWidth: 48)

            Text(DisplayFormat.tokens(tokens))
                .font(PopoverMetrics.valueFont)
                .foregroundStyle(.secondary)
                .frame(width: PopoverMetrics.valueColumnWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .help(DisplayFormat.tokenSplit(usage))
    }
}

#if DEBUG
#Preview("Entrypoint rows") {
    let breakdown = MockUsageStore.sampleBreakdowns[.twentyFourHour]!
    let peak = breakdown.orderedRows.map(\.usage.totalTokens).max() ?? 0
    return VStack(alignment: .leading, spacing: 5) {
        ForEach(breakdown.orderedRows, id: \.entrypoint) { row in
            EntrypointRow(entrypoint: row.entrypoint, usage: row.usage, peakTokens: peak)
        }
        Divider()
        // All-zero window: bars stay empty instead of dividing by zero.
        ForEach(EntrypointBreakdown.empty(window: .fiveHour).orderedRows, id: \.entrypoint) { row in
            EntrypointRow(entrypoint: row.entrypoint, usage: row.usage, peakTokens: 0)
        }
    }
    .padding()
    .frame(width: PopoverMetrics.popoverWidth)
}
#endif
