import CoreServices
import Foundation

/// Kernel-notified watcher for the Claude Code config directory tree.
///
/// Wraps `FSEventStream` (CoreServices) so the app is woken only when something
/// under `~/.claude` is actually written, instead of polling, and reports *which
/// paths* changed so the log layer can reparse incrementally rather than
/// rescanning the whole tree.
///
/// ## Usage
///
/// ```swift
/// let watcher = try ConfigDirectoryWatcher(
///     configuration: .claudeConfigDirectory()
/// ) { batch in
///     if batch.requiresFullRescan {
///         store.rescanEverything()
///     } else {
///         store.reparse(batch.contentChanges(withExtension: "jsonl").map(\.path))
///     }
/// }
/// try watcher.start()
/// ```
///
/// ## API shape: callback, not `AsyncSequence`
///
/// Deliveries are a `@Sendable` closure rather than an `AsyncSequence` of
/// batches. Reasons, since this is the boundary the app target will consume:
///
/// - The consumer is ``UsageStoring``, whose members are all *synchronous* (it
///   serves from an in-memory index). A batch handler does `reparse(paths)` and
///   pokes `@Published` state — there's nothing to await, so an async stream
///   would only add a `Task` whose lifetime has to be managed alongside the
///   watcher's own start/stop lifecycle. Two overlapping lifecycles instead of
///   one, for no gain.
/// - Back-pressure, the usual reason to want a stream, is already handled
///   upstream by ``ChangeCoalescer``: bursts collapse into one batch, so the
///   handler can't be flooded, and buffering policy has no meaning here (a
///   dropped batch would mean lost reparse work).
/// - A stream is trivially layered on top by a caller that wants one
///   (`AsyncStream { continuation in ... }` around this callback), whereas the
///   reverse costs a `Task` per consumer.
///
/// Deliveries land on the watcher's private serial queue, never the main queue —
/// hop to the main actor yourself for UI updates.
///
/// ## Lifecycle
///
/// ``start()`` and ``stop()`` are idempotent and safe to interleave from any
/// thread. `deinit` calls ``stop()``, so a dropped watcher tears its stream
/// down instead of leaking it; the C-level `info` pointer deliberately does not
/// retain the watcher, which is what makes that `deinit` reachable at all.
public final class ConfigDirectoryWatcher: @unchecked Sendable {
    /// Called once per debounced batch. See ``FileChangeBatch``.
    public typealias ChangeHandler = @Sendable (FileChangeBatch) -> Void

    /// Everything tunable about a watcher.
    public struct Configuration: Sendable {
        /// Directory trees to watch, recursively. Usually one entry.
        public var paths: [String]

        /// Quiet period after the last event before a batch is delivered.
        /// See ``ChangeCoalescer/debounceInterval``.
        public var debounceInterval: TimeInterval

        /// Ceiling on delivery latency during sustained writes, or `nil` for an
        /// uncapped trailing debounce.
        /// See ``ChangeCoalescer/maximumDelay``.
        public var maximumDelay: TimeInterval?

        /// FSEvents' own server-side coalescing latency, in seconds. Kept small
        /// because our debounce does the real batching; this only limits how
        /// many wake-ups the daemon sends us.
        public var eventLatency: TimeInterval

        /// Whether ``start()`` rejects paths that don't exist. Leaving this
        /// `true` surfaces a missing config directory immediately instead of
        /// silently watching nothing. (FSEvents itself accepts non-existent
        /// paths and simply never reports anything.)
        public var requiresExistingPaths: Bool

        public init(
            paths: [String],
            debounceInterval: TimeInterval = ChangeCoalescer.defaultDebounceInterval,
            maximumDelay: TimeInterval? = ChangeCoalescer.defaultMaximumDelay,
            eventLatency: TimeInterval = 0.1,
            requiresExistingPaths: Bool = true
        ) {
            self.paths = paths
            self.debounceInterval = debounceInterval
            self.maximumDelay = maximumDelay
            self.eventLatency = eventLatency
            self.requiresExistingPaths = requiresExistingPaths
        }

