import XCTest
@testable import ClaudeStatsCore

/// Every test writes into a per-test temp directory standing in for
/// `~/.claude` — the real config directory is never touched, read or written.
final class StatuslineHookInstallerTests: XCTestCase {
    private var directory: URL!
    private var settingsURL: URL!
    private var scriptURL: URL!
    private var cacheURL: URL!
    private var installer: StatuslineHookInstaller!

    private let bundledScript = Data("#!/usr/bin/env bash\necho v1\n".utf8)
    private let updatedBundledScript = Data("#!/usr/bin/env bash\necho v2\n".utf8)

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatuslineHookInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        settingsURL = directory.appendingPathComponent("settings.json")
        scriptURL = directory.appendingPathComponent(StatuslineHookInstaller.scriptFileName)
        // Own temp path, never the real default — `uninstall()` deletes
        // whatever's at `cacheURL`, and this suite must never touch the
        // real ~/Library/Application Support/ClaudeStats cache.
        cacheURL = directory.appendingPathComponent("statusline-cache.json")
        // Explicit, guaranteed-non-home directory: every test but the two
        // $HOME-relative-path tests below expects an absolute scriptURL path
        // in statusLine.command. Relying on the real home directory here
        // would flip that output (and break ~15 assertions at once) if
        // $TMPDIR/temp base ever falls under $HOME (e.g. containerized CI).
        installer = StatuslineHookInstaller(
            settingsURL: settingsURL,
            installedScriptURL: scriptURL,
            cacheURL: cacheURL,
            homeDirectory: URL(fileURLWithPath: "/nonexistent-home-for-tests")
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func write(_ json: String) throws {
        try Data(json.utf8).write(to: settingsURL)
    }

    private func readSettings() throws -> [String: Any] {
        let data = try Data(contentsOf: settingsURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func statusLineCommand(_ root: [String: Any]) -> String? {
        (root["statusLine"] as? [String: Any])?["command"] as? String
    }

    private func readSettingsText() throws -> String {
        String(decoding: try Data(contentsOf: settingsURL), as: UTF8.self)
    }

    /// Modeled on a real, hand-edited `~/.claude/settings.json`: deliberately
    /// out-of-alphabetical-order top-level keys, a nested `hooks` structure,
    /// and a value containing an unescaped `/` — everything a naive
    /// parse-into-dictionary-and-reserialize round-trip would reorder,
    /// reformat, or slash-escape.
    private let realisticSettings = """
    {
      "cleanupPeriodDays": 90,
      "permissions": {
        "allow": [
          "Bash(git branch *)"
        ]
      },
      "hooks": {
        "Stop": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "bash \\"$HOME/.claude/notify-banner.sh\\""
              }
            ]
          }
        ]
      },
      "statusLine": {
        "type": "command",
        "command": "bash \\"$HOME/.claude/claude-stats-statusline-cache.sh\\" bash \\"$HOME/.claude/statusline-command.sh\\""
      },
      "extraKnownMarketplaces": {
        "caveman": {
          "source": {
            "repo": "JuliusBrussee/caveman",
            "source": "github"
          }
        }
      },
      "theme": "auto"
    }
    """

    /// Same fixture, minus the `statusLine` key — for exercising a fresh
    /// install against otherwise-realistic content.
    private let realisticSettingsWithoutStatusLine = """
    {
      "cleanupPeriodDays": 90,
      "permissions": {
        "allow": [
          "Bash(git branch *)"
        ]
      },
      "hooks": {
        "Stop": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "bash \\"$HOME/.claude/notify-banner.sh\\""
              }
            ]
          }
        ]
      },
      "extraKnownMarketplaces": {
        "caveman": {
          "source": {
            "repo": "JuliusBrussee/caveman",
            "source": "github"
          }
        }
      },
      "theme": "auto"
    }
    """

    // MARK: - Detect

    func testDetectStateNotInstalledWhenNoSettingsFile() throws {
        XCTAssertEqual(try installer.detectState(), .notInstalled)
    }

    func testDetectStateNotInstalledWhenNoStatusLineKey() throws {
        try write(#"{"other": true}"#)
        XCTAssertEqual(try installer.detectState(), .notInstalled)
    }

    func testDetectStateNotInstalledWhenForeignStatusLine() throws {
        try write(#"{"statusLine": {"type": "command", "command": "bash \"$HOME/.claude/mine.sh\""}}"#)
        XCTAssertEqual(try installer.detectState(), .notInstalled)
    }

    /// The script's own header comment documents installing it by hand with a
    /// literal `$HOME`, e.g.
    /// `bash "$HOME/.claude/claude-stats-statusline-cache.sh"` — never
    /// containing `installedScriptURL`'s expanded absolute path. A hook set up
    /// that way must still be recognized as ours, or the "official" tier can
    /// be active while Settings claims nothing is installed.
    func testDetectStateRecognizesHandInstalledHomeStyleCommand() throws {
        try write(#"{"statusLine": {"type": "command", "command": "bash \"$HOME/.claude/claude-stats-statusline-cache.sh\""}}"#)
        XCTAssertEqual(try installer.detectState(), .installed(wrapping: nil))
    }

    func testDetectStateRecognizesHandInstalledHomeStyleCommandWrappingSomething() throws {
        try write(
            #"{"statusLine": {"type": "command", "command": "bash \"$HOME/.claude/claude-stats-statusline-cache.sh\" bash -c 'echo hi'"}}"#
        )
        XCTAssertEqual(try installer.detectState(), .installed(wrapping: "echo hi"))
    }

    func testDetectStateThrowsOnMalformedJSON() throws {
        try write("not json")
        XCTAssertThrowsError(try installer.detectState()) { error in
            XCTAssertEqual(error as? StatuslineHookInstaller.Error, .malformedSettings)
        }
    }

    func testDetectStateThrowsOnUnsupportedStatuslineType() throws {
        try write(#"{"statusLine": {"type": "future-thing", "command": "whatever"}}"#)
        XCTAssertThrowsError(try installer.detectState()) { error in
            XCTAssertEqual(error as? StatuslineHookInstaller.Error, .unsupportedStatuslineType("future-thing"))
        }
    }

    /// When a matched command's remainder doesn't match the exact `bash -c
    /// '...'` shape this installer generates (e.g. hand-edited or modified by
    /// another tool), the raw remainder is surfaced verbatim rather than
    /// guessed at.
    func testDetectStateSurfacesForeignWrapShapeVerbatim() throws {
        try write(#"{"statusLine": {"type": "command", "command": "bash \"$HOME/.claude/claude-stats-statusline-cache.sh\" && echo hi"}}"#)
        XCTAssertEqual(try installer.detectState(), .installed(wrapping: "&& echo hi"))
    }

    // MARK: - Install: fresh

    func testInstallWithNoExistingStatusLineWritesBareCommand() throws {
        let state = try installer.install(bundledScript: bundledScript)
        XCTAssertEqual(state, .installed(wrapping: nil))

        let root = try readSettings()
        XCTAssertEqual(statusLineCommand(root), "bash \"\(scriptURL.path)\"")
        XCTAssertEqual(try Data(contentsOf: scriptURL), bundledScript)
        XCTAssertEqual(try installer.detectState(), .installed(wrapping: nil))
    }

    func testInstallCreatesSettingsFileWhenAbsent() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path))
        _ = try installer.install(bundledScript: bundledScript)
        XCTAssertTrue(FileManager.default.fileExists(atPath: settingsURL.path))
    }

    /// Dotfile-managed setups often symlink `settings.json` elsewhere (e.g.
    /// into a synced folder) — `replaceItemAt` fails with "file doesn't
    /// exist" if asked to replace a symlink whose target lives in a
    /// different directory than the atomic-write temp file.
    func testInstallFollowsSymlinkedSettingsFileInsteadOfReplacingTheSymlink() throws {
        let realDir = directory.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let realSettingsURL = realDir.appendingPathComponent("settings.json")
        try Data(#"{"someOtherSetting": 42}"#.utf8).write(to: realSettingsURL)

        let symlinkURL = directory.appendingPathComponent("linked-settings.json")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: realSettingsURL)

        let symlinkedInstaller = StatuslineHookInstaller(
            settingsURL: symlinkURL,
            installedScriptURL: scriptURL,
            cacheURL: cacheURL,
            homeDirectory: URL(fileURLWithPath: "/nonexistent-home-for-tests")
        )
        let state = try symlinkedInstaller.install(bundledScript: bundledScript)
        XCTAssertEqual(state, .installed(wrapping: nil))

        // The symlink itself must survive — only its target's content changes.
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: symlinkURL.path),
            realSettingsURL.path
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: realSettingsURL)) as? [String: Any]
        )
        XCTAssertEqual(root["someOtherSetting"] as? Int, 42)
        XCTAssertEqual(statusLineCommand(root), "bash \"\(scriptURL.path)\"")
    }

    func testInstallPreservesUnrelatedSettingsKeys() throws {
        try write(#"{"someOtherSetting": 42}"#)
        _ = try installer.install(bundledScript: bundledScript)
        let root = try readSettings()
        XCTAssertEqual(root["someOtherSetting"] as? Int, 42)
    }

    func testInstallBacksUpExistingSettingsFile() throws {
        try write(#"{"statusLine": {"type": "command", "command": "echo hi"}}"#)
        _ = try installer.install(bundledScript: bundledScript)

        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("settings.json.bak-") }
        XCTAssertEqual(backups.count, 1)
    }

    func testBackupsDoNotCollideOnRapidSuccessiveMutations() throws {
        try write(#"{"statusLine": {"type": "command", "command": "echo hi"}}"#)
        _ = try installer.install(bundledScript: bundledScript)
        _ = try installer.install(bundledScript: updatedBundledScript)

        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("settings.json.bak-") }
        XCTAssertEqual(backups.count, 2, "each backup-worthy mutation should produce its own backup file")
    }

    func testInstallScriptIsExecutable() throws {
        _ = try installer.install(bundledScript: bundledScript)
        let attributes = try FileManager.default.attributesOfItem(atPath: scriptURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? Int)
        XCTAssertEqual(permissions & 0o100, 0o100, "owner-executable bit should be set")
    }

    // MARK: - Install: wrapping an existing statusline

    func testInstallWrapsExistingForeignCommand() throws {
        try write(#"{"statusLine": {"type": "command", "command": "bash \"$HOME/.claude/mine.sh\""}}"#)
        let state = try installer.install(bundledScript: bundledScript)
        XCTAssertEqual(state, .installed(wrapping: "bash \"$HOME/.claude/mine.sh\""))

        let root = try readSettings()
        XCTAssertEqual(
            statusLineCommand(root),
            "bash \"\(scriptURL.path)\" bash -c 'bash \"$HOME/.claude/mine.sh\"'"
        )
    }

    func testInstallEscapesSingleQuotesInWrappedCommand() throws {
        try write(#"{"statusLine": {"type": "command", "command": "echo 'hi there'"}}"#)
        _ = try installer.install(bundledScript: bundledScript)

        // Round-trips back through our own parser correctly...
        XCTAssertEqual(try installer.detectState(), .installed(wrapping: "echo 'hi there'"))

        // ...via a properly shell-escaped intermediate form.
        let root = try readSettings()
        XCTAssertEqual(
            statusLineCommand(root),
            "bash \"\(scriptURL.path)\" bash -c 'echo '\\''hi there'\\'''"
        )
    }

    // MARK: - Install: idempotency

    func testReinstallingDoesNotDoubleWrap() throws {
        try write(#"{"statusLine": {"type": "command", "command": "bash \"$HOME/.claude/mine.sh\""}}"#)
        _ = try installer.install(bundledScript: bundledScript)
        let secondState = try installer.install(bundledScript: updatedBundledScript)

        XCTAssertEqual(secondState, .installed(wrapping: "bash \"$HOME/.claude/mine.sh\""))
        let root = try readSettings()
        XCTAssertEqual(
            statusLineCommand(root),
            "bash \"\(scriptURL.path)\" bash -c 'bash \"$HOME/.claude/mine.sh\"'"
        )
    }

    func testReinstallingBareInstallStaysBare() throws {
        _ = try installer.install(bundledScript: bundledScript)
        let secondState = try installer.install(bundledScript: updatedBundledScript)
        XCTAssertEqual(secondState, .installed(wrapping: nil))
    }

    // MARK: - Stale detection

    func testDetectStateReportsStaleWhenScriptContentDiffers() throws {
        _ = try installer.install(bundledScript: bundledScript)
        XCTAssertEqual(
            try installer.detectState(bundledScript: updatedBundledScript),
            .installedStale(wrapping: nil)
        )
    }

    func testDetectStateNotStaleWhenScriptContentMatches() throws {
        _ = try installer.install(bundledScript: bundledScript)
        XCTAssertEqual(
            try installer.detectState(bundledScript: bundledScript),
            .installed(wrapping: nil)
        )
    }

    /// A missing script is the most stale state possible — reporting it as
    /// `.installed` would tell the user everything is fine while Claude Code
    /// silently runs a nonexistent script, with no repair path short of
    /// Remove-then-reinstall.
    func testDetectStateReportsStaleWhenScriptFileIsMissing() throws {
        _ = try installer.install(bundledScript: bundledScript)
        try FileManager.default.removeItem(at: scriptURL)
        XCTAssertEqual(
            try installer.detectState(bundledScript: bundledScript),
            .installedStale(wrapping: nil)
        )
    }

    func testUpdateScriptContentOnlyReplacesScriptWithoutTouchingSettings() throws {
        _ = try installer.install(bundledScript: bundledScript)
        let before = try readSettings()

        try installer.updateScriptContentOnly(bundledScript: updatedBundledScript)

        XCTAssertEqual(try Data(contentsOf: scriptURL), updatedBundledScript)
        let after = try readSettings()
        XCTAssertEqual(statusLineCommand(before), statusLineCommand(after))
        XCTAssertEqual(try installer.detectState(bundledScript: updatedBundledScript), .installed(wrapping: nil))
    }

    // MARK: - Preview

    func testPreviewInstallCommandMatchesActualInstall() throws {
        try write(#"{"statusLine": {"type": "command", "command": "bash \"$HOME/.claude/mine.sh\""}}"#)
        let preview = try installer.previewInstallCommand()
        XCTAssertEqual(preview.before, "bash \"$HOME/.claude/mine.sh\"")

        _ = try installer.install(bundledScript: bundledScript)
        let root = try readSettings()
        XCTAssertEqual(statusLineCommand(root), preview.after)
    }

    func testPreviewInstallCommandBeforeIsNilWhenNothingConfigured() throws {
        let preview = try installer.previewInstallCommand()
        XCTAssertNil(preview.before)
        XCTAssertEqual(preview.after, "bash \"\(scriptURL.path)\"")
    }

    func testPreviewUninstallNotInstalled() throws {
        XCTAssertEqual(try installer.previewUninstall(), .notInstalled)
    }

    func testPreviewUninstallWillRemoveStatusLineWhenBare() throws {
        _ = try installer.install(bundledScript: bundledScript)
        let current = try XCTUnwrap(statusLineCommand(readSettings()))
        XCTAssertEqual(try installer.previewUninstall(), .willRemoveStatusLine(current: current))
    }

    func testPreviewUninstallWillRestoreWrappedCommand() throws {
        try write(#"{"statusLine": {"type": "command", "command": "bash \"$HOME/.claude/mine.sh\""}}"#)
        _ = try installer.install(bundledScript: bundledScript)
        let current = try XCTUnwrap(statusLineCommand(readSettings()))
        XCTAssertEqual(
            try installer.previewUninstall(),
            .willRestore(current: current, original: "bash \"$HOME/.claude/mine.sh\"")
        )
    }

    // MARK: - $HOME-relative vs. absolute script path

    /// When the installed script actually lives under the home directory
    /// (the default `~/.claude` case), the generated command should read
    /// `$HOME`-relative — matching the style Claude Code's own hooks and this
    /// file's hand-written ones already use, and staying correct if
    /// `settings.json` is ever copied to another account/machine.
    func testInstallCommandUsesHomeRelativePathWhenScriptIsUnderHome() throws {
        // `directory` (from setUp) stands in for the home directory here, so
        // `scriptURL` is genuinely "under home" for this test.
        let installerUnderHome = StatuslineHookInstaller(
            settingsURL: settingsURL,
            installedScriptURL: scriptURL,
            cacheURL: cacheURL,
            homeDirectory: directory
        )
        let state = try installerUnderHome.install(bundledScript: bundledScript)
        XCTAssertEqual(state, .installed(wrapping: nil))

        let root = try readSettings()
        XCTAssertEqual(
            statusLineCommand(root),
            "bash \"$HOME/\(StatuslineHookInstaller.scriptFileName)\""
        )
    }

    /// When the script lives outside the home directory (e.g. a
    /// `$CLAUDE_CONFIG_DIR` override pointing elsewhere), `$HOME` wouldn't
    /// resolve there — the absolute path is required. This is also what every
    /// other test in this file exercises implicitly, since their
    /// `installedScriptURL` (a temp directory) isn't under the real home
    /// directory.
    func testInstallCommandUsesAbsolutePathWhenScriptIsNotUnderHome() throws {
        _ = try installer.install(bundledScript: bundledScript)
        let root = try readSettings()
        XCTAssertEqual(statusLineCommand(root), "bash \"\(scriptURL.path)\"")
    }

    // MARK: - Regression: reformatting/reordering the rest of the file

    /// The bug this guards: an earlier implementation parsed the whole file
    /// into `[String: Any]` and reserialized it with `.sortedKeys`, which
    /// alphabetized every top-level key and slash-escaped `JuliusBrussee/caveman`
    /// style values — a much bigger diff than "changed statusLine", on a file
    /// the user hand-edits and shares with other tools.
    func testUninstallDoesNotReorderOrReformatUnrelatedKeys() throws {
        try write(realisticSettings)
        try installer.uninstall()

        let text = try readSettingsText()
        XCTAssertTrue(text.hasPrefix("{\n  \"cleanupPeriodDays\": 90,"), "key order must be untouched:\n\(text)")
        XCTAssertTrue(text.contains("\"repo\": \"JuliusBrussee/caveman\""), "unrelated slashes must stay unescaped")
        XCTAssertFalse(text.contains("\\/"), "no slash-escaping should be introduced anywhere")
        // The fixture's statusLine wraps a real command — uninstall restores
        // that, it doesn't just delete the key.
        XCTAssertEqual(statusLineCommand(try readSettings()), "bash \"$HOME/.claude/statusline-command.sh\"")
    }

    func testInstallDoesNotReorderOrReformatUnrelatedKeys() throws {
        try write(realisticSettingsWithoutStatusLine)

        _ = try installer.install(bundledScript: bundledScript)

        let text = try readSettingsText()
        XCTAssertTrue(text.hasPrefix("{\n  \"cleanupPeriodDays\": 90,"), "key order must be untouched:\n\(text)")
        XCTAssertTrue(text.contains("\"repo\": \"JuliusBrussee/caveman\""), "unrelated slashes must stay unescaped")
        XCTAssertEqual(try installer.detectState(), .installed(wrapping: nil))
    }

    // MARK: - Uninstall

    func testUninstallBacksUpExistingSettingsFile() throws {
        _ = try installer.install(bundledScript: bundledScript)
        try installer.uninstall()

        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("settings.json.bak-") }
        XCTAssertEqual(backups.count, 1)
    }

    func testUninstallRemovesStatusLineKeyWhenBare() throws {
        _ = try installer.install(bundledScript: bundledScript)
        try installer.uninstall()

        let root = try readSettings()
        XCTAssertNil(root["statusLine"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: scriptURL.path))
    }

    func testUninstallRestoresWrappedOriginalCommand() throws {
        try write(#"{"statusLine": {"type": "command", "command": "bash \"$HOME/.claude/mine.sh\""}}"#)
        _ = try installer.install(bundledScript: bundledScript)
        try installer.uninstall()

        let root = try readSettings()
        XCTAssertEqual(statusLineCommand(root), "bash \"$HOME/.claude/mine.sh\"")
    }

    func testUninstallPreservesUnrelatedSettingsKeys() throws {
        try write(#"{"someOtherSetting": 42}"#)
        _ = try installer.install(bundledScript: bundledScript)
        try installer.uninstall()

        let root = try readSettings()
        XCTAssertEqual(root["someOtherSetting"] as? Int, 42)
    }

    func testUninstallIsNoOpWhenNotInstalled() throws {
        try write(#"{"statusLine": {"type": "command", "command": "bash \"$HOME/.claude/mine.sh\""}}"#)
        try installer.uninstall()

        let root = try readSettings()
        XCTAssertEqual(statusLineCommand(root), "bash \"$HOME/.claude/mine.sh\"")
    }

    /// Without this, `StatuslineCacheReader` would keep serving the last real
    /// capture as `.official` for up to its staleness threshold after the
    /// hook that used to refresh it is gone.
    func testUninstallDeletesTheStatuslineCacheFile() throws {
        try Data(#"{"rate_limits": {"five_hour": {"used_percentage": 10}}}"#.utf8).write(to: cacheURL)
        _ = try installer.install(bundledScript: bundledScript)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))

        try installer.uninstall()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func testUninstallIsNoOpOnTheCacheFileWhenNotInstalled() throws {
        try write(#"{"statusLine": {"type": "command", "command": "bash \"$HOME/.claude/mine.sh\""}}"#)
        try Data(#"{"rate_limits": {"five_hour": {"used_percentage": 10}}}"#.utf8).write(to: cacheURL)
        try installer.uninstall()

        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func testUninstallNoOpWhenNoSettingsFileAtAll() throws {
        XCTAssertNoThrow(try installer.uninstall())
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path))
    }
}
