import ClaudeStatsCore
import Foundation
import SwiftUI

/// Bridges the Core data layer into the UI. Holds the last successful
/// readings for local stats/breakdown; the quota snapshot is cleared when
/// its source hard-fails (see `refresh()`) so stale numbers don't read as live.
///
/// The views read these published properties and nothing else — the two
/// protocol-typed dependencies are the seam the real providers plug into.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: QuotaSnapshot?
    /// The other Anthropic accounts this Mac has readings for, newest first —
    /// the user switches the global login between two accounts, and the cache
    /// keeps the previous one's files until they age out.
    ///
    /// Decoration below the active account's rows: never an error source, never
    /// part of the glyph (which shows the account the bars are about), and
    /// empty on a one-account machine. See
    /// ``QuotaProviding/otherAccountSnapshots()``.
    @Published private(set) var otherAccountSnapshots: [QuotaSnapshot] = []
    /// Keys of the ``otherAccountSnapshots`` groups the user has opened in the
    /// popover — `account?.uuid`, or `"unknown"` for the unstamped group.
    ///
    /// Every group starts collapsed, so this is empty until something is
    /// opened. It lives on the model rather than in the view's `@State` so it
    /// survives the popover closing and reopening, exactly like
    /// ``selectedWindow``; it is deliberately not persisted across launches,
    /// since which other accounts exist isn't either.
    @Published var expandedOtherAccounts: Set<String> = []
    @Published private(set) var estimatedCostToday: Double?
    /// Every ``TimeWindow``'s breakdown, all recomputed together by
    /// `reloadBreakdown()`. Precomputed rather than derived on demand because
    /// the summing walks tens of thousands of `UsageEvent`s on the main actor:
    /// doing it when the picker changes stalled the segmented control's own
    /// selection animation for up to a second. The three windows cost one
    /// reload each on the paths where the data can actually change; switching
    /// windows now only picks a different key out of here.
    @Published private(set) var breakdownsByWindow: [TimeWindow: EntrypointBreakdown] = [:]
    /// The breakdown for the currently-selected window, or `nil` before the
    /// first successful reload. Computed, not `@Published` — the views'
    /// `objectWillChange` fires from ``breakdownsByWindow`` and
    /// ``selectedWindow``, which is all SwiftUI needs (same shape as
    /// ``activeErrors``).
    var breakdown: EntrypointBreakdown? { breakdownsByWindow[selectedWindow] }
    @Published private(set) var modelUsage: [ModelUsage] = [] {
        didSet { modelUsageTotal = modelUsage.reduce(TokenUsage.zero) { $0 + $1.usage } }
    }
    /// Every ``modelUsage`` row summed, folded once per reload rather than on
    /// each popover render — the "By model" caption is about the section's
    /// numbers as a whole, and the popover re-renders every clock tick.
    @Published private(set) var modelUsageTotal: TokenUsage = .zero
    @Published private(set) var usingSampleData: Bool

    /// Promo lines Claude Code has cached for its own rate-limit bars, shown
    /// in bar order below the quota bars in the popover.
    ///
    /// Deliberately untouched by every `runQuotaPoll()` failure path: the
    /// notice comes from a different file than the quota reading, so a quota
    /// source that went quiet is no reason to drop it — the empty-state
    /// popover still shows it. It only goes away when a read actually says
    /// there is nothing there.
    @Published private(set) var promoNotices: [RateLimitPromoNotice] = []

    /// Kept independent per subsystem so one reload's success can't clobber
    /// another's still-live failure — see `activeErrors`.
    @Published private(set) var localStatsError: String?
    @Published private(set) var breakdownError: String?
    @Published private(set) var quotaError: String?
    /// Set instead of `quotaError` for `.staleQuotaSource` — the source has a
    /// real (if old) reading, not nothing, so ``snapshot`` is kept (or, on a
    /// cold start, filled in from the rejected reading the error carries) and
    /// this is shown as a warning, not an error. See `runQuotaPoll()`.
    @Published private(set) var quotaWarning: String?
    /// Set by ``clearQuotaCache()`` and shown in place of an error banner while
    /// the cache is deliberately empty — the next reading has to come from
    /// Claude Code's own next statusline render, which is expected to take a
    /// moment. Cleared as soon as any poll comes back with real data (or with a
    /// genuine failure, which is not this state).
    @Published private(set) var quotaCacheClearedNotice: String?

    /// Every still-live failure, not just the highest-priority one — the
    /// popover clears `snapshot` on a quota failure, so a masked `quotaError`
    /// would otherwise leave empty bars with no stated cause.
    var activeErrors: [String] { [localStatsError, breakdownError, quotaError].compactMap { $0 } }

    /// Window selected by the "This Mac" toggle. Purely a choice of which
    /// already-computed ``breakdownsByWindow`` entry to show — it triggers no
    /// reload, so clicking the picker costs nothing but a dictionary lookup.
    @Published var selectedWindow: TimeWindow = .fiveHour

    private let quotaProvider: any QuotaProviding
    private let promoNoticeProvider: any PromoNoticeProviding
    private var usageStore: any UsageStoring
    private var refreshTask: Task<Void, Never>?
    private var lastQuotaPoll: Date?
    private var postInstallPollTask: Task<Void, Never>?
    /// State of the file the last `promoNotices` came from, so an unchanged
    /// file costs one `open` + one `fstat` instead of a 145 KB parse.
    private var lastPromoFingerprint: ClaudeStateFileFingerprint?

    /// Minimum time between live quota polls. Refreshes are triggered by opening
    /// the popover or by new session activity, not by a repeating timer; manual
    /// "Refresh" always bypasses this. User-configurable in Settings.
    @Published private(set) var quotaPollInterval: TimeInterval

    /// Selectable cadences shown in the Settings poll-interval picker.
    static let pollIntervalOptions: [TimeInterval] = [30, 60, 120, 300]
    private static let pollIntervalDefaultsKey = "de.bitgrip.claude-stats.quotaPollInterval"

    /// `promoNoticeProvider` deliberately has no default. Defaulting it to the
    /// real reader would make every test read the developer's own
    /// `~/.claude.json`, which the suite's stated rule forbids; defaulting it
    /// to a no-op would let `ClaudeStatsApp` forget the wiring with nothing
    /// failing to catch it.
    init(
        quotaProvider: any QuotaProviding,
        usageStore: any UsageStoring,
        promoNoticeProvider: any PromoNoticeProviding,
        usingSampleData: Bool = false
    ) {
        self.quotaProvider = quotaProvider
        self.usageStore = usageStore
        self.promoNoticeProvider = promoNoticeProvider
        self.usingSampleData = usingSampleData

        let stored = UserDefaults.standard.double(forKey: Self.pollIntervalDefaultsKey)
        self.quotaPollInterval = Self.pollIntervalOptions.contains(stored) ? stored : 60
    }

    /// Persists the new cadence immediately so it survives the next launch.
    func setQuotaPollInterval(_ interval: TimeInterval) {
        quotaPollInterval = interval
        UserDefaults.standard.set(interval, forKey: Self.pollIntervalDefaultsKey)
    }

    /// Swaps in a freshly-rebuilt store (the FSEvents-triggered refresh path)
    /// without replacing the `AppModel` instance the views are bound to, and
    /// reloads the published local-stats/breakdown state from it immediately.
    func updateUsageStore(_ newStore: any UsageStoring) {
        usageStore = newStore
        reloadLocalStats()
        reloadBreakdown()
    }

    /// Reload everything. The quota network poll is throttled to
    /// `quotaPollInterval` unless `force` is set (manual "Refresh"). Returns
    /// the spawned quota-poll task (`nil` if throttled) so callers that need
    /// to know when it lands — e.g. ``pollAfterInstall()`` — can await it.
    ///
    /// `reloadLocalData` skips `reloadLocalStats()`/`reloadBreakdown()` for the
    /// one caller (`ClaudeStatsApp.rebuildUsageStore`) that just ran them via
    /// `updateUsageStore(_:)` moments earlier — those walk every `UsageEvent`
    /// for all three windows, so redoing them here would pay that cost twice
    /// on every FSEvents batch.
    @discardableResult
    func refresh(force: Bool = false, reloadLocalData: Bool = true) -> Task<Void, Never>? {
        if reloadLocalData {
            reloadLocalStats()
            reloadBreakdown()
        }

        let shouldPollQuota = force || shouldRunUpdateCheck(lastCheck: lastQuotaPoll, now: Date(), interval: quotaPollInterval)
        guard shouldPollQuota else { return nil }
        lastQuotaPoll = Date()

        // Behind the same throttle as the quota poll (≥30s, ≤300s) so
        // filesystem churn can't cause a read per write, and inside it so a
        // manual "Refresh" always re-reads. Synchronous on `@MainActor` is
        // fine — see `PromoNoticeProviding`.
        reloadPromoNotices()

        refreshTask?.cancel()
        refreshTask = runQuotaPoll()
        return refreshTask
    }

    /// Shared body of a live quota poll. Every path that polls goes through
    /// here — `refresh()` directly, and `pollAfterInstall()` /
    /// `clearQuotaCache()` through `refresh(force:)` — so none of them can
    /// drift out of sync on how a poll result is applied.
    ///
    /// While `quotaCacheClearedNotice` is set, a `noQuotaSourceAvailable`
    /// result is the expected outcome rather than a failure — the cache was
    /// deliberately emptied and nothing has written a fresh one yet — so it's
    /// suppressed instead of shown as an error. That check is on the notice
    /// itself, not on which caller started the poll, so any poll landing in
    /// that window (a retry from ``clearQuotaCache()``, or a plain
    /// ``refresh()``) leaves the notice in place rather than clobbering it
    /// with a red error banner for the same expected condition.
    private func runQuotaPoll() -> Task<Void, Never> {
        Task { [quotaProvider] in
            // Read and applied before the snapshot rather than per outcome:
            // these rows come from other accounts' cache files, so whether
            // *this* account's reading succeeds, goes stale or fails says
            // nothing about them. The call can't throw — see
            // `QuotaProviding.otherAccountSnapshots()`.
            //
            // Both reads hit disk, so a poll already superseded by a newer one
            // bails before paying for either rather than after both have run.
            guard !Task.isCancelled else { return }
            let otherAccounts = await quotaProvider.otherAccountSnapshots()
            guard !Task.isCancelled else { return }
            self.otherAccountSnapshots = otherAccounts
            // The per-branch guards below stay: `currentSnapshot()` is the
            // longest await here, and a poll cancelled during it must not
            // clobber `snapshot`/`quotaError` with a superseded result.
            do {
                let snapshot = try await quotaProvider.currentSnapshot()
                guard !Task.isCancelled else { return }
                self.snapshot = snapshot
                self.quotaError = nil
                self.quotaWarning = nil
                self.quotaCacheClearedNotice = nil
            } catch let error as ClaudeStatsError where error.isStaleQuotaSource {
                guard !Task.isCancelled else { return }
                // The source has a real reading, just an old one — surface this
                // as a warning, not an error. A stale-but-present reading also
                // means the "wait for a fresh render" notice no longer
                // describes the state.
                //
                // Normally `snapshot` is left exactly as-is: it holds the last
                // reading that *was* fresh when it landed, which beats the
                // older one this error carries, and the popover's own staleness
                // check already marks it.
                //
                // But when there is no such reading — a cold start where the
                // source was already stale on the very first poll, or after
                // `clearQuotaCache()` emptied it — leaving it `nil` means empty
                // bars forever alongside the warning, even though the reader
                // had real numbers in hand. Fall back to the rejected reading
                // the error carries: a stale number beats no number, the same
                // principle `FreshestQuotaProvider` already applies internally.
                self.quotaWarning = error.localizedDescription
                if case .staleQuotaSource(let snapshot, _) = error,
                   self.snapshot == nil || self.snapshot!.capturedAt < snapshot.capturedAt {
                    self.snapshot = snapshot
                }
                self.quotaError = nil
                self.quotaCacheClearedNotice = nil
            } catch ClaudeStatsError.noQuotaSourceAvailable where self.quotaCacheClearedNotice != nil {
                guard !Task.isCancelled else { return }
                // The expected outcome right after a clear: nothing has written a
                // fresh cache yet. `quotaCacheClearedNotice` already says so, so
                // no error banner — that would read as a fault the user has to
                // fix rather than a state that resolves itself. Left set.
                self.quotaError = nil
                self.quotaWarning = nil
            } catch {
                guard !Task.isCancelled else { return }
                // Replaces the last snapshot rather than leaving it on screen:
                // once the source has genuinely failed (not just a throttled
                // skip — this closure only runs when a poll was attempted),
                // frozen old numbers with no visual change read as live. Any
                // pending "cache cleared" notice no longer applies either —
                // this is a real, different failure.
                self.snapshot = nil
                self.quotaError = error.localizedDescription
                self.quotaWarning = nil
                self.quotaCacheClearedNotice = nil
            }
        }
    }

    /// Deletes the statusline cache and re-polls until a fresh reading lands.
    ///
    /// The escape hatch for a number that looks stuck or wrong. Per-session
    /// cache files stop one quiet session from overwriting a busy one, but they
    /// can't help when every file on disk is wrong. Plain "Refresh" can't help
    /// there either: it re-reads the very files that hold the bad value.
    ///
    /// Only the statusline cache goes: `~/.claude.json` is Claude Code's own
    /// live state file (see `CachedUtilizationReader.clearCache()`), so the
    /// repoll below usually lands on that source's reading rather than on
    /// nothing.
    ///
    /// The repoll goes through ``pollAfterInstall()`` rather than a single
    /// poll: a just-deleted cache is the same "file doesn't exist yet" state as
    /// a just-installed hook, so it needs the same retry ladder. A slow next
    /// statusline render then resolves within ~15s instead of leaving the
    /// notice up for a full `quotaPollInterval` (up to 5 minutes) before
    /// anything tries again.
    ///
    /// ``snapshot`` is dropped right away rather than at the end of the poll:
    /// the whole point of the button is that the number on screen is suspect,
    /// so it goes immediately rather than lingering until a replacement lands.
    ///
    /// If the delete itself fails, none of the above happens: the existing
    /// snapshot/notice state is left untouched and the failure is surfaced via
    /// ``quotaError`` instead.
    func clearQuotaCache() {
        do {
            try quotaProvider.clearCache()
        } catch {
            // The delete itself failed — nothing was actually cleared, so don't
            // show the "cleared" notice or start a repoll; surface the real
            // failure instead.
            quotaError = error.localizedDescription
            reloadLocalStats()
            reloadBreakdown()
            return
        }

        // The other accounts' rows come from the same files this just deleted,
        // so they go with the active account's reading rather than lingering as
        // the only numbers on screen.
        snapshot = nil
        otherAccountSnapshots = []
        quotaError = nil
        quotaWarning = nil
        quotaCacheClearedNotice = "Statusline cache cleared — the bars fall back to Claude Code's own cached reading until the next statusline render."

        reloadLocalStats()
        reloadBreakdown()

        refreshTask?.cancel()
        pollAfterInstall()
    }

    /// Right after installing the hook — or after ``clearQuotaCache()`` — the
    /// statusline cache file doesn't exist yet, so an immediate poll can only
    /// win from Claude Code's own cached reading, if any. Retry a few times
    /// over ~15s instead of waiting for the next popover open: catches the
    /// common case of Claude Code already running in a terminal and firing
    /// the hook almost immediately.
    func pollAfterInstall() {
        postInstallPollTask?.cancel()
        postInstallPollTask = Task { [weak self] in
            for delay in [2.0, 4.0, 8.0] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                await self.refresh(force: true)?.value
                // Not just "a snapshot landed": `FreshestQuotaProvider` will
                // serve Claude Code's own cached blob on the first tick, which
                // says nothing about whether the hook this ladder is waiting
                // on has rendered yet. Keep retrying until the statusline
                // source wins the freshness comparison.
                if self.quotaError == nil, self.snapshot?.confidence == .official { return }
            }
        }
    }

    /// The quota block's own section title — the counterpart of the literal
    /// "This Mac" and "By model" titles next to it.
    ///
    /// Names the account the bars underneath describe, so the block announces
    /// itself the way the other two sections do. Two rules decide the wording:
    ///
    /// - **The account's name, or the literal "Quota".** An unstamped reading
    ///   (or no reading at all) must not be labelled with a guessed account, so
    ///   the section falls back to naming itself rather than naming nobody.
    /// - **The `Active:` prefix only exists when there is something to be
    ///   active *against*** — i.e. when ``otherAccountSnapshots`` is non-empty
    ///   and "Inactive:" groups follow. On the one-account machine, which is
    ///   every machine until the user switches logins, the prefix would
    ///   contrast with nothing and the bare name reads better.
    ///
    /// Lives here rather than in the view so all four combinations are
    /// testable.
    var quotaSectionTitle: String {
        let name = snapshot?.account?.displayName
        guard !otherAccountSnapshots.isEmpty else { return name ?? "Quota" }
        return "Active: \(name ?? "Unknown account")"
    }

    /// What the popover calls one of the *other* accounts' disclosure groups.
    ///
    /// Prefixed "Inactive:" against ``quotaSectionTitle``'s "Active:", so a
    /// collapsed row says what it is without a number: these readings belong to
    /// a login nobody is currently signed in as.
    ///
    /// An unstamped reading is genuinely "we don't know whose this is" — a
    /// cache file written before the hook script learned to stamp one — so it
    /// says so rather than leaving a blank label or borrowing a name from the
    /// account next to it. Lives here rather than in the view so both branches
    /// are testable.
    func otherAccountTitle(for snapshot: QuotaSnapshot) -> String {
        "Inactive: \(snapshot.account?.displayName ?? "Unknown account")"
    }

    /// Stable key for one other-account group's expansion state.
    ///
    /// The uuid, or the one `"unknown"` bucket the unstamped group forms — the
    /// same grouping the readings themselves use, so a group keeps its open or
    /// closed state across a refresh that rebuilds the snapshots.
    static func otherAccountKey(for snapshot: QuotaSnapshot) -> String {
        snapshot.account?.uuid ?? "unknown"
    }

    /// Two-way binding onto ``expandedOtherAccounts`` for one group's
    /// `DisclosureGroup`.
    ///
    /// A `Set` of open keys rather than a `Bool` per row because the rows are
    /// rebuilt from the snapshots on every refresh: anything stored per view
    /// would collapse the group the moment a poll lands.
    func otherAccountExpansionBinding(for snapshot: QuotaSnapshot) -> Binding<Bool> {
        let key = Self.otherAccountKey(for: snapshot)
        return Binding(
            get: { [weak self] in self?.expandedOtherAccounts.contains(key) ?? false },
            set: { [weak self] isExpanded in
                guard let self else { return }
                if isExpanded {
                    self.expandedOtherAccounts.insert(key)
                } else {
                    self.expandedOtherAccounts.remove(key)
                }
            }
        )
    }

    /// The promo notice for one bar, or `nil` when there is none.
    ///
    /// First match wins if a (malformed) payload ever carries two entries for
    /// the same bar — each bar contributes one line to the popover, and picking
    /// the first keeps that deterministic.
    func promoNotice(for bar: QuotaWindowKind) -> RateLimitPromoNotice? {
        promoNotices.first { $0.bar == bar }
    }

    /// Never sets an error: a promo notice is decoration, and there is no
    /// action a user could take about its absence. See ``PromoNoticeProviding``.
    private func reloadPromoNotices() {
        switch promoNoticeProvider.read(unchangedSince: lastPromoFingerprint) {
        case .unchanged:
            break
        case .read(let notices, let fingerprint):
            promoNotices = notices
            lastPromoFingerprint = fingerprint
        }
    }

    private func reloadLocalStats() {
        do {
            estimatedCostToday = try usageStore.estimatedCostToday()
            modelUsage = try usageStore.modelUsage(last24h: true)
            localStatsError = nil
        } catch {
            localStatsError = error.localizedDescription
        }
    }

    /// Recomputes all three windows at once, not just ``selectedWindow`` — see
    /// ``breakdownsByWindow``. Called from every path where the underlying
    /// events can have changed (`refresh()`, `updateUsageStore(_:)`,
    /// `clearQuotaCache()`); no new cadence of its own.
    ///
    /// Delegates to ``UsageStoring/entrypointBreakdowns(for:)`` rather than
    /// looping ``UsageStoring/entrypointBreakdown(for:)`` per window —
    /// `LocalLogUsageStore` sums all three in one walk of the widest window's
    /// events instead of three separate walks, so this no longer pays for the
    /// 7-day slice three times over on every reload.
    ///
    /// Assigned in one shot at the end so a window that throws part-way through
    /// never leaves a half-updated cache mixing two reloads' numbers. Defensive:
    /// no shipping `UsageStoring` throws from `entrypointBreakdown(for:)` today —
    /// `throws` there is protocol conformance — so in practice this is
    /// all-or-nothing per reload either way.
    private func reloadBreakdown() {
        do {
            breakdownsByWindow = try usageStore.entrypointBreakdowns(for: TimeWindow.allCases)
            breakdownError = nil
        } catch {
            breakdownError = error.localizedDescription
        }
    }

    func openSettings() {
        SettingsWindowController.show(model: self)
    }
}

