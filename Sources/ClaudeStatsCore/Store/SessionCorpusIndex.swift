import Foundation
import os

/// Incremental builder of ``LocalLogUsageStore`` snapshots.
///
/// The naive refresh path — reparse every session JSONL under
/// `projects/` — costs ~4.5s and hundreds of MB on a real multi-GB corpus,
/// and the FSEvents watcher triggers it every couple of seconds while a
/// session is active. This index makes ``rebuild(changed:)`` cheap enough to
/// run on every watcher batch:
///
/// - **Stat only what the batch named.** Handed the watcher's
///   ``FileChangeBatch``, a rebuild stats just the `.jsonl` paths in it and
///   reparses those whose modification date or size differs from the cached
///   entry; a path that no longer stats is dropped, which is how deletions and
///   the old half of a rename are caught. Without a batch — the launch
///   rebuild — it enumerates and stats the whole corpus instead, and that same
///   full scan is the fallback whenever the batch can't be trusted to be
///   complete: the first rebuild, dropped FSEvents, a removed or renamed
///   directory. So edits made while the app wasn't looking are still picked
///   up; they just wait for a full scan rather than being found by one every
///   time.
/// - **Retain per-event data only inside the retention window.** Events older
///   than ``retention`` are folded into per-model
///   ``HistoricalModelUsage`` totals and per-day ``DailyUsageCell`` totals —
///   the only things any query needs from deep history (see
///   ``LocalLogUsageStore/historicalByModel`` and
///   ``LocalLogUsageStore/historicalDailyCells``). This keeps
///   the in-memory event array proportional to recent activity instead of
///   lifetime usage.
///
/// Not thread-safe: confine each instance to one serial queue (the app uses
/// its rebuild queue). The initialiser only resolves the config directory —
/// the first ``rebuild(changed:)`` does the initial full parse.
public final class SessionCorpusIndex {
    /// Cached state for one session file on disk.
    private struct CachedFile {
        var modificationDate: Date
        var fileSize: Int
        /// Events newer than the fold cutoff, oldest-first (parse order).
        var recentEvents: [UsageEvent]
        /// This file's events that aged past the cutoff, folded per model ID.
        var foldedByModel: [String?: HistoricalModelUsage]
        /// The same aged-out events, folded per (day, model, source) instead —
        /// the history half of ``LocalLogUsageStore/dailyUsage(days:)``. Bounded
        /// by the days this one file spans, which is why no separate retention
        /// is needed for it.
        var dailyCells: [DailyUsageCell: DailyUsageTotals]
        /// Total malformed lines seen in this file's last parse.
        var skippedCount: Int
        /// First few skipped-line errors, capped at `skippedSampleLimit`.
        var skippedSamples: [ClaudeStatsError]
    }

    /// How long individual events are kept before being folded into
    /// ``HistoricalModelUsage`` totals. Must cover the longest per-event
    /// query, so it is derived from both: every ``TimeWindow`` and
    /// ``LocalLogUsageStore/localHistoryDays`` (8 days). A new, longer window
    /// case widens retention automatically instead of silently
    /// under-reporting.
    public static let defaultRetention: TimeInterval = max(
        TimeInterval(LocalLogUsageStore.localHistoryDays) * 86_400,
        TimeWindow.allCases.map(\.duration).max() ?? 0
    )

    /// Per-file cap on retained skipped-line errors. A half-written last line
    /// is the normal state of an active session file, so these accumulate one
    /// per active file; the cap only guards against a pathological file
    /// producing thousands.
    public static let skippedSampleLimit = 5

