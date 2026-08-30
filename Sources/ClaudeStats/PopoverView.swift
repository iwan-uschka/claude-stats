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
                quotaWindowRow(.fiveHour, window: snapshot.fiveHour)
                quotaWindowRow(.sevenDay, window: snapshot.sevenDay)
                ForEach(snapshot.scopedWeekly) { limit in
                    scopedWeeklyRow(limit)
                }
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
                quotaWindowRow(.fiveHour, window: .empty)
                quotaWindowRow(.sevenDay, window: .empty)
                // The cleared-cache notice wins over both fallbacks: it names a
                // state the user just caused on purpose, so it explains the empty
                // bars better than "none yet" or a staleness warning would.
                Text(model.quotaCacheClearedNotice
                    ?? model.quotaWarning
                    ?? "source: none yet — run Claude Code once and the percentages appear on the next refresh")
                    .font(PopoverMetrics.captionFont)
                    .foregroundStyle(quotaFallbackStyle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            clearCacheRow
        }
    }

    /// One quota bar plus whatever promo notice belongs under it.
    ///
    /// Used by *both* branches of ``quotaSection`` so a snapshot and an empty
    /// state can't drift apart on which rows exist or what they're called.
    /// The inner 2 pt (against the section's 6 pt) is what makes the notice
    /// read as attached to this bar rather than as its own line.
    private func quotaWindowRow(_ bar: QuotaWindowKind, window: QuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            WindowBarView(title: bar.title, window: window, now: now)
            if let notice = model.promoNotice(for: bar) {
                promoNoticeLine(notice)
            }
        }
    }

    /// One per-model weekly sub-limit, as Claude Code reports it.
    ///
    /// The tooltip deliberately says nothing about what the percentage is a
    /// share of: the payload gives a bare `percent` with no denominator, and
    /// whether it measures a model-specific sub-cap or the account's weekly
    /// total is unverified — see ``QuotaScopedLimit``. Claiming either would be
    /// inventing a fact the source doesn't carry. No countdown appears when the
    /// entry has no `resets_at`, which is the common case.
    private func scopedWeeklyRow(_ limit: QuotaScopedLimit) -> some View {
        WindowBarView(
            title: "\(limit.label) (weekly)",
            window: limit.window,
            now: now
        )
        .help("Claude Code's own scoped weekly limit for \(limit.label), reported exactly as it comes from Claude Code. What the percentage is measured against is not documented.")
    }

    /// Claude Code's own promo line for a bar, with any URL in it clickable.
    ///
    /// Full content width, no indent: indenting to `labelColumnWidth` leaves
    /// ~220 pt, which wraps the real 59-character string onto three lines.
    private func promoNoticeLine(_ notice: RateLimitPromoNotice) -> some View {
        // Colours are set *inside the runs*, never with an outer
        // `.foregroundStyle(.secondary)` — that recolours the link range too
        // and kills the only affordance saying it's clickable.
        var attributed = AttributedString(notice.body.prefix)
        attributed.foregroundColor = .secondary
        if let label = notice.body.linkLabel, let url = notice.body.linkURL {
            var link = AttributedString(label)
            link.link = url
            link.foregroundColor = PopoverMetrics.brandLinkColor
            link.underlineStyle = .single
            attributed.append(link)
        }
        var tail = AttributedString(notice.body.suffix)
        tail.foregroundColor = .secondary
        attributed.append(tail)

        // `Text(AttributedString)` and `Text(someStringVariable)` never take
        // the `LocalizedStringKey` markdown path. A `Text` *literal* would —
        // and this text comes from a user-writable file, so a planted
        // `[label](evil://x)` would become a real link. Keep it an
        // `AttributedString`.
        //
        // One `Text`, no `Link`, no `HStack`: only a single `Text` wraps
        // mid-line, and this string is ~307 pt against 312 pt of content width.
        return Text(attributed)
            .font(PopoverMetrics.captionFont)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
            // Split label/value instead of one flattened `.accessibilityLabel`
            // so `.isLink` isn't just cosmetic: VoiceOver still needs an
            // explicit action, since collapsing to one element loses the
            // `AttributedString` link's own default activation.
            .accessibilityLabel(notice.bar.title)
            .accessibilityValue(notice.text)
            .accessibilityAddTraits(notice.body.linkURL != nil ? .isLink : [])
            .accessibilityAction {
                if let url = notice.body.linkURL {
                    NSWorkspace.shared.open(url)
                }
            }
            // Disclosing the resolved https URL is the anti-phishing affordance
            // for a scheme-less label — and matters more because any https
            // host is linkified, not just a known one.
            .help(notice.body.linkURL?.absoluteString ?? notice.text)
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
                .help("Deletes the cached statusline reading — use it when the percentage looks stuck or wrong. The bars fall back to Claude Code's own cached reading until the next statusline render.")
        }
    }

    private func sourceTag(for snapshot: QuotaSnapshot) -> String {
        let tag = DisplayFormat.sourceTag(
            confidence: snapshot.confidence,
            age: snapshot.age(asOf: now)
        )
        // Each source has its own cadence: the statusline hook fires per
        // render (~10 min), Claude Code refreshes its cached blob on a much
        // slower schedule (~30 min) — one threshold would mislabel the other.
        let threshold: TimeInterval = switch snapshot.confidence {
        case .official: QuotaSnapshot.defaultStalenessThreshold
        case .cachedOfficial: CachedUtilizationReader.defaultStalenessThreshold
        }
        return snapshot.isStale(asOf: now, threshold: threshold) ? tag + " · stale" : tag
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

#Preview("Popover — promo notice") {
    PopoverView(model: .previewPromoNotice(), clock: PopoverClock())
}

#Preview("Popover — promo notice, no quota source") {
    PopoverView(model: .previewPromoNoticeWithoutQuota(), clock: PopoverClock())
}

#Preview("Popover — 24h breakdown") {
    PopoverView(model: .preview(window: .twentyFourHour), clock: PopoverClock())
}
#endif
