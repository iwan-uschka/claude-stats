import Foundation

/// Automates wiring ClaudeStats' `statusLine` cache script into the user's
/// real `~/.claude/settings.json`, as an alternative to the fully-manual
/// steps documented in `claude-stats-statusline-cache.sh`'s header comment.
///
/// This type never touches disk on its own initiative — every mutating call
/// (``install(bundledScript:)``, ``uninstall()``, ``updateScriptContentOnly(bundledScript:)``)
/// is expected to be gated behind an explicit user confirmation in the UI
/// layer, since it edits a config file Claude Code itself reads and that the
/// user may already have customized.
///
/// ## Wrapping an existing statusline
///
/// `statusLine` is a single hook slot, not a list. If the user already has one
/// configured, blindly overwriting it would silently kill their setup. Instead
/// the installed command wraps the original inside a `bash -c '<original>'`
/// argument — the cache script's own `"$@"` delegation (see its header
/// comment's "Case B") re-feeds it the same stdin and passes its stdout
/// through untouched. Wrapping via `bash -c` on the raw original string, rather
/// than trying to tokenize it into argv pieces, is what lets this handle an
/// arbitrary existing command without understanding its shape.
public struct StatuslineHookInstaller {
    /// Result of inspecting the current `statusLine` configuration.
    public enum State: Equatable {
        /// No hook of ours is configured.
        case notInstalled
        /// Our script is wired up. `wrapping` is the original command it now
        /// delegates to, if one was found and wrapped at install time.
        case installed(wrapping: String?)
        /// Our script is wired up, but the on-disk copy's content differs from
        /// the bundled resource passed to ``detectState(bundledScript:)`` —
        /// offer a content-only update.
        case installedStale(wrapping: String?)
    }

    public enum Error: Swift.Error, Equatable {
        /// `settings.json` exists but isn't valid JSON / isn't a JSON object.
        case malformedSettings
        /// `statusLine.type` is something other than `"command"` — a hook
        /// shape this installer doesn't understand. Left untouched rather
        /// than guessed at.
        case unsupportedStatuslineType(String)
    }

    /// File name the script is installed under, alongside `settings.json`.
    public static let scriptFileName = "claude-stats-statusline-cache.sh"

    private static let statusLineKey = "statusLine"
    private static let typeKey = "type"
    private static let commandKey = "command"
    private static let commandTypeValue = "command"
    private static let wrapPrefix = "bash -c '"
    private static let wrapSuffix = "'"

    public let settingsURL: URL
    public let installedScriptURL: URL
    /// `FileManager` isn't marked `Sendable`, but `.default` and other
    /// instances are documented thread-safe.
    nonisolated(unsafe) private let fileManager: FileManager
    private let homeDirectory: URL

    public init(
        settingsURL: URL,
        installedScriptURL: URL,
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.settingsURL = settingsURL
        self.installedScriptURL = installedScriptURL
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
    }

    /// `~/.claude/settings.json` and `~/.claude/claude-stats-statusline-cache.sh`
    /// (honoring `$CLAUDE_CONFIG_DIR`, like the rest of the data layer) — `nil`
    /// if the config directory can't be resolved at all.
    public static func standard(fileManager: FileManager = .default) -> StatuslineHookInstaller? {
        guard let configDir = try? ClaudeConfigDirectory.resolve(fileManager: fileManager) else {
            return nil
        }
        return StatuslineHookInstaller(
            settingsURL: configDir.appendingPathComponent("settings.json", isDirectory: false),
            installedScriptURL: configDir.appendingPathComponent(scriptFileName, isDirectory: false),
            fileManager: fileManager
        )
    }

    // MARK: - Detect

    /// Inspects `settings.json` (and, if given, compares the installed
    /// script's bytes against `bundledScript`) without changing anything.
    public func detectState(bundledScript: Data? = nil) throws -> State {
        guard let command = try currentCommand() else { return .notInstalled }
        guard let wrapping = wrappedOriginal(from: command) else { return .notInstalled }

        if let bundledScript, isScriptStale(against: bundledScript) {
            return .installedStale(wrapping: wrapping)
        }
        return .installed(wrapping: wrapping)
    }

    // MARK: - Install

    /// What ``install(bundledScript:)`` would write `statusLine.command` as,
    /// without touching disk — for a before/after confirmation dialog. `before`
    /// is the current raw command (`nil` if there's no `statusLine` at all).
    public func previewInstallCommand() throws -> (before: String?, after: String) {
        let existingCommand = try currentCommand()
        let commandToWrap = resolvedCommandToWrap(existingCommand: existingCommand)
        return (existingCommand, commandLine(wrapping: commandToWrap))
    }

