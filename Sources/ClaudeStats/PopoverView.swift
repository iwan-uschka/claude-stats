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

    /// Drives the reset countdowns off a single tick, so the rows never
    /// disagree with each other. Injected rather than owned because
    /// only ``StatusItemController`` knows when the popover is actually visible.
    @ObservedObject var clock: PopoverClock

    /// The day the pointer is on in the "By source" chart, and the one in "By
    /// model". Two pieces of state, not one: the charts share an x-axis, but a
    /// table that rewrites itself while the pointer is in the block *below* it
    /// is a surprise, so hovering one block highlights only itself.
    @State private var hoveredSourceDay: Date?
    @State private var hoveredModelDay: Date?

    /// Width of the y-label column both charts set their labels in: whatever
    /// the wider of the two needs.
    ///
    /// One width for the pair, because two plots stacked in one column take the
    /// same x-ticks — left to themselves each starts where its own widest label
    /// ends, and `2G` is not as wide as `$2.50`, so the same x would mean one
    /// day in the upper plot and another in the lower. Measured from the labels
    /// the charts are about to draw, not reserved: a column wide enough for
    /// every label the formatters *could* produce (`$12.5k`) cost 19 pt of plot
    /// on an ordinary `$6` day.
    private var chartYLabelWidth: CGFloat {
        max(sourceChart(yLabelWidth: nil).naturalYLabelWidth, modelChart(yLabelWidth: nil).naturalYLabelWidth)
    }

    private func sourceChart(yLabelWidth: CGFloat?) -> DailyUsageChart {
        DailyUsageChart(
            days: model.dailyHistory.days,
            series: sourceSeries,
            metric: .tokens,
            bandsName: "source",
            hoveredDay: hoveredSourceDay,
            onHover: { hoveredSourceDay = $0 },
            yLabelWidth: yLabelWidth
        )
    }

    private func modelChart(yLabelWidth: CGFloat?) -> DailyUsageChart {
        DailyUsageChart(
            days: model.dailyHistory.days,
            series: modelSeries,
            metric: .cost,
            bandsName: "model",
            hoveredDay: hoveredModelDay,
            onHover: { hoveredModelDay = $0 },
            yLabelWidth: yLabelWidth
        )
    }

    /// The hover days are seeded rather than always starting empty so the
    /// README render harness and SwiftUI previews can show a hovered popover —
    /// offscreen there is no pointer to move.
    init(
        model: AppModel,
        clock: PopoverClock,
        hoveredSourceDay: Date? = nil,
        hoveredModelDay: Date? = nil
    ) {
        self.model = model
        self.clock = clock
        _hoveredSourceDay = State(initialValue: hoveredSourceDay)
        _hoveredModelDay = State(initialValue: hoveredModelDay)
    }

    private var now: Date { clock.now }

    var body: some View {
        // Read once and handed to both blocks: each read of `chartYLabelWidth`
        // builds and measures both charts, so letting the two sections each ask
        // for it would do that work twice per render for one identical value.
        let yLabelWidth = chartYLabelWidth
        return VStack(alignment: .leading, spacing: PopoverMetrics.sectionSpacing) {
            header
            quotaSection
            Divider()
            sourceSection(yLabelWidth: yLabelWidth)
            Divider()
            modelSection(yLabelWidth: yLabelWidth)
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
                // The one place the mark is drawn in brand ink rather than in
                // the surrounding text's: the menu bar glyph is a template
                // image the system tints, so this is where "Claude" can be a
                // colour rather than a shape.
                .foregroundStyle(PopoverMetrics.brandColor)
                .accessibilityHidden(true)
            Text("Claude Stats")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
        }
    }

    // MARK: - Quota windows

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: PopoverMetrics.quotaRowSpacing) {
            quotaTitleRow
            if let snapshot = model.snapshot {
                quotaWindowRow(.fiveHour, window: snapshot.fiveHour)
                quotaWindowRow(.sevenDay, window: snapshot.sevenDay)
                ForEach(snapshot.scopedWeekly) { limit in
                    scopedWeeklyRow(limit)
                }
                if let credits = snapshot.usageCredits {
                    usageCreditsRow(credits)
                }
                promoNoticeLines
                if let warning = model.quotaWarning {
                    Text(warning)
                        .font(PopoverMetrics.captionFont)
                        .foregroundStyle(PopoverMetrics.brandColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                quotaWindowRow(.fiveHour, window: nil)
                quotaWindowRow(.sevenDay, window: nil)
                promoNoticeLines
                // The cleared-cache notice wins over both fallbacks: it names a
                // state the user just caused — a manual clear, or swapping the
                // login, which clears the cache too — so it explains the empty
                // bars better than "none yet" or a staleness warning would.
                Text(model.quotaCacheClearedNotice
                    ?? model.quotaWarning
                    ?? "source: none yet — run Claude Code once and the percentages appear on the next refresh")
                    .font(PopoverMetrics.captionFont)
                    .foregroundStyle(quotaFallbackStyle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The quota block's section title, plus the freshness tag on the same
    /// line — the shape "By source" and "By model" already use, so the quota
    /// rows read as a titled section rather than as a preamble to the popover.
    ///
    /// The title names the active Anthropic account when something on disk
    /// actually said which one (see ``AppModel/quotaSectionTitle``); the
    /// tooltip is the one thing that still distinguishes a named account from
    /// the unstamped fallback, since the title itself deliberately reads as a
    /// section name in that case. Only the active account is ever shown —
    /// see `AGENTS.md` for why the inactive-account rows were removed.
    ///
    /// The tag is trailing rather than on a line of its own: it is metadata
    /// about the numbers below, and the title row has the width for it.
    private var quotaTitleRow: some View {
        HStack {
            Text(model.quotaSectionTitle)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(accountHelp(for: model.snapshot))
            Spacer(minLength: PopoverMetrics.rowSpacing)
            if let snapshot = model.snapshot {
                sourceTagLine(for: snapshot)
            }
        }
        .font(PopoverMetrics.sectionTitleFont)
    }

    /// Claude Code's own promo lines, in bar order, under the active account's
    /// last row.
    ///
    /// Collected here rather than hung under the bar each one names: the lines
    /// wrap to the full content width, so one sitting between two bars broke
    /// the column of rows in half. Bar order keeps the association readable
    /// when both bars have a notice, and every notice in ``AppModel/promoNotices``
    /// is rendered — a bar the reader couldn't map is already dropped upstream.
    @ViewBuilder
    private var promoNoticeLines: some View {
        ForEach(QuotaWindowKind.allCases, id: \.self) { bar in
            if let notice = model.promoNotice(for: bar) {
                promoNoticeLine(notice)
            }
        }
    }

    /// One of the two account-wide quota bars.
    ///
    /// Used by *both* branches of ``quotaSection`` so a snapshot and an empty
    /// state can't drift apart on which rows exist or what they're called. The
    /// bar's promo notice is *not* rendered here — see ``promoNoticeLines``,
    /// which collects them below the last row so a full-width line never splits
    /// the column of bars.
    ///
    /// A `nil` `window` — no snapshot at all, or a snapshot on which no source
    /// reported this window — renders the row as no reading rather than 0%; see
    /// ``WindowBarView``.
    private func quotaWindowRow(_ bar: QuotaWindowKind, window: QuotaWindow?) -> some View {
        WindowBarView(title: bar.title, window: window, now: now)
    }

    /// One per-model weekly sub-limit, as Claude Code reports it.
    ///
    /// The tooltip deliberately says nothing about what the percentage is a
    /// share of: the payload gives a bare `percent` with no denominator, and
    /// whether it measures a model-specific sub-cap or the account's weekly
    /// total is unverified — see ``QuotaScopedLimit``. Claiming either would be
    /// inventing a fact the source doesn't carry. The countdown column is
    /// empty when the entry has no `resets_at`, which is the common case — an
    /// absent reset here means "not reported", not `pending` the way it
    /// does for the two account-wide bars.
    private func scopedWeeklyRow(_ limit: QuotaScopedLimit) -> some View {
        WindowBarView(
            title: "\(limit.label) weekly",
            window: limit.window,
            now: now,
            showsPendingResetPlaceholder: false
        )
        .help("Claude Code's own scoped weekly limit for \(limit.label), reported exactly as it comes from Claude Code. What the percentage is measured against is not documented.")
    }

    /// Organisation usage credits: money spent against a monthly cap, not a
    /// rate-limit window — hence the hatched bar, which marks it as a different
    /// kind of measurement rather than a fourth window.
    ///
    /// The percent and caption columns match the window rows above exactly —
    /// same font, same secondary ink, same trailing edge — rather than the
    /// single wide `€0.00 of €33.00` reading this row used to carry in place
    /// of both. `63%` says what the bar already shows; `of €33.00` says what
    /// it's a percentage of. What was spent moves to the row's tooltip (see
    /// ``usageCreditsHelp(_:)``), which is the one place on the row that had
    /// nowhere else for it to go.
    ///
    /// The countdown column is empty on every window row because the payload
    /// reports no rollover timestamp for the monthly cap; here it carries the
    /// caption instead — the same ``PopoverMetrics/trailingValueColumnWidth``
    /// every row's trailing reading uses, ``PopoverMetrics/rowSpacing`` wider
    /// than a plain countdown needs, so a three-digit limit still fits. Same
    /// nested zero-spacing stack as ``WindowBarView`` too: the bar, the
    /// percent and the caption sit flush against each other with no real
    /// spacing, which is what keeps this row's percent column starting at the
    /// same x as the window rows' above it — see
    /// ``PopoverMetrics/trailingValueColumnWidth``.
    ///
    /// There is no absent-credits branch anywhere: no credits means no row —
    /// see ``UsageCredits`` on why that is the normal state and not an error.
    private func usageCreditsRow(_ credits: UsageCredits) -> some View {
        HStack(spacing: PopoverMetrics.rowSpacing) {
            Text("Usage credits")
                .font(PopoverMetrics.bodyFont)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: PopoverMetrics.labelColumnWidth, alignment: .leading)

            HStack(spacing: 0) {
                UsageBar(fraction: credits.window.fractionUsed, fillStyle: .hatched)
                    .frame(minWidth: 48)

                Text(DisplayFormat.windowPercent(credits.window))
                    .font(PopoverMetrics.valueFont)
                    .lineLimit(1)
                    .frame(width: PopoverMetrics.percentColumnWidth, alignment: .trailing)

                Text(DisplayFormat.creditsLimitCaption(credits.limit))
                    .font(PopoverMetrics.captionValueFont)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .frame(width: PopoverMetrics.trailingValueColumnWidth, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .combine)
        .help(usageCreditsHelp(credits))
    }

    private func usageCreditsHelp(_ credits: UsageCredits) -> String {
        var text = "Extra usage credits for this month, as Claude Code reports them:"
            + " \(DisplayFormat.moneySpend(used: credits.used, limit: credits.limit)) spent"
            + " of the monthly limit. The cap is monthly and the payload reports no"
            + " reset time for it, so there is no countdown."
        if credits.limitReached {
            text += " The monthly limit has been reached — extra usage is paused until it resets."
        }
        return text
    }

    /// The source tag — `cached` while Claude Code's own cached reading
    /// serves, nothing at all for a statusline capture. No age, no "stale":
    /// freshness is not displayed; an over-threshold reading surfaces as the
    /// terracotta warning line under the bars instead.
    ///
    /// Trailing on the active account's title row (see ``quotaTitleRow``).
    @ViewBuilder
    private func sourceTagLine(for snapshot: QuotaSnapshot) -> some View {
        if let tag = DisplayFormat.sourceTag(confidence: snapshot.confidence) {
            Text(tag)
                .font(PopoverMetrics.captionFont)
                .foregroundStyle(.secondary)
                .help("Claude Code's own cached copy of the rate limits, from its state file — it can be an hour or more behind. The statusline hook, once installed, replaces it.")
        }
    }

    /// Tooltip for the quota section's title: which account the rows describe, plus the `disabled_reason` for missing usage credits
    /// when the payload gave one.
    ///
    /// That reason has nowhere else to go: with no credits there is no credits
    /// row to hang it on, the source tag is usually absent, and it must not
    /// become an error line — "credits are off" is a normal configuration,
    /// not a fault.
    private func accountHelp(for snapshot: QuotaSnapshot?) -> String {
        var text = snapshot?.account != nil
            ? "Anthropic account these quota numbers belong to, as Claude Code's own state file names it."
            : "Claude Code's cache file for this account doesn't record which account it is."
        if let snapshot, snapshot.usageCredits == nil, let reason = snapshot.usageCreditsDisabledReason {
            text += " Usage credits aren't being reported for this account: \(reason)"
        }
        return text
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
            link.foregroundColor = PopoverMetrics.brandColor
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
            .accessibilityLabel(notice.bar.spokenTitle)
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

    /// Brand ink only for a staleness warning; the cleared-cache notice is an
    /// expected, self-resolving state, not something to flag.
    private var quotaFallbackStyle: Color {
        if model.quotaCacheClearedNotice != nil { return Color.secondary }
        return model.quotaWarning != nil ? PopoverMetrics.brandColor : Color.secondary
    }

    /// Explains a token total that replayed cache reads dominate, so the
    /// headline number doesn't read as fresh work. Only "By model" has one:
    /// it is the block a reader is most likely to take for "what the real work
    /// cost", and the same sentence under both tables would be one sentence too
    /// many on a card this dense.
    private func cacheReadNoteLine(_ note: String) -> some View {
        Text(note)
            .font(PopoverMetrics.captionFont)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// What both tables caption their numbers with at rest.
    ///
    /// Counted off the history rather than fixed at `Last 30 days`: a Mac whose
    /// logs are younger charts fewer days (see ``DailyUsageHistory/days``), and
    /// this caption is the one place that states which window the numbers under
    /// it belong to — a wrong count there is worse than no caption.
    private var chartWindowCaption: String {
        "Last \(model.dailyHistory.days.count) days"
    }

    /// One of the two symmetric usage blocks: a section title, a stacked
    /// thirty-day chart, and a table of the same window's numbers under it.
    ///
    /// Written once and called twice rather than laid out twice, which is what
    /// makes "same columns, same stack order, same hover rule" a fact instead of
    /// a convention two pieces of code happen to agree on today. The two blocks
    /// differ in exactly three things: the title, which field of a day the chart
    /// plots, and which split the bands come from.
    ///
    /// No window tag opposite the title, unlike the quota block: the x-axis is
    /// dated, so it already says how far back the chart reaches and that it ends
    /// today, and the table's caption says the same in words for the numbers.
    @ViewBuilder
    private func usageBlock(
        title: String,
        chart: DailyUsageChart,
        series: [DailyUsageSeries],
        hoveredDay: Date?,
        showsCacheReadNote: Bool = false
    ) -> some View {
        let table = DailyUsageTable(
            series: series,
            total: model.dailyHistory.total,
            days: model.dailyHistory.days,
            hoveredDay: hoveredDay,
            restingCaption: chartWindowCaption,
            // Read from the model on every render rather than captured once, so
            // flipping the preference in Settings changes the open popover.
            restingRange: model.defaultDisplayRange
        )
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(PopoverMetrics.sectionTitleFont)

            if model.dailyHistory.isEmpty {
                // A flat line through zero would read as "you stopped working"
                // rather than "there is nothing here yet".
                Text("No local usage yet")
                    .font(PopoverMetrics.captionFont)
                    .foregroundStyle(.secondary)
            } else {
                chart
                    .padding(.vertical, PopoverMetrics.chartMargin)
                table
                // Computed from what the table is showing, not from a fixed
                // window: hovering a day has to re-state the share for that day,
                // or a thirty-day percentage sits under one day's numbers.
                if showsCacheReadNote, let note = DisplayFormat.cacheReadNote(table.shownUsage) {
                    cacheReadNoteLine(note)
                }
            }
        }
    }

    // MARK: - By source

    /// Where the tokens came from: thirty days of usage stacked per source,
    /// over a table of that window's per-source counts and spend.
    ///
    /// This is what is left of a chain of redesigns — a segmented picker with
    /// peak-relative bars, then a 3x3 table of windows, then a chart with a
    /// five-hour legend row under it. The legend went the way the `24h` and `7d`
    /// columns went before it: every other number in the popover is now the
    /// chart's own window, and a five-hour reading beneath a thirty-day plot was
    /// the last place two windows still met in one row.
    private func sourceSection(yLabelWidth: CGFloat) -> some View {
        usageBlock(
            title: "By source",
            chart: sourceChart(yLabelWidth: yLabelWidth),
            series: sourceSeries,
            hoveredDay: hoveredSourceDay
        )
    }

    private var sourceSeries: [DailyUsageSeries] {
        DailyUsageSeries.sources(from: model.dailyHistory)
    }

    // MARK: - By model

    /// Where the money went: the same thirty days, stacked as estimated spend
    /// per model family, with its own table.
    ///
    /// The top edge of this stack *is* the line the popover used to draw as a
    /// separate "Estimated cost" section — one series with nothing under it — so
    /// that section and its chart are gone rather than kept alongside: the same
    /// curve now also says which models are under it. Today's spend went with
    /// it, and is hover-only now by decision: one window and one hover rule for
    /// every local number beats a row that was the popover's last fixed reading.
    ///
    /// Deliberately a per-model chart, which an earlier round rejected. It lost
    /// then on two counts — five bands against a palette of three shades, and
    /// sitting above rows tagged `fixed 24h` — and both are gone: the ramp
    /// carries five distinguishable shades, and there is no second window left
    /// to be ambiguous about.
    private func modelSection(yLabelWidth: CGFloat) -> some View {
        usageBlock(
            title: "By model",
            chart: modelChart(yLabelWidth: yLabelWidth),
            series: modelSeries,
            hoveredDay: hoveredModelDay,
            showsCacheReadNote: true
        )
    }

    private var modelSeries: [DailyUsageSeries] {
        DailyUsageSeries.models(from: model.dailyHistory)
    }

    private var sampleDataLine: some View {
        Text("Sample data — no Claude logs found")
            .font(PopoverMetrics.captionFont)
            .foregroundStyle(PopoverMetrics.brandColor)
    }

    /// An error line, in the same brand ink as the warning and sample-data
    /// lines — the popover has one colour, and the words say which of the three
    /// this is. See ``PopoverMetrics/brandColor``.
    private func errorLine(_ error: String) -> some View {
        Text(error)
            .font(PopoverMetrics.captionFont)
            .foregroundStyle(PopoverMetrics.brandColor)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Footer

    /// The popover's actions, including "Clear Quota Cache".
    ///
    /// That button sits here rather than under the quota rows it acts on: the
    /// quota section is limited to the active account's own numbers (see
    /// `AGENTS.md`, "Only the active account is shown"), so there is no natural
    /// place for a manual action among them. It is deliberately not gated on
    /// `snapshot == nil` — the whole point is to clear a value that looks live
    /// but is wrong, every session's cache file agreeing on a bad number, so it
    /// has to be reachable while a number is on screen.
    private var footer: some View {
        HStack(spacing: 6) {
            Button("Refresh") { model.refresh(force: true) }
                .keyboardShortcut("r", modifiers: .command)
            // `.fixedSize()` because four buttons all but fill 312 pt of content
            // width: without it the `HStack` shrinks the longest label first
            // and this one renders as "Clear Quota Cac…" while the trailing
            // spacer keeps its slack.
            Button("Clear Quota Cache") { model.clearQuotaCache() }
                .fixedSize()
                .help("Deletes the cached statusline reading — use it when the percentage looks stuck or wrong. The bars fall back to Claude Code's own cached reading until the next statusline render.")
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

#Preview("Popover — usage credits") {
    PopoverView(model: .previewUsageCredits(), clock: PopoverClock())
}

#Preview("Popover — usage credits, limit reached") {
    PopoverView(
        model: .previewUsageCredits(credits: UsageCredits(
            used: MoneyAmount(amountMinor: 3_300, currency: "EUR", exponent: 2),
            limit: MoneyAmount(amountMinor: 3_300, currency: "EUR", exponent: 2),
            percentUsed: 100,
            severity: "critical",
            limitReached: true
        )),
        clock: PopoverClock()
    )
}

/// The state the README screenshot is rendered from — see
/// ``AppModel/previewShowcase(now:)``. Kept here so a layout change can be
/// judged in the canvas before regenerating the committed PNG.
#Preview("Popover — README showcase") {
    PopoverView(model: .previewShowcase(), clock: PopoverClock())
}
#endif
