import Foundation

/// Incremental builder of ``LocalLogUsageStore`` snapshots.
///
/// The naive refresh path — reparse every session JSONL under
/// `projects/` — costs ~4.5s and hundreds of MB on a real multi-GB corpus,
/// and the FSEvents watcher triggers it every couple of seconds while a
/// session is active. This index makes ``rebuild()`` cheap enough to run on
/// every watcher batch:
///
/// - **Parse only what changed.** Each rebuild stats every session file
///   (cheap) and reparses only those whose modification date or size differs
///   from the cached entry. The watcher batch is just a trigger; change
///   detection works from the stat pass alone, so dropped FSEvents, renames,
///   and edits that happened while the app wasn't looking are all picked up
///   the same way.
/// - **Retain per-event data only inside the retention window.** Events older
///   than ``retention`` are folded into per-model
///   ``HistoricalModelUsage`` totals — the only thing any query needs from
///   deep history (see ``LocalLogUsageStore/historicalByModel``). This keeps
///   the in-memory event array proportional to recent activity instead of
///   lifetime usage.
///
/// Not thread-safe: confine each instance to one serial queue (the app uses
/// its rebuild queue). The initialiser only resolves the config directory —
/// the first ``rebuild()`` does the initial full parse.
public final class SessionCorpusIndex {
    /// Cached state for one session file on disk.
    private struct CachedFile {
        var modificationDate: Date
        var fileSize: Int
        /// Events newer than the fold cutoff, oldest-first (parse order).
        var recentEvents: [UsageEvent]
        /// This file's events that aged past the cutoff, folded per model ID.
        var foldedByModel: [String?: HistoricalModelUsage]
        /// Total malformed lines seen in this file's last parse.
        var skippedCount: Int
        /// First few skipped-line errors, capped at `skippedSampleLimit`.
        var skippedSamples: [ClaudeStatsError]
    }

    /// How long individual events are kept before being folded into
    /// ``HistoricalModelUsage`` totals. Must cover the longest per-event
    /// query: every ``TimeWindow`` (≤ 7 days) and the plan-tier heuristic's
    /// ``LocalLogUsageStore/planDetectionHistoryDays`` (8 days).
    public static let defaultRetention: TimeInterval =
        TimeInterval(LocalLogUsageStore.planDetectionHistoryDays) * 86_400

    /// Per-file cap on retained skipped-line errors. A half-written last line
    /// is the normal state of an active session file, so these accumulate one
    /// per active file; the cap only guards against a pathological file
    /// producing thousands.
    public static let skippedSampleLimit = 5

    private let configDirectory: URL
    private let retention: TimeInterval
    private let calendar: Calendar
    private let nowProvider: @Sendable () -> Date
    /// Parse seam, injectable so tests can count which files get reparsed.
    private let parseFile: (URL) -> SessionLogParser.ParseResult

    private var files: [String: CachedFile] = [:]

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
    public func rebuild() -> LocalLogUsageStore {
        let now = nowProvider()
        let cutoff = now.addingTimeInterval(-retention)

        var seen = Set<String>()
        for url in SessionLogParser.sessionFileURLs(inConfigDirectory: configDirectory) {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modificationDate = values.contentModificationDate,
                  let fileSize = values.fileSize
            else { continue }  // vanished mid-scan; next rebuild sees the truth
            let path = url.path
            seen.insert(path)

            if var cached = files[path],
               cached.modificationDate == modificationDate,
               cached.fileSize == fileSize {
                // Unchanged on disk — just fold whatever aged past the cutoff.
                if cached.recentEvents.contains(where: { $0.timestamp < cutoff }) {
                    Self.fold(events: &cached.recentEvents, into: &cached.foldedByModel, before: cutoff)
                    files[path] = cached
                }
                continue
            }

            let result = parseFile(url)
            var entry = CachedFile(
                modificationDate: modificationDate,
                fileSize: fileSize,
                recentEvents: result.events,
                foldedByModel: [:],
                skippedCount: result.skippedLines.count,
                skippedSamples: Array(result.skippedLines.prefix(Self.skippedSampleLimit))
            )
            Self.fold(events: &entry.recentEvents, into: &entry.foldedByModel, before: cutoff)
            files[path] = entry
        }
        files = files.filter { seen.contains($0.key) }

        var events: [UsageEvent] = []
        var skipped: [ClaudeStatsError] = []
        var historical: [String?: HistoricalModelUsage] = [:]
        for entry in files.values {
            events.append(contentsOf: entry.recentEvents)
            skipped.append(contentsOf: entry.skippedSamples)
            for (modelID, total) in entry.foldedByModel {
                historical[modelID, default: HistoricalModelUsage()].merge(total)
            }
        }

        return LocalLogUsageStore(
            events: events,
            skippedLines: skipped,
            historicalByModel: historical,
            calendar: calendar,
            now: nowProvider
        )
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
        before cutoff: Date
    ) {
        var kept: [UsageEvent] = []
        kept.reserveCapacity(events.count)
        for event in events {
            if event.timestamp < cutoff {
                folded[event.modelID, default: HistoricalModelUsage()].fold(event)
            } else {
                kept.append(event)
            }
        }
        events = kept
    }
}