#if DEBUG
extension AppModel {
    /// Fully-populated model for SwiftUI previews.
    ///
    /// Lives in this file because the published properties are `private(set)`, so
    /// only same-file code can seed them synchronously — previews would otherwise
    /// render one frame of empty state before the async quota read lands.
    static func preview(
        window: TimeWindow = .fiveHour,
        snapshot: QuotaSnapshot? = MockQuotaProvider.sampleSnapshot(),
        error: String? = nil,
        warning: String? = nil,
        promoNotices: [RateLimitPromoNotice] = [],
        otherAccounts: [QuotaSnapshot] = []
    ) -> AppModel {
        let store = MockUsageStore()
        // Inlined here (not a public Core factory) so a preview-only "no
        // data yet" fixture can't be mistaken for or reused as a real
        // placeholder elsewhere. `confidence` has no non-official case to
        // express "not real data" — this fixture is never rendered as-is;
        // it only backstops the mock provider when `snapshot` is nil. Both
        // windows are `nil`, which is the honest shape of "nothing reported
        // anything": the rows read as no reading, not as 0%.
        let previewPlaceholder = QuotaSnapshot(
            fiveHour: nil,
            sevenDay: nil,
            confidence: .official,
            capturedAt: Date()
        )
        let model = AppModel(
            quotaProvider: MockQuotaProvider(
                snapshot: snapshot ?? previewPlaceholder,
                otherAccounts: otherAccounts
            ),
            usageStore: store,
            promoNoticeProvider: MockPromoNoticeProvider(notices: promoNotices)
        )
        model.selectedWindow = window
        // Selecting a window no longer loads anything, so the breakdowns have
        // to be filled in explicitly — one reload covers all three windows.
        model.reloadBreakdown()
        model.snapshot = snapshot
        model.otherAccountSnapshots = otherAccounts
        model.promoNotices = promoNotices
        model.estimatedCostToday = try? store.estimatedCostToday()
        model.modelUsage = (try? store.modelUsage(last24h: true)) ?? []
        model.quotaError = error
        model.quotaWarning = warning
        return model
    }

