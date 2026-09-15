import ClaudeStatsCore
import SwiftUI

/// One rate-limit window row: `5-hour  ▓▓▓▓▓▓░░ 62%  2h 14m`.
///
/// A `nil` ``window`` is the "no reading" row — `—  no data` over an empty
/// track. That is not 0%: it means no quota source currently reports the
/// window at all, which is the normal state right after one rolls over. Scoped
/// weekly and usage-credits rows always have a window and pass a non-`nil` one.
struct WindowBarView: View {
    var title: String
    /// The window to render, or `nil` when nothing reported one — see the type
    /// note.
    var window: QuotaWindow?
    /// Passed in rather than read from the clock so the countdown ticks with the
    /// popover's timer and previews stay deterministic.
    var now: Date
    /// Whether a `nil` `window.resetsAt` renders as `pending` or as an
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

            // The bar and both readings sit in one zero-spacing stack — no
            // `rowSpacing` between any of them — so every row's percent
            // column starts at the same x regardless of what its own
            // trailing reading needs (a countdown here, `of €33.00` on
            // ``PopoverView``'s usage-credits row). That single shared shape
            // is also why the bar is a member of this stack rather than the
            // row's own direct child: see
            // ``PopoverMetrics/trailingValueColumnWidth``.
            //
            // Both readings are still right-aligned in columns wider than
            // anything they hold, so `62%` stands clear of `2h 2m` on the
            // column widths' own slack alone.
            //
            // The percentage's right edge lands 253 pt from the row's leading
            // edge, and the bar takes everything in front of it — see
            // ``PopoverMetrics/trailingValueColumnWidth``, which is where
            // those points came from, and ``PopoverMetrics/quotaBarWidth``,
            // where they went.
            HStack(spacing: 0) {
                // An unknown window draws the empty track — the same pixels as
                // 0%, but the two text columns say which of the two it is. The
                // bar's own "0%" accessibility value would put back the number
                // nobody reported, so it's hidden from the row's combined
                // announcement.
                UsageBar(fraction: window?.fractionUsed ?? 0)
                    .frame(minWidth: 48)
                    .accessibilityHidden(window == nil)

                Text(DisplayFormat.windowPercent(window))
                    .font(PopoverMetrics.valueFont)
                    .lineLimit(1)
                    .frame(width: PopoverMetrics.percentColumnWidth, alignment: .trailing)

                Text(DisplayFormat.windowCountdown(
                    window, from: now, showsPendingResetPlaceholder: showsPendingResetPlaceholder
                ))
                    // A countdown is a number and it ticks: monospaced digits
                    // keep `2h 14m` from jittering as it counts down past
                    // `2h 9m`, and keep the column of them right-aligned on the
                    // same stems.
                    .font(PopoverMetrics.captionValueFont)
                    // Pinned like the percentage beside it: the column is sized
                    // to `11d 11h`, and a payload with a far-future `resets_at`
                    // must truncate rather than grow the row to two lines.
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .frame(width: PopoverMetrics.trailingValueColumnWidth, alignment: .trailing)
            }
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
        // No source reports this window at all — empty track, no percentage.
        WindowBarView(
            title: "unknown",
            window: nil,
            now: now
        )
    }
    .padding()
    .frame(width: PopoverMetrics.popoverWidth)
}
#endif