    /// Copies `bundledScript` to ``installedScriptURL`` and points
    /// `statusLine` at it, wrapping any existing hook command it finds.
    /// Backs up `settings.json` first (best-effort — a failed backup doesn't
    /// block the install). Only the `statusLine` member's text is touched —
    /// see ``JSONObjectSurgery``.
    @discardableResult
    public func install(bundledScript: Data) throws -> State {
        try writeScript(bundledScript)

        let existingCommand = try currentCommand()
        let commandToWrap = resolvedCommandToWrap(existingCommand: existingCommand)

        try backupSettingsIfPresent()

        let newCommand = commandLine(wrapping: commandToWrap)
        try spliceStatusLine(valueJSON: statusLineValueJSON(command: newCommand))

        return .installed(wrapping: commandToWrap)
    }

    /// If we're already installed, this is what our *previous* install was
    /// wrapping (`nil` if it was bare) rather than the raw current command —
    /// otherwise a second `install()` call would wrap our own invocation a
    /// second time.
    private func resolvedCommandToWrap(existingCommand: String?) -> String? {
        guard let existingCommand else { return nil }
        if let wrapping = wrappedOriginal(from: existingCommand) {
            return wrapping
        }
        return existingCommand
    }

    /// Replaces the on-disk script with `bundledScript` without touching
    /// `settings.json` — for the ``State/installedStale(wrapping:)`` case.
    public func updateScriptContentOnly(bundledScript: Data) throws {
        try writeScript(bundledScript)
    }

    // MARK: - Uninstall

    /// What ``uninstall()`` would do, without touching disk — for a
    /// before/after confirmation dialog.
    public enum UninstallPreview: Equatable {
        /// We're not installed; ``uninstall()`` would be a no-op.
        case notInstalled
        /// `statusLine` would be removed entirely.
        case willRemoveStatusLine
        /// `statusLine.command` would revert to this original command.
        case willRestore(String)
    }

    public func previewUninstall() throws -> UninstallPreview {
        guard let command = try currentCommand(),
              let wrapping = wrappedOriginal(from: command)
        else { return .notInstalled }
        guard let wrapping else { return .willRemoveStatusLine }
        return .willRestore(wrapping)
    }

    /// Restores `statusLine` to whatever our script was wrapping (or removes
    /// the key entirely if it wasn't wrapping anything), and deletes the
    /// installed script. No-op if we're not currently installed. Only the
    /// `statusLine` member's text is touched — see ``JSONObjectSurgery``.
    public func uninstall() throws {
        guard let command = try currentCommand(),
              let wrapping = wrappedOriginal(from: command)
        else { return }

        try backupSettingsIfPresent()

        if let wrapping {
            try spliceStatusLine(valueJSON: statusLineValueJSON(command: wrapping))
        } else {
            let text = readSettingsText()
            let newText = try mappingSurgeryError { try JSONObjectSurgery.removingTopLevelValue(forKey: Self.statusLineKey, in: text) }
            try writeSettingsText(newText)
        }

        try? fileManager.removeItem(at: installedScriptURL)
    }

    // MARK: - Command line construction

    private func commandLine(wrapping existingCommand: String?) -> String {
        let scriptInvocation = "bash \"\(scriptPathForCommandLine)\""
        guard let existingCommand else { return scriptInvocation }
        return "\(scriptInvocation) \(Self.wrapPrefix)\(escape(existingCommand))\(Self.wrapSuffix)"
    }

    /// `$HOME`-relative when the script actually lives under the home
    /// directory (matching the `$HOME`-based style Claude Code's own
    /// documentation and this file's other hand-written hooks use — portable
    /// across accounts/machines), falling back to the absolute path only when
    /// it doesn't — e.g. a `$CLAUDE_CONFIG_DIR` override pointing somewhere
    /// `$HOME` wouldn't resolve to.
    private var scriptPathForCommandLine: String {
        let homePrefix = homeDirectory.standardizedFileURL.path + "/"
        let scriptPath = installedScriptURL.standardizedFileURL.path
        guard scriptPath.hasPrefix(homePrefix) else { return scriptPath }
        return "$HOME/" + scriptPath.dropFirst(homePrefix.count)
    }

    /// `'` -> `'\''`, the standard single-quote escape for embedding a string
    /// inside a single-quoted shell argument.
    private func escape(_ original: String) -> String {
        original.replacingOccurrences(of: "'", with: "'\\''")
    }