    /// Cold-start state: nothing has been read yet.
    static func previewEmpty() -> AppModel {
        AppModel(
            quotaProvider: MockQuotaProvider(),
            usageStore: MockUsageStore(),
            promoNoticeProvider: MockPromoNoticeProvider(notices: [])
        )
    }

    /// The promo banner with a live snapshot behind it.
    static func previewPromoNotice() -> AppModel {
        preview(promoNotices: [MockPromoNoticeProvider.sampleNotice()])
    }

    /// The promo banner with no quota source at all — it comes from a
    /// different file, so it survives an empty-state popover.
    static func previewPromoNoticeWithoutQuota() -> AppModel {
        preview(
            snapshot: nil,
            error: ClaudeStatsError.noQuotaSourceAvailable.localizedDescription,
            promoNotices: [MockPromoNoticeProvider.sampleNotice()]
        )
    }

    /// With organisation usage credits reported — the hatched fourth row.
    static func previewUsageCredits(
        credits: UsageCredits = MockQuotaProvider.sampleUsageCredits()
    ) -> AppModel {
        preview(snapshot: MockQuotaProvider.sampleSnapshotWithUsageCredits(credits: credits))
    }

    /// Everything the popover can draw at once: both fixed windows, the promo
    /// notice, the scoped weekly row and a part-spent usage-credits bar.
    ///
    /// The single source of truth for the README asset renderer
    /// (`Tests/ClaudeStatsTests/ReadmeAssetRenderTests.swift`), so the shipped
    /// screenshot and the Xcode canvas can never drift apart — the preview
    /// below renders the same call the renderer does.
    ///
    /// - Parameter now: pinned by the renderer so every time-derived string
    ///   ("resets in …", "… ago") is byte-stable across runs; defaults to
    ///   `Date()` for the canvas, which wants a live-looking clock.
    static func previewShowcase(now: Date = Date()) -> AppModel {
        preview(
            snapshot: MockQuotaProvider.sampleShowcaseSnapshot(now: now),
            promoNotices: [MockPromoNoticeProvider.sampleNotice()]
        )
    }

