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
            sourceSection
            Divider()
            modelSection
            Divider()
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
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                quotaWindowRow(.fiveHour, window: nil)
                quotaWindowRow(.sevenDay, window: nil)
                promoNoticeLines
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
            otherAccountsSection
        }
    }

    /// The quota block's section title, plus the freshness tag on the same
    /// line — the shape "Tokens by source" and "By model" already use, so the quota
    /// rows read as a titled section rather than as a preamble to the popover.
    ///
    /// The title names the active Anthropic account when something on disk
    /// actually said which one (see ``AppModel/quotaSectionTitle``); the
    /// tooltip is the one thing that still distinguishes a named account from
    /// the unstamped fallback, since the title itself deliberately reads as a
    /// section name in that case.
    ///
    /// The tag is trailing rather than on a line of its own: it is metadata
    /// about the numbers below, and the title row has the width for it.
    private var quotaTitleRow: some View {
        HStack {
            HStack(spacing: PopoverMetrics.accountMarkerSpacing) {
                if model.showsAccountStateMarkers {
                    accountStateMarker(active: true)
                }
                Text(model.quotaSectionTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
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

    /// One collapsed group per account this Mac has readings for *other* than
    /// the active one — what is left behind after switching the global login.
    ///
    /// Each group starts closed, so the popover's height doesn't grow by a
    /// whole second account's worth of rows for readings the user is not
    /// currently living in. The collapsed row is a cross icon and the account
    /// name, nothing else — no summary percentage, which would be a number
    /// about an account the bars above aren't describing. It pairs with the
    /// checkmark ``quotaTitleRow`` takes on once these groups exist, and is set
    /// in the same ``PopoverMetrics/sectionTitleFont`` in the same primary ink,
    /// so the two read as one list of accounts rather than as a section and a
    /// footnote under it.
    ///
    /// The whole row is one plain `Button`, not a ``DisclosureGroup``: a
    /// disclosure toggles from its chevron alone, and puts that chevron on the
    /// left where it reports the group's *state*. Here the caret is trailing
    /// and names the **action** instead — `chevron.down` on a closed row means
    /// "reveal below", `chevron.up` on an open one means "collapse" — which is
    /// the one thing a reader of a collapsed row wants to know.
    ///
    /// Separated by whitespace alone — ``PopoverMetrics/accountGroupSpacing``,
    /// no divider and no indent. A `Divider()` per group is what the popover
    /// used to do, and it collided with the dividers that mark the top-level
    /// sections: the same line meant both "next section" and "next account".
    ///
    /// Expanded, the content is exactly what used to render inline: the same
    /// rows and the same "no reading" rendering as the active account, each
    /// with its own freshness tag, since these readings age independently (the
    /// account nobody is logged in as stops being written to at all). That
    /// includes the usage-credits row and its `disabled_reason` tooltip:
    /// `spend` normally only reaches us for the active login, but a cache file
    /// written just before a switch can still carry one, and a stale reading
    /// shown with its own freshness tag beats silently dropping a reading the
    /// other rows would have shown. Empty on a one-account machine, which is
    /// every machine until the user switches accounts.
    ///
    /// Which groups are open lives on ``AppModel/expandedOtherAccounts`` rather
    /// than in `@State` here, so it survives the popover being closed and
    /// reopened, and a poll rebuilding the rows — and is deliberately not
    /// persisted across launches, since the set of other accounts isn't
    /// either.
    @ViewBuilder
    private var otherAccountsSection: some View {
        // Explicitly guarded rather than left to an empty `ForEach`, so the
        // one-account machine — every machine until the user switches logins —
        // puts nothing at all into the quota `VStack` here.
        if !model.otherAccountSnapshots.isEmpty {
            VStack(alignment: .leading, spacing: PopoverMetrics.accountGroupSpacing) {
                ForEach(Array(model.otherAccountSnapshots.enumerated()), id: \.offset) { _, snapshot in
                    let expanded = model.isOtherAccountExpanded(snapshot)
                    VStack(alignment: .leading, spacing: PopoverMetrics.quotaRowSpacing) {
                        Button {
                            model.toggleOtherAccountExpansion(for: snapshot)
                        } label: {
                            HStack(spacing: PopoverMetrics.accountMarkerSpacing) {
                                accountStateMarker(active: false)
                                // An unstamped group is genuinely "we don't know", not a
                                // nameless account — see `AppModel.otherAccountTitle(for:)`.
                                Text(model.otherAccountTitle(for: snapshot))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: PopoverMetrics.rowSpacing)
                                // The caret names the action, not the state:
                                // pointing down on a closed row because
                                // clicking reveals rows below it, up on an open
                                // one because clicking folds them away. It
                                // inherits the row's ink, so it reads as part
                                // of the label rather than as a control bolted
                                // to its end.
                                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                    .accessibilityHidden(true)
                            }
                            .font(PopoverMetrics.sectionTitleFont)
                            // Secondary ink on purpose, against the active
                            // title's primary: same weight, one step dimmer, so
                            // the row reads as an account heading that is not
                            // the one the bars above describe. Icon, name and
                            // caret all inherit it.
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(accountHelp(for: snapshot))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityValue(expanded ? "expanded" : "collapsed")

                        if expanded {
                            VStack(alignment: .leading, spacing: 4) {
                                WindowBarView(title: QuotaWindowKind.fiveHour.title, window: snapshot.fiveHour, now: now)
                                WindowBarView(title: QuotaWindowKind.sevenDay.title, window: snapshot.sevenDay, now: now)
                                ForEach(snapshot.scopedWeekly) { limit in
                                    scopedWeeklyRow(limit)
                                }
                                if let credits = snapshot.usageCredits {
                                    usageCreditsRow(credits)
                                }
                                sourceTagLine(for: snapshot)
                            }
                        }
                    }
                }
            }
            // The quota `VStack` already spaces its rows; this tops the first
            // group's gap up to `accountGroupSpacing` so it reads as separated
            // from the bars rather than as one more row under them.
            .padding(.top, PopoverMetrics.accountGroupSpacing - PopoverMetrics.quotaRowSpacing)
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
    /// absent reset here means "not reported", not "reset pending" the way it
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
    /// The value column shows money, not the percentage: `0%` of an unstated
    /// budget says nothing, where `€0.00 of €33.00` says both. It is formatted
    /// from the payload's own `currency` and `exponent` (see
    /// ``DisplayFormat/money(_:locale:)``) — never a hardcoded symbol or a
    /// hardcoded divide by 100, which would be silently wrong for an org billed
    /// in a zero-decimal currency.
    ///
    /// The countdown column is empty because the payload reports no rollover
    /// timestamp for the monthly cap; the value spans both trailing columns
    /// instead, so it still ends flush with the countdowns above it.
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

            UsageBar(fraction: credits.window.fractionUsed, fillStyle: .hatched)
                .frame(minWidth: 48)

            Text(DisplayFormat.moneySpend(used: credits.used, limit: credits.limit))
                .font(PopoverMetrics.valueFont)
                .frame(width: PopoverMetrics.percentAndCountdownColumnWidth, alignment: .trailing)
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
    /// orange warning line under the bars instead.
    ///
    /// Trailing on the active account's title row (see ``quotaTitleRow``) and
    /// at the foot of an expanded other-account group, which has no title row
    /// of its own. Those groups come from statusline files, so in practice
    /// the foot stays empty; it is rendered from the same rule so the two
    /// places can't drift.
    @ViewBuilder
    private func sourceTagLine(for snapshot: QuotaSnapshot) -> some View {
        if let tag = DisplayFormat.sourceTag(confidence: snapshot.confidence) {
            Text(tag)
                .font(PopoverMetrics.captionFont)
                .foregroundStyle(.secondary)
                .help("Claude Code's own cached copy of the rate limits, from its state file — it can be an hour or more behind. The statusline hook, once installed, replaces it.")
        }
    }

    /// The active/inactive marker in front of an account name: the same
    /// checkmark Settings shows next to "Statusline hook installed", and a
    /// cross for a login nobody is signed in as. Deliberately uncoloured —
    /// they inherit the title's ink — because "inactive" is a state, not a
    /// fault; the shapes alone carry the contrast. Shown only while both
    /// kinds exist, see ``AppModel/showsAccountStateMarkers``.
    private func accountStateMarker(active: Bool) -> some View {
        Image(systemName: active ? "checkmark.circle.fill" : "xmark.circle.fill")
            .accessibilityLabel(active ? "Active account" : "Inactive account")
    }

    /// Tooltip for an account title or disclosure label: which account the
    /// rows describe, plus the `disabled_reason` for missing usage credits
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

    /// Orange only for a staleness warning; the cleared-cache notice is an
    /// expected, self-resolving state, not something to flag.
    private var quotaFallbackStyle: Color {
        if model.quotaCacheClearedNotice != nil { return Color.secondary }
        return model.quotaWarning != nil ? Color.orange : Color.secondary
    }

    /// Explains a token total that replayed cache reads dominate, so the
    /// headline number doesn't read as fresh work. Only "By model" has one:
    /// "Tokens by source" captions a chart spanning 30 days with legend numbers from a
    /// five-hour window, so it has no single total for a note to describe.
    private func cacheReadNoteLine(_ note: String) -> some View {
        Text(note)
            .font(PopoverMetrics.captionFont)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - By source

    /// Thirty days of local usage as a stacked chart, with one legend row of
    /// numbers under it.
    ///
    /// This replaced a 3x3 table — one row per entrypoint, one column per
    /// ``TimeWindow``. The `24h` and `7d` columns were integrals over ranges
    /// the chart's x-axis now covers (the last point, the last seven), so they
    /// went. `5h` did not: a daily chart has no intra-day resolution, it is the
    /// only sub-day reading in the popover, and it is the machine-local
    /// counterpart to the account-wide five-hour quota bar above — so it stays,
    /// as the legend's value rather than as a column.
    ///
    /// The chart covers ``AppModel/chartWindowDays``, or fewer days on a Mac
    /// whose logs don't go back that far — which the dated x-axis says by
    /// itself, so the section carries no window tag.
    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // No window tag opposite the title: the x-axis is dated, so it
            // already says both how far back the chart reaches and that it ends
            // today. "By model" still needs its `fixed 24h` tag, having no axis
            // of its own.
            Text("Tokens by source")
                .font(PopoverMetrics.sectionTitleFont)

            if model.dailyHistory.isEmpty {
                // A flat line through zero would read as "you stopped working"
                // rather than "there is nothing here yet".
                Text("No local usage yet")
                    .font(PopoverMetrics.captionFont)
                    .foregroundStyle(.secondary)
            } else {
                DailyUsageChart(days: model.dailyHistory.days, series: sourceSeries)
                    .padding(.vertical, PopoverMetrics.chartMargin)
                sourceLegend
            }
        }
    }

    private var sourceSeries: [DailyUsageSeries] {
        DailyUsageSeries.sources(from: model.dailyHistory)
    }

    /// One chip per source: swatch, label, and its five-hour token count.
    ///
    /// Zipped against ``Entrypoint/displayOrder`` because
    /// ``DailyUsageSeries/sources(from:)`` builds the bands in exactly that
    /// order — pinned by a test, since the chip's number comes from the
    /// entrypoint while its swatch comes from the band.
    private var sourceLegend: some View {
        HStack(spacing: 0) {
            ForEach(Array(zip(Entrypoint.displayOrder, sourceSeries).enumerated()), id: \.offset) { index, pair in
                if index > 0 { Spacer(minLength: PopoverMetrics.rowSpacing) }
                legendChip(entrypoint: pair.0, band: pair.1)
            }
            Spacer(minLength: PopoverMetrics.rowSpacing)
            // Labels every chip's number, the way the table's column headers
            // labelled every cell under them.
            Text(TimeWindow.fiveHour.displayName)
                .font(PopoverMetrics.captionFont)
                .foregroundStyle(.secondary)
        }
    }

    private func legendChip(entrypoint: Entrypoint, band: DailyUsageSeries) -> some View {
        let usage = breakdown(for: .fiveHour).usage(for: entrypoint)
        return HStack(spacing: PopoverMetrics.legendSwatchSpacing) {
            Circle()
                .fill(Color.primary.opacity(band.shade))
                .frame(width: PopoverMetrics.legendSwatchSize, height: PopoverMetrics.legendSwatchSize)
            Text(entrypoint.displayName)
                .font(PopoverMetrics.bodyFont)
            Text(DisplayFormat.tokens(usage.totalTokens))
                .font(PopoverMetrics.valueFont)
        }
        .lineLimit(1)
        // One element per source, like the table's cells: a bare "298.5M"
        // announced on its own says neither which source nor which window.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entrypoint.displayName), \(TimeWindow.fiveHour.displayName)")
        .accessibilityValue(DisplayFormat.tokens(usage.totalTokens))
        // The full input/output/cache split lived on the table's cells; it
        // moves here rather than being dropped.
        .help(DisplayFormat.tokenSplit(usage))
    }

    /// The breakdown for one window, or an all-zero one before the first
    /// reload has landed — every window is recomputed together, so a missing
    /// key means "nothing read yet", never "this window is stale".
    private func breakdown(for window: TimeWindow) -> EntrypointBreakdown {
        model.breakdownsByWindow[window] ?? .empty(window: window)
    }

    // MARK: - By model

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("By model")
                    .font(PopoverMetrics.sectionTitleFont)
                Spacer()
                // Fixed window on purpose, and tagged as such: the chart
                // above spans thirty dated days, so "which window is this?" is
                // a live question for the rows below it.
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

    // MARK: - Est. cost

    /// Thirty days of spend over today's exact figure.
    ///
    /// "Est." sits in the section title rather than on the row, where it now
    /// qualifies the chart too. It has to: a curve invites reading the area
    /// under it as a monthly bill, and this is a local estimate from published
    /// per-token prices — on a subscription, spend that was never charged.
    ///
    /// The chart and the row can't disagree. Both count from local midnight on
    /// the same calendar, and today is always inside the retention window, so
    /// the curve's last point is the row's number.
    private var costSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Est. cost")
                .font(PopoverMetrics.sectionTitleFont)

            if !model.dailyHistory.isEmpty {
                DailyCostChart(
                    days: model.dailyHistory.days,
                    points: model.dailyHistory.total
                )
                .padding(.vertical, PopoverMetrics.chartMargin)
            }

            HStack {
                Text("Today")
                    .font(PopoverMetrics.bodyFont)
                Spacer()
                Text(model.estimatedCostToday.map(DisplayFormat.cost) ?? "—")
                    .font(PopoverMetrics.valueFont)
            }
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

    /// The popover's actions, including "Clear Quota Cache".
    ///
    /// That button sits here rather than under the quota rows it acts on: in
    /// the quota section it floated after the other accounts' groups, reading
    /// as though it belonged to the last one. It is deliberately not gated on
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

#Preview("Popover — two accounts") {
    PopoverView(model: .previewTwoAccounts(), clock: PopoverClock())
}

#Preview("Popover — two accounts, other one expanded") {
    PopoverView(model: .previewTwoAccounts(expanded: true), clock: PopoverClock())
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