    /// Signpost emitter for ``rebuild(changed:)``'s phases, so the real cost of
    /// an FSEvent-triggered rebuild can be read off an Instruments trace
    /// instead of guessed at. Record with:
    ///
    /// ```
    /// xcrun xctrace record --template 'os_signpost' --launch ClaudeStats.app
    /// ```
    ///
    /// Signposts compile to a cheap "is anyone listening?" check when nothing
    /// is recording, so these stay always-on rather than hiding behind a
    /// build flag. Five interval names are emitted, the first two mutually
    /// exclusive — each rebuild takes one branch or the other. A healthy
    /// steady-state trace is one `StatPass` at launch and one `ScopedScan` per
    /// coalesced write; a `StatPass` per write means something keeps forcing
    /// the full path.
    ///
    /// - `StatPass` — one per *full* rebuild, spanning enumeration + sort of
    ///   the session files and the per-file `resourceValues` stat. It
    ///   *encloses* the `Reparse` and `Fold` intervals below (the scan and the
    ///   reparse-or-skip decision share one loop, and instrumentation must not
    ///   restructure that), so the stat-only cost is
    ///   `StatPass − Σ Reparse − Σ Fold`. That residual still includes the
    ///   per-file `contains(where:)` scan (over every retained event of every
    ///   unchanged file) that decides whether a fold is even needed.
    /// - `ScopedScan` — one per *batch-scoped* rebuild, over the stat of just
    ///   the named paths plus the retention sweep across the rest of the index.
    ///   Encloses the same `Reparse`/`Fold` intervals. `named:` is how many
    ///   `.jsonl` changes the batch carried, against which `reparsed:` and
    ///   `removed:` say how many were real news — a large `named:` with
    ///   `reparsed: 0` means the debounce window is collecting touches that
    ///   change nothing.
    /// - `Reparse` — one per file that actually got reparsed, around the parse
    ///   call alone; files skipped by the mtime/size check emit nothing, so
    ///   the count of intervals is the churn rate and their sum is the real
    ///   reparse cost.
    /// - `Fold` — one per file whose retained events are swept for the
    ///   fold-past-cutoff pass, covering both unchanged files (aged-out
    ///   events) and freshly reparsed files (fresh events already past the
    ///   cutoff on arrival).
    /// - `SnapshotAssembly` — one per rebuild, over the event concatenation
    ///   and historical-fold merge that builds the returned store.
    private static let signposter = OSSignposter(
        subsystem: "de.bitgrip.claude-stats",
        category: "RebuildPerf"
    )

    private let configDirectory: URL
    private let retention: TimeInterval
    private let calendar: Calendar
    private let nowProvider: @Sendable () -> Date
    /// Parse seam, injectable so tests can count which files get reparsed.
    private let parseFile: (URL) -> SessionLogParser.ParseResult

    private var files: [String: CachedFile] = [:]

    /// Every session path the last full scan saw, ascending — the deterministic
    /// order the snapshot assembly walks. `SessionLogParser.sessionFileURLs`
    /// already yields paths sorted, so a full scan just keeps what it enumerated
    /// rather than re-sorting 13.5k strings; a scoped rebuild maintains the
    /// order incrementally through ``insert(path:)`` / ``remove(path:)``.
    ///
    /// A superset of `files.keys`: a path that vanished between the stat and the
    /// assembly stays listed and is skipped when its entry doesn't resolve.
    private var orderedPaths: [String] = []

    /// `false` until one full scan has populated ``orderedPaths``. Until then a
    /// scoped rebuild has no baseline to narrow against, so the first rebuild is
    /// always a full one even when handed a batch.
    private var hasScannedFullCorpus = false

