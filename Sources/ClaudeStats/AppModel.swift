import ClaudeStatsCore
import Foundation
import SwiftUI

/// Which window the popover's two tables read **at rest** — the Settings
/// preference behind ``AppModel/defaultDisplayRange``.
///
/// The choice is about the numbers, not about the plot: both charts keep
/// drawing the whole window either way, because a single day is one point with
/// no shape to read and the hover rule would have nothing left to move over.
/// What the setting changes is which reading the tables open on — the window's
/// sum, or the newest day in it, which is the figure someone checking "what
/// have I spent today" comes for and which used to be reachable only by
/// hovering the right edge of a 250 pt plot.
///
/// Hovering still wins wherever it lands, so the "latest day" setting is a
/// different *default*, not a second mode with its own rules.
enum DefaultDisplayRange: String, CaseIterable, Identifiable {
    /// The whole charted window summed — how the popover has always opened.
    case last30Days
    /// The newest day the charts plot, i.e. today once anything has been
    /// logged. Resolved by position, never as a stored date, so midnight
    /// sliding the window moves it along.
    case latestDay

    var id: String { rawValue }

    /// What the Settings picker calls it. The 30 is spelled from
    /// ``AppModel/chartWindowDays`` rather than typed, so shortening the
    /// window can't leave the label claiming a month.
    var label: String {
        switch self {
        case .last30Days: return "Last \(AppModel.chartWindowDays) days"
        case .latestDay: return "Latest day"
        }
    }
}

/// The popover's daily history read out of one usage store, together with the
/// local day it was read on — the unit ``AppModel`` caches and the rebuild
/// queue hands over.
///
/// A value rather than a call so it can be computed off the main actor:
/// ``UsageStoring/dailyUsage(days:)`` walks every retained event plus the
/// folded day cells — about 11 ms against a real 14k-file corpus — and
/// `ClaudeStatsApp.rebuildUsageStore` used to pay that on the main actor for
/// every FSEvents rebuild. It now builds one of these on the rebuild queue,
/// next to the store it describes, and ``AppModel/updateUsageStore(_:localStats:)``
/// only assigns it.
struct LocalStatsLoad: Sendable {
    enum Outcome: Sendable, Equatable {
        case history(DailyUsageHistory)
        /// The store threw; carries its `localizedDescription`, which is all
        /// ``AppModel/localStatsError`` ever shows.
        case failure(String)
    }

    /// Local start of the day the history was read on. A history is only
    /// valid for that day: its window ends with "today", so after midnight the
    /// same store gives a different answer.
    let day: Date
    let outcome: Outcome

    /// Reads ``AppModel/chartWindowDays`` of history out of `store`. Safe on
    /// any thread — every ``UsageStoring`` is `Sendable` and the real one is
    /// immutable arithmetic over data already in memory.
    ///
    /// `day` is taken *before* the read, so a read that straddles midnight is
    /// labelled with the earlier day and simply reloaded on the next check —
    /// never kept a day longer than it is right.
    static func load(
        from store: any UsageStoring,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> LocalStatsLoad {
        let day = calendar.startOfDay(for: now)
        do {
            return LocalStatsLoad(day: day, outcome: .history(try store.dailyUsage(days: AppModel.chartWindowDays)))
        } catch {
            return LocalStatsLoad(day: day, outcome: .failure(error.localizedDescription))
        }
    }
}

/// Bridges the Core data layer into the UI. Holds the last successful
/// readings for local stats/breakdown; the quota snapshot is cleared when
/// its source hard-fails (see `refresh()`) so stale numbers don't read as live.
///
/// The views read these published properties and nothing else — the two
/// protocol-typed dependencies are the seam the real providers plug into.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: QuotaSnapshot?
    /// Daily history behind both popover blocks — "By source" stacks its
    /// per-source token split, "By model" stacks the estimated spend of its
    /// per-family one — covering ``chartWindowDays``.
    ///
    /// The single local reading the popover has, since the two blocks replaced
    /// the five-hour legend, the fixed-24h model rows and the `Today` spend
    /// figure: one window, one hover rule, one query. Empty until the first
    /// reload, and on a Mac with no local history at all — the sections draw an
    /// empty state rather than a flat line through zero.
    @Published private(set) var dailyHistory: DailyUsageHistory = .empty
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
    @Published private(set) var quotaError: String?
    /// Set instead of `quotaError` for `.staleQuotaSource` — the source has a
    /// real (if old) reading, not nothing, so ``snapshot`` is kept (or, on a
    /// cold start, filled in from the rejected reading the error carries) and
    /// this is shown as a warning, not an error. See `runQuotaPoll()`.
    @Published private(set) var quotaWarning: String?
    /// Set by ``clearQuotaCache()`` — or by the automatic clear after an account
    /// switch, in its own wording (see ``QuotaCacheClear``) — and shown in place
    /// of an error banner while the cache is deliberately empty: the next
    /// reading has to come from Claude Code's own next statusline render, which
    /// is expected to take a moment. Cleared as soon as any poll comes back with
    /// real data (or with a genuine failure, which is not this state).
    @Published private(set) var quotaCacheClearedNotice: String?

