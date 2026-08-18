import ClaudeStatsCore
import SwiftUI

/// One row of the "By model" section: `Sonnet   2.1M tok   $3.15`.
struct ModelUsageRow: View {
    var usage: ModelUsage

    var body: some View {
        HStack(spacing: PopoverMetrics.rowSpacing) {
            Text(usage.displayName)
                .font(PopoverMetrics.bodyFont)
                .frame(width: PopoverMetrics.labelColumnWidth, alignment: .leading)

            Spacer(minLength: 0)

            Text("\(DisplayFormat.tokens(usage.tokens)) tok")
                .font(PopoverMetrics.valueFont)
                .foregroundStyle(.secondary)
                .frame(width: PopoverMetrics.modelTokenColumnWidth, alignment: .trailing)

            Text(DisplayFormat.cost(usage.estimatedCostUSD))
                .font(PopoverMetrics.valueFont)
                .frame(width: PopoverMetrics.costColumnWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .help(DisplayFormat.tokenSplit(usage.usage))
    }
}

#if DEBUG
#Preview("Model rows") {
    VStack(alignment: .leading, spacing: 5) {
        ForEach(MockUsageStore.sampleModelUsage) { usage in
            ModelUsageRow(usage: usage)
        }
        Divider()
        // Unrecognised model ID: falls back to the raw ID as the label.
        ModelUsageRow(
            usage: ModelUsage(
                modelID: "claude-experimental-9",
                usage: TokenUsage(inputTokens: 250, outputTokens: 1_000),
                estimatedCostUSD: 0
            )
        )
        // 4-digit spend: exercises the column width sized for `$1234.56`.
        ModelUsageRow(
            usage: ModelUsage(
                modelID: "claude-opus-5",
                usage: TokenUsage(inputTokens: 4_000_000, cacheReadInputTokens: 900_000_000),
                estimatedCostUSD: 1_234.56
            )
        )
    }
    .padding()
    .frame(width: PopoverMetrics.popoverWidth)
}
#endif