    /// - Parameters:
    ///   - environment: consulted for `$CLAUDE_CONFIG_DIR`, like the stores.
    ///   - retention: see ``defaultRetention``.
    /// - Throws: ``ClaudeStatsError/configDirectoryNotFound``.
    public convenience init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        parser: SessionLogParser = SessionLogParser(),
        retention: TimeInterval = SessionCorpusIndex.defaultRetention,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        let directory = try ClaudeConfigDirectory.resolve(environment: environment)
        self.init(
            configDirectory: directory,
            parser: parser,
            retention: retention,
            calendar: calendar,
            now: now
        )
    }

    public init(
        configDirectory: URL,
        parser: SessionLogParser = SessionLogParser(),
        retention: TimeInterval = SessionCorpusIndex.defaultRetention,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() },
        parseFile: ((URL) -> SessionLogParser.ParseResult)? = nil
    ) {
        self.configDirectory = configDirectory
        self.retention = retention
        self.calendar = calendar
        self.nowProvider = now
        self.parseFile = parseFile ?? { parser.parse(fileAt: $0) }
    }

    /// Bring the index up to date with the on-disk corpus and return a store
    /// snapshot. Reparses only files whose (modification date, size) changed;
    /// drops entries for deleted files; folds events that aged past the
    /// retention cutoff since the last rebuild.
    ///
    /// - Parameter batch: the watcher batch that triggered this rebuild, when
    ///   there is one. Given a batch, only the `.jsonl` paths it names are
    ///   stat-ed and reparsed, which is what keeps a rebuild off the
    ///   O(corpus) enumeration. Passing `nil` — the launch rebuild, or any
    ///   caller with no batch to hand — scans the whole corpus. A batch is
    ///   ignored (and the full scan runs anyway) before the first full scan
    ///   has built a baseline, when the OS says it dropped events
    ///   (``FileChangeBatch/requiresFullRescan``), and when a directory was
    ///   removed or renamed
    ///   (``FileChangeBatch/containsRemovedOrRenamedDirectory``) — FSEvents
    ///   names no children for those, so the batch is not a complete account
    ///   of what changed.
    public func rebuild(changed batch: FileChangeBatch? = nil) -> LocalLogUsageStore {
        let now = nowProvider()
        let cutoff = now.addingTimeInterval(-retention)

        if let batch,
           hasScannedFullCorpus,
           !batch.requiresFullRescan,
           !batch.containsRemovedOrRenamedDirectory {
            scan(changes: batch.contentChanges(withExtension: "jsonl"), before: cutoff)
        } else {
            scanFullCorpus(before: cutoff)
        }

        return assembleSnapshot()
    }

    // MARK: - Scanning

    /// Enumerate and stat every session file under `projects/`, reparsing the
    /// ones whose (modification date, size) moved and dropping entries for the
    /// ones that are gone. Rebuilds ``orderedPaths`` from the enumeration.
    private func scanFullCorpus(before cutoff: Date) {
        var seen = Set<String>()
        // Scan order, retained: `sessionFileURLs` already yields paths sorted, so
        // this *is* the deterministic assembly order the snapshot loop needs.
        // Re-deriving it there with `files.keys.sorted()` sorted the same 13.5k
        // strings a second time on every rebuild.
        var scannedPaths: [String] = []
        var reparsedCount = 0
        let statPass = Self.signposter.beginInterval("StatPass", id: Self.signposter.makeSignpostID())
        for url in SessionLogParser.sessionFileURLs(inConfigDirectory: configDirectory) {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modificationDate = values.contentModificationDate,
                  let fileSize = values.fileSize
            else { continue }  // vanished mid-scan; next rebuild sees the truth
            let path = url.path
            seen.insert(path)
            scannedPaths.append(path)

            if var cached = files[path],
               cached.modificationDate == modificationDate,
               cached.fileSize == fileSize {
                // Unchanged on disk — just fold whatever aged past the cutoff.
                // The `contains` pre-check keeps untouched files off the fold
                // path entirely; it is deliberately *not* inside
                // `foldAgedEvents`, where the reparse path below wants the fold
                // (and its signpost) unconditionally.
                if cached.recentEvents.contains(where: { $0.timestamp < cutoff }) {
                    foldAgedEvents(of: &cached, before: cutoff)
                    files[path] = cached
                }
                continue
            }

            reparse(url, path: path, modificationDate: modificationDate, fileSize: fileSize, before: cutoff)
            reparsedCount += 1
        }
        files = files.filter { seen.contains($0.key) }
        orderedPaths = scannedPaths
        hasScannedFullCorpus = true
        Self.signposter.endInterval(
            "StatPass", statPass,
            "scanned: \(seen.count), reparsed: \(reparsedCount)"
        )
    }

    /// Stat and reparse only the paths `changes` names, then sweep the retention
    /// cutoff across the whole index.
    ///
    /// Deletions are detected the same way the full scan gets them for free —
    /// by the file not being there. A `stat` that fails is taken as "gone", which
    /// covers `.removed` and the *old* half of a `.renamed` pair (that path
    /// 404s), while the new half stats fine and is inserted. `.metadata`-only
    /// touches never reach here: ``FileChangeBatch/contentChanges`` already
    /// dropped them.
    ///
    /// The retention sweep is deliberately over every known file, not just the
    /// named ones: aging out is a property of the clock, so it happens to files
    /// nothing has written to. It is cheap — an in-memory `contains` per file,
    /// no `stat`, no enumeration — and files just reparsed above were folded on
    /// the way in, so the sweep finds nothing left to fold for them and can't
    /// double-count.
    private func scan(changes: [FileChange], before cutoff: Date) {
        let scopedScan = Self.signposter.beginInterval("ScopedScan", id: Self.signposter.makeSignpostID())
        var reparsedCount = 0
        var removedCount = 0
        let prefixes = projectsPrefixes()

        for change in changes {
            // Batch paths come from FSEvents in fully resolved form, which need
            // not be the spelling the cache is keyed by. Skip anything that
            // isn't this corpus in either spelling.
            guard let path = cacheKey(for: change.path, prefixes: prefixes) else { continue }
            let url = URL(fileURLWithPath: path)

            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modificationDate = values.contentModificationDate,
                  let fileSize = values.fileSize
            else {
                if files.removeValue(forKey: path) != nil { removedCount += 1 }
                remove(path: path)
                continue
            }

            if let cached = files[path],
               cached.modificationDate == modificationDate,
               cached.fileSize == fileSize {
                // Named but unchanged: a write that reverted inside the
                // debounce window, or a touch that survived the metadata
                // filter. The sweep below still ages its events.
                continue
            }

            // New to the index — a `.created`, or the new half of a rename.
            if files[path] == nil { insert(path: path) }
            reparse(url, path: path, modificationDate: modificationDate, fileSize: fileSize, before: cutoff)
            reparsedCount += 1
        }

        for path in orderedPaths {
            guard var cached = files[path],
                  cached.recentEvents.contains(where: { $0.timestamp < cutoff })
            else { continue }
            foldAgedEvents(of: &cached, before: cutoff)
            files[path] = cached
        }

        Self.signposter.endInterval(
            "ScopedScan", scopedScan,
            "named: \(changes.count), reparsed: \(reparsedCount), removed: \(removedCount)"
        )
    }

    /// Reparse `url` from scratch and cache the result under `path`, discarding
    /// whatever was there — so a fold that already happened for this file is
    /// rebuilt rather than added to.
    private func reparse(
        _ url: URL,
        path: String,
        modificationDate: Date,
        fileSize: Int,
        before cutoff: Date
    ) {
        let reparse = Self.signposter.beginInterval("Reparse", id: Self.signposter.makeSignpostID())
        let result = parseFile(url)
        Self.signposter.endInterval(
            "Reparse", reparse,
            "bytes: \(fileSize), events: \(result.events.count)"
        )

        var entry = CachedFile(
            modificationDate: modificationDate,
            fileSize: fileSize,
            recentEvents: result.events,
            foldedByModel: [:],
            dailyCells: [:],
            skippedCount: result.skippedLines.count,
            skippedSamples: Array(result.skippedLines.prefix(Self.skippedSampleLimit))
        )
        // Fresh events can already be past the cutoff on arrival, so a
        // just-parsed file folds too.
        foldAgedEvents(of: &entry, before: cutoff)
        files[path] = entry
    }

    /// Move `entry`'s events older than `cutoff` into its historical totals.
    private func foldAgedEvents(of entry: inout CachedFile, before cutoff: Date) {
        // Both `inout` arguments must come from independent locals: passing
        // `&entry.recentEvents` and `&entry.foldedByModel` directly lets the
        // release optimizer collapse them onto one base pointer and trip a runtime
        // exclusivity trap. Do not inline these back into the call.
        var recentEvents = entry.recentEvents
        var foldedByModel = entry.foldedByModel
        var dailyCells = entry.dailyCells
        let fold = Self.signposter.beginInterval("Fold", id: Self.signposter.makeSignpostID())
        Self.fold(
            events: &recentEvents,
            into: &foldedByModel,
            daily: &dailyCells,
            before: cutoff,
            calendar: calendar
        )
        Self.signposter.endInterval("Fold", fold, "events: \(recentEvents.count)")
        entry.recentEvents = recentEvents
        entry.foldedByModel = foldedByModel
        entry.dailyCells = dailyCells
    }

    // MARK: - Path space

    /// The two spellings of the `projects/` root a path can arrive in, each with
    /// a trailing separator so a prefix test can't match a sibling directory
    /// whose name merely starts the same:
    ///
    /// - *declared* — ``configDirectory`` with `projects` appended, which
    ///   ``ClaudeConfigDirectory/resolve(environment:homeDirectory:fileManager:)``
    ///   only *standardizes*, symlinks and all.
    /// - *resolved* — the same directory with symlinks followed through. FSEvents
    ///   reports paths in this form and nothing else, so it is the only form a
    ///   watcher batch ever carries.
    ///
    /// The two differ whenever the config directory sits behind a symlink —
    /// `$CLAUDE_CONFIG_DIR` under `/tmp` or `/var/folders/…`, where macOS's
    /// `/var → /private/var` link makes every watcher path `/private/…`. Without
    /// translating between them a scoped rebuild matches nothing, falls through
    /// every path as "not ours", and quietly stops updating.
    ///
    /// `scanned` is whichever of the two the cache is actually keyed by, and
    /// that is `FileManager.enumerator(at:)`'s choice rather than ours: measured
    /// on macOS 15, it hands back *resolved* URLs even when given a declared
    /// path, so `SessionLogParser.sessionFileURLs` yields resolved paths from a
    /// `/var/folders/…` config directory. Rather than bake that in, this checks
    /// the spelling of a key the index already holds and only falls back to the
    /// measured behaviour for an empty corpus.
    ///
    /// Resolution goes through ``ConfigDirectoryWatcher/resolvedPath(_:)`` rather
    /// than `URL.resolvingSymlinksInPath()` on purpose — see that method for why
    /// the Foundation one gives the wrong answer here. Recomputed per scoped
    /// rebuild (one `realpath`, against the corpus-wide enumeration this lane
    /// removes) so that a `projects/` created after launch is picked up.
    private func projectsPrefixes() -> (scanned: String, watched: String) {
        let projects = configDirectory.appendingPathComponent("projects", isDirectory: true).path
        let declared = projects + "/"
        let resolved = ConfigDirectoryWatcher.resolvedPath(projects) + "/"
        if let known = orderedPaths.first {
            if known.hasPrefix(declared) { return (scanned: declared, watched: resolved) }
            if known.hasPrefix(resolved) { return (scanned: resolved, watched: declared) }
        }
        return (scanned: resolved, watched: declared)
    }

    /// `path` as this index keys it, or `nil` when it names something outside
    /// this corpus (anything under a different root — a test's own scratch
    /// files, another config directory) and so has nothing to update.
    private func cacheKey(for path: String, prefixes: (scanned: String, watched: String)) -> String? {
        if path.hasPrefix(prefixes.scanned) { return path }
        if path.hasPrefix(prefixes.watched) {
            return prefixes.scanned + path.dropFirst(prefixes.watched.count)
        }
        return nil
    }

    // MARK: - Ordered path maintenance

    /// Splice `path` into ``orderedPaths`` at its sorted position. A no-op when
    /// it is already listed. Binary search rather than append-and-re-sort: a
    /// scoped rebuild touches a handful of paths, and re-sorting the whole
    /// corpus for each of them is the cost this lane exists to remove.
    private func insert(path: String) {
        let index = Self.insertionIndex(of: path, in: orderedPaths)
        guard index == orderedPaths.count || orderedPaths[index] != path else { return }
        orderedPaths.insert(path, at: index)
    }

    /// Drop `path` from ``orderedPaths``. A no-op when it isn't listed.
    private func remove(path: String) {
        let index = Self.insertionIndex(of: path, in: orderedPaths)
        guard index < orderedPaths.count, orderedPaths[index] == path else { return }
        orderedPaths.remove(at: index)
    }

    /// Index of the first element of the ascending `paths` not ordered before
    /// `path` — i.e. where `path` belongs, and where an existing equal entry
    /// would sit.
    private static func insertionIndex(of path: String, in paths: [String]) -> Int {
        var low = 0
        var high = paths.count
        while low < high {
            let middle = low + (high - low) / 2
            if paths[middle] < path {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    // MARK: - Snapshot

    private func assembleSnapshot() -> LocalLogUsageStore {
        let assembly = Self.signposter.beginInterval("SnapshotAssembly", id: Self.signposter.makeSignpostID())
        var events: [UsageEvent] = []
        var skipped: [ClaudeStatsError] = []
        var historical: [String?: HistoricalModelUsage] = [:]
        var dailyCells: [DailyUsageCell: DailyUsageTotals] = [:]
        // Walked in `orderedPaths` order — sorted by path, whether a full scan
        // laid it down from `SessionLogParser.sessionFileURLs` or a scoped scan
        // spliced into it — so the assembly is deterministic across launches;
        // Dictionary iteration order would let timestamp ties resolve
        // differently per process. `orderedPaths` is a superset of `files.keys`;
        // a path with no entry is one that vanished before it could be stat-ed.
        for path in orderedPaths {
            guard let entry = files[path] else { continue }
            events.append(contentsOf: entry.recentEvents)
            skipped.append(contentsOf: entry.skippedSamples)
            for (modelID, total) in entry.foldedByModel {
                historical[modelID, default: HistoricalModelUsage()].merge(total)
            }
            for (cell, totals) in entry.dailyCells {
                dailyCells[cell, default: DailyUsageTotals()].merge(totals)
            }
        }
        let store = LocalLogUsageStore(
            events: events,
            skippedLines: skipped,
            historicalByModel: historical,
            historicalDailyCells: dailyCells,
            calendar: calendar,
            now: nowProvider
        )
        Self.signposter.endInterval(
            "SnapshotAssembly", assembly,
            "events: \(events.count), models: \(historical.count)"
        )
        return store
    }

    /// Total malformed lines across the corpus (uncapped, unlike the samples
    /// handed to the store) — for diagnostics.
    public var skippedLineCount: Int {
        files.values.reduce(0) { $0 + $1.skippedCount }
    }

    /// Move every event older than `cutoff` from `events` into `folded`.
    /// Parse order within one file is chronological in practice, but a strict
    /// prefix split would silently retain any out-of-order stragglers, so this
    /// partitions by timestamp instead.
    private static func fold(
        events: inout [UsageEvent],
        into folded: inout [String?: HistoricalModelUsage],
        daily: inout [DailyUsageCell: DailyUsageTotals],
        before cutoff: Date,
        calendar: Calendar
    ) {
        var kept: [UsageEvent] = []
        kept.reserveCapacity(events.count)
        var days = LocalDayResolver(calendar: calendar)
        for event in events {
            if event.timestamp < cutoff {
                folded[event.modelID, default: HistoricalModelUsage()].fold(event)
                if DailyUsageTotals.countsTowardsDailyHistory(event) {
                    let cell = DailyUsageCell(
                        day: days.day(for: event.timestamp),
                        modelID: event.modelID,
                        entrypoint: event.entrypoint
                    )
                    daily[cell, default: DailyUsageTotals()].add(event)
                }
            } else {
                kept.append(event)
            }
        }
        events = kept
    }
}