    /// Every still-live failure, not just the highest-priority one — the
    /// popover clears `snapshot` on a quota failure, so a masked `quotaError`
    /// would otherwise leave empty bars with no stated cause.
    var activeErrors: [String] { [localStatsError, quotaError].compactMap { $0 } }

    private let quotaProvider: any QuotaProviding
    private let promoNoticeProvider: any PromoNoticeProviding
    private var usageStore: any UsageStoring
    /// The day ``dailyHistory`` was read on, out of the current
    /// ``usageStore`` — `nil` when it has to be read (again): nothing loaded
    /// yet, the store was swapped, or the last read failed. See
    /// ``reloadLocalStats()``.
    private var dailyHistoryDay: Date?
    /// Clock and calendar behind the "is ``dailyHistory`` still today's"
    /// check, injected so a test can cross midnight.
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private var refreshTask: Task<Void, Never>?
    private var lastQuotaPoll: Date?
    private var postInstallPollTask: Task<Void, Never>?
    /// State of the file the last `promoNotices` came from, so an unchanged
    /// file costs one `open` + one `fstat` instead of a 145 KB parse.
    private var lastPromoFingerprint: ClaudeStateFileFingerprint?
    /// The uuid of the last account a poll saw logged in, for spotting a login
    /// switch — see ``noteActiveAccount(_:)``.
    ///
    /// In memory only, deliberately: the first poll after a launch has nothing
    /// to compare against and clears nothing. A switch made while the app
    /// wasn't running is left to per-account grouping and the mislabel guard,
    /// which keep the other login's files off the bars anyway — the automatic
    /// clear is a tidy-up on top of them, not what makes the bars correct.
    /// Holds the last *known* uuid — a poll that can't tell who is logged in
    /// leaves it alone rather than resetting it.
    private var lastKnownAccountUuid: String?

    /// Minimum time between live quota polls, and also the cadence of the
    /// background timer started by ``startBackgroundPolling()``. Refreshes
    /// are triggered by opening the popover, by new session activity, or by
    /// that timer; manual "Refresh" always bypasses the throttle.
    /// User-configurable in Settings.
    @Published private(set) var quotaPollInterval: TimeInterval

    /// Ticks ``refresh()`` at ``quotaPollInterval`` so the menu-bar glyph
    /// doesn't sit on a stale reading for as long as the app runs quietly —
    /// without this, ``snapshot`` (and the glyph `StatusItemController` draws
    /// from it) only updates on a popover open or new session activity, which
    /// can be arbitrarily far apart. `nil` until ``startBackgroundPolling()``
    /// runs; internal rather than `private` so a test can read and `fire()`
    /// it without waiting on wall-clock time.
    private(set) var backgroundPollTimer: Timer?