        /// Watch a single directory.
        public init(
            path: String,
            debounceInterval: TimeInterval = ChangeCoalescer.defaultDebounceInterval,
            maximumDelay: TimeInterval? = ChangeCoalescer.defaultMaximumDelay,
            eventLatency: TimeInterval = 0.1,
            requiresExistingPaths: Bool = true
        ) {
            self.init(
                paths: [path],
                debounceInterval: debounceInterval,
                maximumDelay: maximumDelay,
                eventLatency: eventLatency,
                requiresExistingPaths: requiresExistingPaths
            )
        }

        /// Watch Claude Code's config directory: `$CLAUDE_CONFIG_DIR` when set,
        /// otherwise `~/.claude` (never `~/.config/claude`).
        ///
        /// Deliberately delegates to ``ClaudeConfigDirectory/candidate(environment:homeDirectory:)``
        /// — the parsing layer resolves the log tree with the same type, and a
        /// second copy of that logic here could drift from the directory the
        /// parser actually reads.
        ///
        /// Uses `candidate` rather than `ClaudeConfigDirectory.resolve`, so
        /// building a `Configuration` can't throw; ``start()`` is where a
        /// missing directory surfaces, as ``StartError/pathNotADirectory(_:)``.
        public static func claudeConfigDirectory(
            debounceInterval: TimeInterval = ChangeCoalescer.defaultDebounceInterval,
            maximumDelay: TimeInterval? = ChangeCoalescer.defaultMaximumDelay,
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Configuration {
            Configuration(
                path: ClaudeConfigDirectory.candidate(environment: environment).path,
                debounceInterval: debounceInterval,
                maximumDelay: maximumDelay
            )
        }
    }

    /// Why ``start()`` refused.
    public enum StartError: Error, Sendable, Equatable {
        /// ``Configuration/paths`` was empty.
        case noPathsConfigured
        /// A configured path doesn't exist or isn't a directory, and
        /// ``Configuration/requiresExistingPaths`` was `true`.
        case pathNotADirectory(String)
        /// `FSEventStreamCreate` returned `NULL` — nothing actionable, but
        /// surfaced rather than swallowed.
        case streamCreationFailed
    }

    public let configuration: Configuration

    /// Serial queue for both FSEvents delivery and debounce timers, so the
    /// coalescer never sees concurrent access and batches arrive in order.
    private let queue: DispatchQueue
    private let coalescer: ChangeCoalescer
    /// Gates delivery so a batch already in flight on `queue` when ``stop()``
    /// lands is dropped instead of arriving after the caller stopped listening.
    private let active: ActiveFlag

    private let lock = NSLock()
    /// Lock-guarded. Non-`nil` exactly while running.
    private var stream: FSEventStreamRef?
    /// Lock-guarded. The manually retained `EventSink` handed to C as `info`.
    private var sinkPointer: UnsafeMutableRawPointer?

    /// - Parameters:
    ///   - configuration: What to watch and how hard to debounce.
    ///   - onChange: Batch handler. Invoked on a private serial queue.
    public init(configuration: Configuration, onChange: @escaping ChangeHandler) {
        self.configuration = configuration
        let queue = DispatchQueue(label: "de.bitgrip.claude-stats.config-watcher")
        self.queue = queue

        let active = ActiveFlag()
        self.active = active

        // Built from locals, never capturing `self`, so the coalescer's flush
        // closure can't retain the watcher.
        self.coalescer = ChangeCoalescer(
            debounceInterval: configuration.debounceInterval,
            maximumDelay: configuration.maximumDelay,
            scheduler: DispatchQueueScheduler(queue: queue)
        ) { batch in
            guard active.isActive else { return }
            onChange(batch)
        }
    }

    deinit {
        stop()
    }

    /// `true` between a successful ``start()`` and the next ``stop()``.
    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stream != nil
    }

    // MARK: Lifecycle

