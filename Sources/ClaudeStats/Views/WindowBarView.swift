import ClaudeStatsCore
import SwiftUI

/// One rate-limit window row: `5-hour window  ▓▓▓▓▓▓░░ 62%  resets in 2h 14m`.
struct WindowBarView: View {
    var title: String
    var window: QuotaWindow
    /// Passed in rather than read from the clock so the countdown ticks with the
    /// popover's timer and previews stay deterministic.
    var now: Date

    var body: some View {
        HStack(spacing: PopoverMetrics.rowSpacing) {
            Text(title)
                .font(PopoverMetrics.bodyFont)
                .frame(width: PopoverMetrics.labelColumnWidth, alignment: .leading)

            UsageBar(fraction: window.fractionUsed)
                .frame(minWidth: 48)

            Text(DisplayFormat.percent(percentValue: window.percentUsed))
                .font(PopoverMetrics.valueFont)
                .frame(width: 34, alignment: .trailing)

            Text(DisplayFormat.resetCountdown(window.timeUntilReset(from: now)))
                .font(PopoverMetrics.captionFont)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

#if DEBUG
#Preview("Window rows") {
    let now = Date()
    return VStack(alignment: .leading, spacing: 6) {
        WindowBarView(
            title: "5-hour window",
            window: QuotaWindow(
                percentUsed: 62,
                resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60)
            ),
            now: now
        )
        WindowBarView(
            title: "7-day window",
            window: QuotaWindow(
                percentUsed: 31,
                resetsAt: now.addingTimeInterval(4 * 86_400 + 6 * 3600)
            ),
            now: now
        )
        WindowBarView(
            title: "no reset info",
            window: QuotaWindow(percentUsed: 0),
            now: now
        )
        WindowBarView(
            title: "over budget",
            window: QuotaWindow(percentUsed: 118, resetsAt: now.addingTimeInterval(45)),
            now: now
        )
    }
    .padding()
    .frame(width: PopoverMetrics.popoverWidth)
}
#endif