    /// Selectable cadences shown in the Settings poll-interval picker.
    static let pollIntervalOptions: [TimeInterval] = [30, 60, 120, 300]
    private static let pollIntervalDefaultsKey = "de.bitgrip.claude-stats.quotaPollInterval"

    /// Which window the popover's tables show at rest — see
    /// ``DefaultDisplayRange``. Persisted like the poll interval, and read on
    /// every render rather than baked into the tables, so changing it in
    /// Settings takes effect on the open popover.
    @Published private(set) var defaultDisplayRange: DefaultDisplayRange
    private static let defaultDisplayRangeDefaultsKey = "de.bitgrip.claude-stats.defaultDisplayRange"

    /// Where both preferences are read and written. Injected so a test can
    /// exercise persistence in its own suite instead of writing into whatever
    /// domain the process happens to have.
    private let defaults: UserDefaults

    /// `promoNoticeProvider` deliberately has no default. Defaulting it to the
    /// real reader would make every test read the developer's own
    /// `~/.claude.json`, which the suite's stated rule forbids; defaulting it
    /// to a no-op would let `ClaudeStatsApp` forget the wiring with nothing
    /// failing to catch it.
    init(
        quotaProvider: any QuotaProviding,
        usageStore: any UsageStoring,
        promoNoticeProvider: any PromoNoticeProviding,
        usingSampleData: Bool = false,
        defaults: UserDefaults = .standard,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.quotaProvider = quotaProvider
        self.usageStore = usageStore
        self.promoNoticeProvider = promoNoticeProvider
        self.usingSampleData = usingSampleData
        self.defaults = defaults
        self.calendar = calendar
        self.now = now

        let stored = defaults.double(forKey: Self.pollIntervalDefaultsKey)
        self.quotaPollInterval = Self.pollIntervalOptions.contains(stored) ? stored : 60

        // Anything unrecognised — an absent key, or a value written by a
        // version that spelled the cases differently — falls back to the
        // thirty-day window the popover has always opened on.
        self.defaultDisplayRange = defaults.string(forKey: Self.defaultDisplayRangeDefaultsKey)
            .flatMap(DefaultDisplayRange.init(rawValue:)) ?? .last30Days
    }

    /// Persists the new cadence immediately so it survives the next launch,
    /// and restarts the background poll timer at the new interval if it's
    /// running — `Timer`'s own interval is fixed at creation, so a cadence
    /// picked in Settings only takes effect once the timer is rebuilt.
    func setQuotaPollInterval(_ interval: TimeInterval) {
        quotaPollInterval = interval
        defaults.set(interval, forKey: Self.pollIntervalDefaultsKey)
        if backgroundPollTimer != nil {
            scheduleBackgroundPollTimer()
        }
    }

    /// Starts the background poll timer described on ``backgroundPollTimer``.
    /// Call once, after the launch poll — `ClaudeStatsApp` is the only caller.
    func startBackgroundPolling() {
        scheduleBackgroundPollTimer()
    }