    /// `nil` when `command` isn't ours at all. `.some(nil)` when it's ours and
    /// bare (no delegate). `.some(.some(original))` when it's ours and
    /// wrapping something — modeled here as `String??` collapsed to `String?`
    /// by the caller checking `wrappedOriginal(from:) != nil` first.
    ///
    /// Matches by script *file name*, not the full quoted invocation
    /// ``commandLine(wrapping:)`` generates — the script's own header comment
    /// documents installing it with a literal `$HOME` (e.g.
    /// `bash "$HOME/.claude/claude-stats-statusline-cache.sh"`), which never
    /// contains ``installedScriptURL``'s expanded absolute path, so a
    /// hand-installed hook must still be recognized as ours.
    private func wrappedOriginal(from command: String) -> String?? {
        guard let nameRange = command.range(of: Self.scriptFileName) else { return nil }

        var tailStart = nameRange.upperBound
        if tailStart < command.endIndex, command[tailStart] == "\"" || command[tailStart] == "'" {
            tailStart = command.index(after: tailStart)
        }

        let remainder = command[tailStart...].trimmingCharacters(in: .whitespaces)
        guard !remainder.isEmpty else { return .some(nil) }

        guard remainder.hasPrefix(Self.wrapPrefix), remainder.hasSuffix(Self.wrapSuffix),
              remainder.count >= Self.wrapPrefix.count + Self.wrapSuffix.count
        else {
            // Wrapped in some shape we didn't generate — surface it as the raw
            // remainder rather than guessing at unescaping.
            return .some(remainder)
        }

        let inner = remainder.dropFirst(Self.wrapPrefix.count).dropLast(Self.wrapSuffix.count)
        return .some(inner.replacingOccurrences(of: "'\\''", with: "'"))
    }

    // MARK: - settings.json I/O

    /// The current `statusLine.command`, if `statusLine.type == "command"`.
    /// `nil` if there's no `statusLine` at all.
    /// - Throws: ``Error/malformedSettings`` if the file exists but isn't a
    ///   JSON object; ``Error/unsupportedStatuslineType(_:)`` if `statusLine`
    ///   is configured with a type this installer doesn't recognize.
    private func currentCommand() throws -> String? {
        guard let root = try readSettingsObject() else { return nil }
        guard let statusLine = root[Self.statusLineKey] as? [String: Any] else { return nil }

        let type = statusLine[Self.typeKey] as? String ?? Self.commandTypeValue
        guard type == Self.commandTypeValue else {
            throw Error.unsupportedStatuslineType(type)
        }
        return statusLine[Self.commandKey] as? String
    }

    private func readSettingsObject() throws -> [String: Any]? {
        guard let data = fileManager.contents(atPath: settingsURL.path) else { return nil }
        guard !data.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else {
            throw Error.malformedSettings
        }
        return root
    }

    /// Raw text of `settings.json`, or `"{}"` if it doesn't exist yet (so
    /// ``JSONObjectSurgery`` has a root object to insert into).
    private func readSettingsText() -> String {
        guard let data = fileManager.contents(atPath: settingsURL.path),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    /// Atomic write: temp file in the same directory, then `replaceItemAt`, so
    /// a crash mid-write never leaves `settings.json` truncated.
    private func writeSettingsText(_ text: String) throws {
        let tempURL = settingsURL.deletingLastPathComponent()
            .appendingPathComponent(".\(settingsURL.lastPathComponent).\(UUID().uuidString).tmp")
        try Data(text.utf8).write(to: tempURL, options: .atomic)
        _ = try fileManager.replaceItemAt(settingsURL, withItemAt: tempURL)
    }

    /// Replaces (or inserts) the `statusLine` member via ``JSONObjectSurgery``
    /// — every other key in `settings.json` stays byte-for-byte untouched.
    private func spliceStatusLine(valueJSON: String) throws {
        let text = readSettingsText()
        let newText = try mappingSurgeryError {
            try JSONObjectSurgery.settingTopLevelValue(valueJSON, forKey: Self.statusLineKey, in: text)
        }
        try writeSettingsText(newText)
    }

    /// `{"type": "command", "command": "<command, JSON-escaped>"}`, single
    /// line, slashes left unescaped (`JSONSerialization`'s default escapes `/`
    /// as `\/`, which would be a jarring difference from the rest of a
    /// hand-written `settings.json` for a value that's mostly a file path).
    private func statusLineValueJSON(command: String) throws -> String {
        let object: [String: Any] = [Self.typeKey: Self.commandTypeValue, Self.commandKey: command]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// `JSONObjectSurgery.SurgeryError` folded into this type's own `Error` so
    /// callers only ever see one error type.
    private func mappingSurgeryError<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch is JSONObjectSurgery.SurgeryError {
            throw Error.malformedSettings
        }
    }

    private func backupSettingsIfPresent() throws {
        guard fileManager.fileExists(atPath: settingsURL.path) else { return }
        let backupURL = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("\(settingsURL.lastPathComponent).bak-\(Int(Date().timeIntervalSince1970))")
        // Best-effort: a failed backup shouldn't block the install itself.
        try? fileManager.copyItem(at: settingsURL, to: backupURL)
    }

    private func writeScript(_ bundledScript: Data) throws {
        let directory = installedScriptURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: installedScriptURL.path) {
            try fileManager.removeItem(at: installedScriptURL)
        }
        fileManager.createFile(atPath: installedScriptURL.path, contents: bundledScript)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installedScriptURL.path)
    }

    private func isScriptStale(against bundledScript: Data) -> Bool {
        guard let installed = fileManager.contents(atPath: installedScriptURL.path) else { return false }
        return installed != bundledScript
    }
}
