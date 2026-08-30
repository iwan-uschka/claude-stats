import ClaudeStatsCore
import SwiftUI

/// One rate-limit window row: `5-hour window  ▓▓▓▓▓▓░░ 62%  resets in 2h 14m`.
struct WindowBarView: View {
    var title: String
    var window: QuotaWindow
    /// Passed in rather than read from the clock so the countdown ticks with the
    /// popover's timer and previews stay deterministic.
    var now: Date
    /// Whether a `nil` `window.resetsAt` renders as "reset pending" or as an
    /// empty column.
    ///
    /// The two account-wide bars always have documented reset semantics, so
    /// `nil` there really does mean a reset is pending. Scoped weekly rows'
    /// `resets_at` is the common case being absent entirely undocumented —
    /// "not reported", not "pending" — see ``QuotaScopedLimit``. Defaults to
    /// the original, always-shows-placeholder behavior so the two main bars
    /// don't have to opt back in.
    var showsPendingResetPlaceholder: Bool = true

    var body: some View {
        HStack(spacing: PopoverMetrics.rowSpacing) {
            Text(title)
                .font(PopoverMetrics.bodyFont)
                // Scoped rows take their label from the payload, so an
                // unexpectedly long model name has to truncate — wrapping would
                // make one row twice as tall as its neighbours.
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: PopoverMetrics.labelColumnWidth, alignment: .leading)

            UsageBar(fraction: window.fractionUsed)
                .frame(minWidth: 48)

            Text(DisplayFormat.percent(percentValue: window.percentUsed))
                .font(PopoverMetrics.valueFont)
                .frame(width: 34, alignment: .trailing)

            Text(window.resetsAt == nil && !showsPendingResetPlaceholder
                ? ""
                : DisplayFormat.resetCountdown(window.timeUntilReset(from: now)))
                .font(PopoverMetrics.captionFont)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("Window rows") {
    let now = Date()
    return VStack(alignment: .leading, spacing: 6) {
        WindowBarView(
            title: QuotaWindowKind.fiveHour.title,
            window: QuotaWindow(
                percentUsed: 62,
                resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60)
            ),
            now: now
        )
        WindowBarView(
            title: QuotaWindowKind.sevenDay.title,
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