    private func scheduleBackgroundPollTimer() {
        backgroundPollTimer?.invalidate()
        let timer = Timer(timeInterval: quotaPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.refresh()
            }
        }
        // `.common` so it keeps ticking while a menu or the popover's own
        // event tracking is running — see `PopoverClock` for the same reasoning.
        RunLoop.main.add(timer, forMode: .common)
        backgroundPollTimer = timer
    }

    deinit {
        backgroundPollTimer?.invalidate()
    }

    /// Persists the new resting window immediately, the way the cadence is —
    /// there is no Apply button in this Settings pane.
    func setDefaultDisplayRange(_ range: DefaultDisplayRange) {
        defaultDisplayRange = range
        defaults.set(range.rawValue, forKey: Self.defaultDisplayRangeDefaultsKey)
    }

    /// Swaps in a freshly-rebuilt store (the FSEvents-triggered refresh path)
    /// without replacing the `AppModel` instance the views are bound to, and
    /// publishes its daily history immediately.
    ///
    /// `localStats` is that history already read — by
    /// `ClaudeStatsApp.rebuildUsageStore`, on the rebuild queue — so the main
    /// actor only assigns it. Without one it is read here. A successful load
    /// is also checked against today afterwards, so one computed just before
    /// midnight and delivered just after is read again rather than kept; a
    /// failed load is not retried immediately, since the store hasn't changed.
    func updateUsageStore(_ newStore: any UsageStoring, localStats: LocalStatsLoad? = nil) {
        usageStore = newStore
        dailyHistoryDay = nil
        guard let localStats else {
            reloadLocalStats()
            return
        }
        apply(localStats)
        // Only a successful load can be stale-dated (computed just before
        // midnight); a failure isn't worth immediately retrying against the
        // same, unchanged store — the next natural reload will retry it.
        if case .history = localStats.outcome {
            reloadLocalStats()
        }
    }

    /// Reload everything. The quota network poll is throttled to
    /// `quotaPollInterval` unless `force` is set (manual "Refresh"). Returns
    /// the spawned quota-poll task (`nil` if throttled) so callers that need
    /// to know when it lands — e.g. ``pollAfterInstall()`` — can await it.
    ///
    /// The local half is free unless something changed: ``reloadLocalStats()``
    /// only reads the store when it has a new one or the day has rolled over,
    /// so neither a popover open, the rebuild path's refresh right after
    /// ``updateUsageStore(_:localStats:)``, nor a retry-ladder rung pays for
    /// the corpus walk again. `force` does not bypass that: the store is
    /// in-memory, and reading it twice can only give the same answer.
    @discardableResult
    func refresh(force: Bool = false) -> Task<Void, Never>? {
        reloadLocalStats()

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
    ///
    /// Every poll first asks who is logged in
    /// (``QuotaProviding/currentAccount()``), before and independently of the
    /// snapshot, so a switch is seen even on a poll whose read would throw —
    /// the usual outcome right after one. When ``noteActiveAccount(_:)``
    /// reports a switch, this poll hands over to the shared clear path instead
    /// of reading a snapshot the clear would drop straight away; the retry
    /// ladder that path starts does the reading.
    ///
    /// That hand-over can't loop or cut itself off. The remembered uuid is
    /// updated before the clear runs, so the ladder's own polls see the same
    /// account and pass straight through. The clear cancels `refreshTask` —
    /// this very poll — but only after its last suspension point, and the poll
    /// returns immediately after. And a poll that was cancelled while it was
    /// asking bails before touching the remembered uuid, so a superseded answer
    /// can never be recorded over a newer one.
    private func runQuotaPoll() -> Task<Void, Never> {
        Task { [quotaProvider] in
            // The read hits disk, so a poll already superseded by a newer one
            // bails before paying for it.
            guard !Task.isCancelled else { return }
            let account = await quotaProvider.currentAccount()
            // Nothing between this guard and the clear suspends, so no newer
            // poll can start in between and be cancelled by it.
            guard !Task.isCancelled else { return }
            if let account, self.noteActiveAccount(account) {
                self.performQuotaCacheClear(.accountSwitch(account))
                return
            }
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
    ///
    /// The same body also runs on its own, without the button, once a poll
    /// notices Claude Code's login has switched to a different account — see
    /// ``noteActiveAccount(_:)``. Only the notice's wording differs (see
    /// ``QuotaCacheClear``); both go through ``performQuotaCacheClear(_:)`` so
    /// the two can't drift apart.
    func clearQuotaCache() {
        performQuotaCacheClear(.manual)
    }

    /// Why the statusline cache is being cleared — which decides the notice
    /// shown while the bars wait for a fresh render, and nothing else.
    enum QuotaCacheClear: Equatable {
        /// The "Clear Quota Cache" button.
        case manual
        /// A poll saw Claude Code logged in as a different account than the
        /// one before; carries the new one, to name it.
        case accountSwitch(QuotaAccount)

        static let manualNotice =
            "Statusline cache cleared — the bars fall back to Claude Code's own cached reading until the next statusline render."

        /// Names the new account rather than restating the manual text: the
        /// user didn't press anything, so "cache cleared" on its own would read
        /// as something the app did unprompted, for no stated reason.
        static func accountSwitchNotice(for account: QuotaAccount) -> String {
            "Account switched to \(account.displayName) — statusline cache cleared, waiting for its first statusline render."
        }

        var notice: String {
            switch self {
            case .manual: return Self.manualNotice
            case .accountSwitch(let account): return Self.accountSwitchNotice(for: account)
            }
        }
    }

    /// Shared body of ``clearQuotaCache()`` and the automatic clear after an
    /// account switch — see the former for what each step is for.
    private func performQuotaCacheClear(_ reason: QuotaCacheClear) {
        do {
            try quotaProvider.clearCache()
        } catch {
            // The delete itself failed — nothing was actually cleared, so don't
            // show the "cleared" notice or start a repoll; surface the real
            // failure instead. For an automatic clear the switch still counts
            // as handled (the uuid was already recorded): retrying the delete
            // on every poll would pin this error over the bars for as long as
            // the fault lasts, while per-account grouping keeps the old
            // login's files off them regardless.
            quotaError = error.localizedDescription
            reloadLocalStats()
            return
        }

        snapshot = nil
        quotaError = nil
        quotaWarning = nil
        quotaCacheClearedNotice = reason.notice

        reloadLocalStats()

        refreshTask?.cancel()
        pollAfterInstall()
    }

    /// Records the account a poll just saw and says whether it is a switch
    /// worth clearing the cache for: `true` only for a known account followed
    /// by a *different* known account.
    ///
    /// - The first account seen after launch is recorded, never a switch —
    ///   there is nothing to compare it with.
    /// - Unknown (no state file, a half-written one, no `oauthAccount`) never
    ///   reaches here and never overwrites the record. So known → unknown
    ///   clears nothing, and unknown → known clears nothing *unless* the
    ///   account that comes back differs from the last known one: A → unknown
    ///   → B is a switch, because the state file blinking out mid-swap is
    ///   exactly how a login change can look to a poll.
    /// - The same uuid again is not a switch, which is also what stops the
    ///   clear's own retry ladder from triggering another clear.
    ///
    /// Detection waits for the next quota poll: the state file lives in
    /// `$HOME`, which isn't watched, and polls are triggered by opening the
    /// popover, by session activity, or by the background timer (all
    /// throttled to ``quotaPollInterval``) — so a switch is noticed no later
    /// than one poll interval after it happens, even in an otherwise idle app.
    private func noteActiveAccount(_ account: QuotaAccount) -> Bool {
        defer { lastKnownAccountUuid = account.uuid }
        guard let previous = lastKnownAccountUuid else { return false }
        return previous != account.uuid
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
    /// "By source" and "By model" titles next to it.
    ///
    /// Names the account the bars underneath describe, so the block announces
    /// itself the way the other two sections do. An unstamped reading (or no
    /// reading at all) must not be labelled with a guessed account, so the
    /// section falls back to naming itself — the literal "Quota" — rather than
    /// naming nobody. Lives here rather than in the view so both cases are
    /// testable.
    var quotaSectionTitle: String {
        snapshot?.account?.displayName ?? "Quota"
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

    /// Window the popover's charts cover. Thirty days is what the daily fold
    /// can serve without touching retention, and about what fits at a readable
    /// ~10 pt per day across the popover's width.
    ///
    /// `nonisolated` because the rebuild queue reads it too — see
    /// ``LocalStatsLoad/load(from:calendar:now:)``.
    nonisolated static let chartWindowDays = 30

    /// One query, because the popover now reads one window — and only when its
    /// answer can have changed.
    ///
    /// It used to also sum a five-hour per-entrypoint breakdown and a fixed-24h
    /// per-model list, both of which walked tens of thousands of `UsageEvent`s
    /// on the main actor for numbers that sat beside a thirty-day chart. The
    /// two tables read the same ``DailyUsageHistory`` the charts do, so that
    /// work is gone rather than moved.
    ///
    /// The one query left still costs ~11 ms on a real corpus, and it used to
    /// run on every call: each popover open, each FSEvents rebuild, and four
    /// times per account switch (the clear plus three ladder rungs). Its answer
    /// depends on exactly two things — the store, which is immutable, and
    /// which local day it is — so it is cached against both: a swapped store
    /// clears ``dailyHistoryDay``, and a new day no longer matches it.
    /// Nothing else can change the result, the display-range setting included:
    /// that picks a reading out of the history at render time.
    ///
    /// A failed read is not cached, so the next call retries it.
    private func reloadLocalStats() {
        let today = calendar.startOfDay(for: now())
        guard dailyHistoryDay != today else { return }
        apply(LocalStatsLoad.load(from: usageStore, calendar: calendar, now: now()))
    }

    /// Publishes one load. A failure keeps the history already on screen — see
    /// `testAFailedReloadAfterASuccessfulOneKeepsTheHistoryItAlreadyHas`.
    private func apply(_ load: LocalStatsLoad) {
        switch load.outcome {
        case .history(let history):
            dailyHistory = history
            localStatsError = nil
            dailyHistoryDay = load.day
        case .failure(let message):
            localStatsError = message
            dailyHistoryDay = nil
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
        snapshot: QuotaSnapshot? = MockQuotaProvider.sampleSnapshot(),
        error: String? = nil,
        warning: String? = nil,
        promoNotices: [RateLimitPromoNotice] = [],
        usingSampleData: Bool = false
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
            quotaProvider: MockQuotaProvider(snapshot: snapshot ?? previewPlaceholder),
            usageStore: store,
            promoNoticeProvider: MockPromoNoticeProvider(notices: promoNotices),
            usingSampleData: usingSampleData
        )
        model.snapshot = snapshot
        model.promoNotices = promoNotices
        model.dailyHistory = (try? store.dailyUsage(days: AppModel.chartWindowDays)) ?? .empty
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
    /// notice, the scoped weekly row, a part-spent usage-credits bar, and the
    /// active account titling the quota section.
    ///
    /// The single source of truth for the README asset renderer
    /// (`Tests/ClaudeStatsTests/ReadmeAssetRenderTests.swift`), so the shipped
    /// screenshot and the Xcode canvas can never drift apart — the preview
    /// below renders the same call the renderer does.
    ///
    /// - Parameter now: pinned by the renderer so every time-derived string
    ///   (the reset countdowns) is byte-stable across runs; defaults to
    ///   `Date()` for the canvas, which wants a live-looking clock.
    static func previewShowcase(now: Date = Date()) -> AppModel {
        var active = MockQuotaProvider.sampleShowcaseSnapshot(now: now)
        active.account = MockQuotaProvider.sampleAccount()
        return preview(
            snapshot: active,
            promoNotices: [MockPromoNoticeProvider.sampleNotice()]
        )
    }

    /// Live source, but stale — quota still shown, plus a warning line.
    static func previewStaleWarning() -> AppModel {
        preview(warning: "Statusline cache is 14 minutes old.")
    }

    /// Straight after "Clear Quota Cache": no snapshot, no error — just the
    /// notice explaining what the popover is waiting for.
    static func previewCacheCleared() -> AppModel {
        let model = preview(snapshot: nil)
        model.quotaCacheClearedNotice = QuotaCacheClear.manualNotice
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
        let model = preview(snapshot: snapshot)
        model.quotaWarning = ClaudeStatsError
            .staleQuotaSource(snapshot: snapshot, age: 42 * 60)
            .localizedDescription
        return model
    }
}
#endif
