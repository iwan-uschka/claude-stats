import AppKit
import ClaudeStatsCore
import Combine
import SwiftUI

/// The popover shown when the status item is clicked — the layout sketched in
/// `AGENTS.md`.
///
/// Reads everything from ``AppModel``'s published properties; it never touches a
/// data source directly, so the real providers can land behind the protocols
/// without this file changing.
struct PopoverView: View {
    @ObservedObject var model: AppModel

    /// Drives the reset countdowns and the freshness tag off a single tick, so
    /// they never disagree with each other. Injected rather than owned because
    /// only ``StatusItemController`` knows when the popover is actually visible.
    @ObservedObject var clock: PopoverClock

    init(model: AppModel, clock: PopoverClock) {
        self.model = model
        self.clock = clock
    }

    private var now: Date { clock.now }

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverMetrics.sectionSpacing) {
            header
            quotaSection
            Divider()
            planSection
            Divider()
            breakdownSection
            Divider()
            modelSection
            costSection
            if model.usingSampleData {
                sampleDataLine
            }
            ForEach(Array(model.activeErrors.enumerated()), id: \.offset) { _, error in errorLine(error) }
            Divider()
            footer
        }
        .padding(PopoverMetrics.contentPadding)
        .frame(width: PopoverMetrics.popoverWidth)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            ClaudeMarkView(size: 13)
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
            Text("Claude Stats")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
        }
    }

    // MARK: - Quota windows

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let snapshot = model.snapshot {
                WindowBarView(title: "5-hour window", window: snapshot.fiveHour, now: now)
                WindowBarView(title: "7-day window", window: snapshot.sevenDay, now: now)
                Text(sourceTag(for: snapshot))
                    .font(PopoverMetrics.captionFont)
                    .foregroundStyle(.secondary)
                if let warning = model.quotaWarning {
                    Text(warning)
                        .font(PopoverMetrics.captionFont)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                WindowBarView(title: "5-hour window", window: .empty, now: now)
                WindowBarView(title: "7-day window", window: .empty, now: now)
                // The cleared-cache notice wins over both fallbacks: it names a
                // state the user just caused on purpose, so it explains the empty
                // bars better than "none yet" or a staleness warning would.
                Text(model.quotaCacheClearedNotice
                    ?? model.quotaWarning
                    ?? "source: none yet — requires Claude Code's statusLine hook (Settings → Quota source)")
                    .font(PopoverMetrics.captionFont)
                    .foregroundStyle(quotaFallbackStyle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            clearCacheRow
        }
    }

    /// Orange only for a staleness warning; the cleared-cache notice is an
    /// expected, self-resolving state, not something to flag.
    private var quotaFallbackStyle: Color {
        if model.quotaCacheClearedNotice != nil { return Color.secondary }
        return model.quotaWarning != nil ? Color.orange : Color.secondary
    }

    /// Deliberately not gated on `snapshot == nil`: the whole point is to clear a
    /// value that looks live but is actually a stale write from another Claude
    /// Code session, so it has to be reachable while a number is on screen.
    private var clearCacheRow: some View {
        HStack {
            Spacer()
            Button("Clear Quota Cache") { model.clearQuotaCache() }
                .controlSize(.small)
                .font(PopoverMetrics.captionFont)
                .help("Deletes the cached statusline reading — use it when the percentage looks stuck or wrong. The next number comes from Claude Code's next statusline render.")
        }
    }

    private func sourceTag(for snapshot: QuotaSnapshot) -> String {
        let tag = DisplayFormat.sourceTag(
            confidence: snapshot.confidence,
            age: snapshot.age(asOf: now)
        )
        return snapshot.isStale(asOf: now) ? tag + " · stale" : tag
    }

    // MARK: - Plan / burn rate

    private var planSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            labelledLine("Plan", DisplayFormat.planDescription(model.planTier))
            if let usage = model.burnRateUsage {
                labelledLine("Burn rate", DisplayFormat.burnRate(Double(usage.totalTokens)))
                    .help(DisplayFormat.tokenSplit(usage))
            } else {
                labelledLine("Burn rate", "—")
            }
            if let note = model.burnRateUsage.flatMap(DisplayFormat.cacheReadNote) {
                cacheReadNoteLine(note)
            }
        }
    }

    /// Explains a token total that replayed cache reads dominate, so the
    /// headline number doesn't read as fresh work.
    private func cacheReadNoteLine(_ note: String) -> some View {
        Text(note)
            .font(PopoverMetrics.captionFont)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func labelledLine(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text("\(label):")
                .font(PopoverMetrics.bodyFont)
                .foregroundStyle(.secondary)
            Text(value)
                .font(PopoverMetrics.bodyFont)
            Spacer(minLength: 0)
        }
    }

    // MARK: - This Mac

    private var breakdownSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("This Mac")
                    .font(PopoverMetrics.sectionTitleFont)
                Spacer()
                Picker("Window", selection: $model.selectedWindow) {
                    ForEach(TimeWindow.allCases, id: \.self) { window in
                        Text(window.displayName).tag(window)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 132)
            }

            let breakdown = model.breakdown ?? .empty(window: model.selectedWindow)
            let rows = breakdown.orderedRows
            let peak = rows.map(\.usage.totalTokens).max() ?? 0

            VStack(alignment: .leading, spacing: 5) {
                ForEach(rows, id: \.entrypoint) { row in
                    EntrypointRow(
                        entrypoint: row.entrypoint,
                        usage: row.usage,
                        peakTokens: peak
                    )
                }
            }
            // Every entrypoint row summed — like "By model", the caption is
            // about the section's numbers as a whole, not any single row.
            if let note = DisplayFormat.cacheReadNote(breakdown.totalUsage) {
                cacheReadNoteLine(note)
            }
        }
    }

    // MARK: - By model

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("By model")
                    .font(PopoverMetrics.sectionTitleFont)
                Spacer()
                // Fixed window on purpose — not tied to the toggle above.
                Text("fixed 24h")
                    .font(PopoverMetrics.captionFont)
                    .foregroundStyle(.secondary)
            }

            if model.modelUsage.isEmpty {
                Text("No local model usage yet")
                    .font(PopoverMetrics.captionFont)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(model.modelUsage) { usage in
                        ModelUsageRow(usage: usage)
                    }
                }
                // Every model row summed — the note is about the section's
                // numbers as a whole, and one line reads better than one per
                // row. The sum itself is cached on ``AppModel``.
                if let note = DisplayFormat.cacheReadNote(model.modelUsageTotal) {
                    cacheReadNoteLine(note)
                }
            }
        }
    }

    private var costSection: some View {
        HStack {
            Text("Est. cost today")
                .font(PopoverMetrics.bodyFont)
            Spacer()
            Text(model.estimatedCostToday.map(DisplayFormat.cost) ?? "—")
                .font(PopoverMetrics.valueFont)
        }
    }

    private var sampleDataLine: some View {
        Text("Sample data — no Claude logs found")
            .font(PopoverMetrics.captionFont)
            .foregroundStyle(.orange)
    }

    private func errorLine(_ error: String) -> some View {
        Text(error)
            .font(PopoverMetrics.captionFont)
            .foregroundStyle(.red)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Refresh") { model.refresh(force: true) }
                .keyboardShortcut("r", modifiers: .command)
            Button("Settings") { model.openSettings() }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .controlSize(.small)
    }
}

