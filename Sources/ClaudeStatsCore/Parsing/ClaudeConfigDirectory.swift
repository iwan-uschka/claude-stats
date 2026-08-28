import Foundation

/// Locates Claude Code's config directory — the root of the session-log tree
/// (`<config dir>/projects/<escaped-cwd>/<session-uuid>.jsonl`).
///
/// Resolution order:
/// 1. `$CLAUDE_CONFIG_DIR`, when set to a non-empty value (tilde expanded).
/// 2. `~/.claude`.
///
/// `~/.config/claude` is deliberately *not* consulted: current Claude Code
/// installs use `~/.claude`, and honouring a second default would silently pick
/// a stale tree.
public enum ClaudeConfigDirectory {
    /// Environment variable that overrides the default location.
    public static let environmentVariable = "CLAUDE_CONFIG_DIR"

    /// The resolved config directory.
    ///
    /// - Throws: ``ClaudeStatsError/configDirectoryNotFound`` when the resolved
    ///   path doesn't exist or isn't a directory.
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> URL {
        let url = candidate(environment: environment, homeDirectory: homeDirectory)
        guard isDirectory(url, fileManager: fileManager) else {
            throw ClaudeStatsError.configDirectoryNotFound
        }
        return url.standardizedFileURL
    }

    /// Where ``resolve(environment:homeDirectory:fileManager:)`` will look,
    /// without checking whether it exists. Useful for diagnostics and for the
    /// Settings pane.
    public static func candidate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = environment[environmentVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(".claude", isDirectory: true)
    }

    /// File name of Claude Code's own state file — a *sibling* of the config
    /// directory, not a member of it.
    public static let stateFileName = ".claude.json"

    /// Where Claude Code's own state file might live, in probe order.
    ///
    /// The docs say `$CLAUDE_CONFIG_DIR` relocates "every `~/.claude` path", but
    /// `.claude.json` is a *sibling* of `~/.claude`, not inside it — whether the
    /// override moves it too is undetermined, so probe both. First one that
    /// opens wins (see ``ClaudeStateFile``).
    ///
    /// Order: `$CLAUDE_CONFIG_DIR/.claude.json` (only when the variable is set
    /// to a non-blank value, matching
    /// ``candidate(environment:homeDirectory:)``), then `~/.claude.json`.
    public static func stateFileCandidates(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        var candidates: [URL] = []
        if let override = environment[environmentVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty {
            candidates.append(
                URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
                    .appendingPathComponent(stateFileName, isDirectory: false)
            )
        }
        candidates.append(homeDirectory.appendingPathComponent(stateFileName, isDirectory: false))
        return candidates
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        return isDir.boolValue
    }
}