    /// Begin watching. No-op when already running.
    ///
    /// - Throws: ``StartError``.
    public func start() throws {
        lock.lock()
        guard stream == nil else {
            lock.unlock()
            return
        }
        lock.unlock()

        guard !configuration.paths.isEmpty else { throw StartError.noPathsConfigured }

        // FSEvents reports fully symlink-resolved paths, so resolve the roots
        // the same way — otherwise a caller watching `/var/folders/...` gets
        // events under `/private/var/folders/...` that don't share its prefix.
        var resolvedPaths: [String] = []
        for path in configuration.paths {
            let resolved = ConfigDirectoryWatcher.resolvedPath(path)
            if configuration.requiresExistingPaths {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
                      isDirectory.boolValue
                else {
                    throw StartError.pathNotADirectory(path)
                }
            }
            resolvedPaths.append(resolved)
        }

        // The `info` pointer is a manually retained sink that holds only the
        // coalescer — never the watcher. That keeps `deinit` reachable (a
        // retained `self` here would be an un-collectable cycle) and means a
        // late callback can't touch a half-torn-down watcher.
        let sink = EventSink(coalescer: coalescer)
        let sinkPointer = Unmanaged.passRetained(sink).toOpaque()

        var context = FSEventStreamContext(
            version: 0,
            info: sinkPointer,
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents      // per-file paths + item flags
                | kFSEventStreamCreateFlagNoDefer   // fire on the leading event; we debounce ourselves
                | kFSEventStreamCreateFlagWatchRoot // tell us if the config dir itself moves
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            eventStreamCallback,
            &context,
            resolvedPaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            configuration.eventLatency,
            flags
        ) else {
            // Balance `passRetained` — nothing took ownership.
            Unmanaged<EventSink>.fromOpaque(sinkPointer).release()
            throw StartError.streamCreationFailed
        }

        // Dispatch-queue scheduling instead of `FSEventStreamScheduleWithRunLoop`:
        // no run loop to keep alive, and teardown is a single `Invalidate`
        // rather than an unschedule-per-run-loop-mode dance.
        FSEventStreamSetDispatchQueue(stream, queue)

        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            Unmanaged<EventSink>.fromOpaque(sinkPointer).release()
            throw StartError.streamCreationFailed
        }

        active.isActive = true

        lock.lock()
        self.stream = stream
        self.sinkPointer = sinkPointer
        lock.unlock()
    }

    /// Stop watching and tear the stream down. No-op when not running.
    ///
    /// Pending debounced changes are discarded rather than delivered, so no
    /// callback arrives after this returns (modulo a batch already executing on
    /// the queue, which ``ActiveFlag`` suppresses).
    public func stop() {
        active.isActive = false

        lock.lock()
        let stream = self.stream
        let sinkPointer = self.sinkPointer
        self.stream = nil
        self.sinkPointer = nil
        lock.unlock()

        coalescer.cancelPending()

        guard let stream else { return }

        // Order matters. Stop halts delivery; Invalidate detaches from the
        // dispatch queue and guarantees no further callbacks (so it must come
        // before releasing the sink the callback dereferences); Release drops
        // our reference to the stream itself.
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)

        if let sinkPointer {
            Unmanaged<EventSink>.fromOpaque(sinkPointer).release()
        }
    }

    /// Deliver any debounced-but-undelivered changes right now. Useful for a
    /// manual "Refresh" that shouldn't wait out the debounce window.
    public func flushPendingChanges() {
        coalescer.flushNow()
    }

    /// Fully resolve `path` the way FSEvents does, so reported change paths and
    /// the watch root share a prefix.
    ///
    /// Uses `realpath(3)` rather than `URL.resolvingSymlinksInPath()`, which is
    /// *not* equivalent: Foundation strips the `/private` prefix, turning the
    /// real `/private/var/folders/…` back into `/var/folders/…`, while FSEvents
    /// reports the `/private` form. Matters for temp directories (and anything
    /// under `/tmp` or `/etc`); `~/.claude` is unaffected either way.
    ///
    /// Falls back to tilde-expansion plus standardizing when the path doesn't
    /// exist yet, since `realpath` requires an existing file.
    static func resolvedPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(expanded, &buffer) != nil {
            return String(cString: buffer)
        }
        return (expanded as NSString).standardizingPath
    }
}