#if DEBUG
// A clock that is never resumed keeps previews static, so the countdowns read
// exactly the values the mock data was built around.
#Preview("Popover") {
    PopoverView(model: .preview(), clock: PopoverClock())
}

#Preview("Popover — no data yet") {
    PopoverView(model: .previewEmpty(), clock: PopoverClock())
}

#Preview("Popover — stale, over budget, warning") {
    PopoverView(model: .previewDegraded(), clock: PopoverClock())
}

#Preview("Popover — no quota source installed") {
    PopoverView(
        model: .preview(snapshot: nil, error: ClaudeStatsError.noQuotaSourceAvailable.localizedDescription),
        clock: PopoverClock()
    )
}

#Preview("Popover — stale warning") {
    PopoverView(model: .previewStaleWarning(), clock: PopoverClock())
}

#Preview("Popover — stale warning, no prior snapshot") {
    PopoverView(model: .preview(snapshot: nil, warning: "Statusline cache is 14 minutes old."), clock: PopoverClock())
}

#Preview("Popover — quota cache just cleared") {
    PopoverView(model: .previewCacheCleared(), clock: PopoverClock())
}

#Preview("Popover — 24h breakdown") {
    PopoverView(model: .preview(window: .twentyFourHour), clock: PopoverClock())
}
#endif