    /// Two accounts: the one Claude Code is logged in as now, labelled, with
    /// the account the user switched away from collapsed under it.
    ///
    /// - Parameter expanded: opens the other account's disclosure, which is
    ///   closed in the shipping default — the canvas needs a way to see the
    ///   rows inside it without clicking.
    static func previewTwoAccounts(now: Date = Date(), expanded: Bool = false) -> AppModel {
        var active = MockQuotaProvider.sampleSnapshot(now: now)
        active.account = MockQuotaProvider.sampleAccount()
        let other = MockQuotaProvider.sampleOtherAccountSnapshot(now: now)
        let model = preview(snapshot: active, otherAccounts: [other])
        if expanded {
            model.expandedOtherAccounts = [otherAccountKey(for: other)]
        }
        return model
    }

    /// Live source, but stale — quota still shown, plus a warning line.
    static func previewStaleWarning() -> AppModel {
        preview(warning: "Statusline cache is 14 minutes old.")
    }

    /// Straight after "Clear Quota Cache": no snapshot, no error — just the
    /// notice explaining what the popover is waiting for.
    static func previewCacheCleared() -> AppModel {
        let model = preview(snapshot: nil)
        model.quotaCacheClearedNotice =
            "Statusline cache cleared — the bars fall back to Claude Code's own cached reading until the next statusline render."
        return model
    }

    /// Worst case: a stale snapshot, a window over budget, and a quota
    /// staleness warning to surface.
    static func previewDegraded() -> AppModel {
        let now = Date()
        let snapshot = QuotaSnapshot(
            fiveHour: QuotaWindow(percentUsed: 104, resetsAt: now.addingTimeInterval(90)),
            sevenDay: QuotaWindow(percentUsed: 88, resetsAt: nil),
            confidence: .official,
            capturedAt: now.addingTimeInterval(-42 * 60)
        )
        let model = preview(window: .sevenDay, snapshot: snapshot)
        model.quotaWarning = ClaudeStatsError
            .staleQuotaSource(snapshot: snapshot, age: 42 * 60)
            .localizedDescription
        return model
    }
}
#endif