// MARK: - C bridging

/// Holds what the C callback needs, and nothing else — see the comment at the
/// `passRetained` call site for why this isn't the watcher itself.
///
/// File-scope rather than nested so the `@convention(c)` callback below (which
/// can't live inside the type) can name it.
private final class EventSink {
    let coalescer: ChangeCoalescer
    init(coalescer: ChangeCoalescer) { self.coalescer = coalescer }
}

/// Free function rather than a closure so it can be `@convention(c)`.
private let eventStreamCallback: FSEventStreamCallback = {
    _, clientCallBackInfo, numEvents, eventPaths, eventFlags, _ in
    guard let clientCallBackInfo, numEvents > 0 else { return }

    // Unretained: `stop()` owns the retain and only releases it after
    // `FSEventStreamInvalidate`, which guarantees this callback is done.
    let sink = Unmanaged<EventSink>
        .fromOpaque(clientCallBackInfo)
        .takeUnretainedValue()

    // Without `kFSEventStreamCreateFlagUseCFTypes`, `eventPaths` is a plain
    // `char **` of `numEvents` C strings.
    let cPaths = eventPaths.bindMemory(to: UnsafePointer<CChar>?.self, capacity: numEvents)

    var changes: [FileChange] = []
    changes.reserveCapacity(numEvents)
    for index in 0..<numEvents {
        guard let cPath = cPaths[index] else { continue }
        changes.append(
            FileChange(
                path: String(cString: cPath),
                flags: FileChange.Flags(fsEventFlags: eventFlags[index])
            )
        )
    }

    sink.coalescer.record(changes)
}

extension FileChange.Flags {
    /// Map raw `kFSEventStreamEventFlag*` bits onto this package's small, stable
    /// vocabulary. Unknown bits are ignored; the several distinct
    /// "we lost events" bits all collapse to ``requiresRescan``.
    init(fsEventFlags raw: FSEventStreamEventFlags) {
        var flags: FileChange.Flags = []
        func contains(_ flag: Int) -> Bool { raw & FSEventStreamEventFlags(flag) != 0 }

        if contains(kFSEventStreamEventFlagItemCreated) { flags.insert(.created) }
        if contains(kFSEventStreamEventFlagItemModified) { flags.insert(.modified) }
        if contains(kFSEventStreamEventFlagItemRemoved) { flags.insert(.removed) }
        if contains(kFSEventStreamEventFlagItemRenamed) { flags.insert(.renamed) }
        if contains(kFSEventStreamEventFlagItemIsDir) { flags.insert(.isDirectory) }

        if contains(kFSEventStreamEventFlagItemInodeMetaMod)
            || contains(kFSEventStreamEventFlagItemChangeOwner)
            || contains(kFSEventStreamEventFlagItemXattrMod)
            || contains(kFSEventStreamEventFlagItemFinderInfoMod) {
            flags.insert(.metadata)
        }

        // Any of these means the per-path list is untrustworthy: the daemon
        // coalesced a subtree, dropped events under memory pressure, or the
        // watched root itself moved.
        if contains(kFSEventStreamEventFlagMustScanSubDirs)
            || contains(kFSEventStreamEventFlagUserDropped)
            || contains(kFSEventStreamEventFlagKernelDropped)
            || contains(kFSEventStreamEventFlagRootChanged)
            || contains(kFSEventStreamEventFlagMount)
            || contains(kFSEventStreamEventFlagUnmount) {
            flags.insert(.requiresRescan)
        }

        self = flags
    }
}

/// Minimal thread-safe boolean. Shared by the watcher and the coalescer's flush
/// closure so `stop()` can suppress an in-flight delivery without either side
/// referencing the other.
private final class ActiveFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isActive: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}
