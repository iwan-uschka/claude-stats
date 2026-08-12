import XCTest
@testable import ClaudeStatsCore

final class JSONObjectSurgeryTests: XCTestCase {
    // MARK: - Fixture modeled on a real ~/.claude/settings.json

    /// Deliberately mirrors the shape that broke the naive
    /// parse-into-dictionary-and-reserialize approach: nested arrays of
    /// strings with slashes, deeply nested `hooks`, an empty array, nested
    /// objects — anything a whole-file `JSONSerialization` round-trip would
    /// reorder, reformat, or slash-escape.
    private let realisticSettings = """
    {
      "cleanupPeriodDays": 90,
      "env": {
        "ENABLE_LSP_TOOL": "1"
      },
      "permissions": {
        "allow": [
          "Bash(git branch *)",
          "mcp__codegraph__*"
        ],
        "deny": [
          "Bash(rm -rf *)"
        ],
        "additionalDirectories": []
      },
      "model": "sonnet",
      "hooks": {
        "PreToolUse": [
          {
            "matcher": "Bash",
            "hooks": [
              {
                "type": "command",
                "command": "input=$(cat); result=$(echo \\"$input\\" | rtk hook claude)"
              }
            ]
          }
        ]
      },
      "statusLine": {
        "type": "command",
        "command": "bash \\"$HOME/.claude/statusline-command.sh\\""
      },
      "extraKnownMarketplaces": {
        "claude-code-warp": {
          "source": {
            "source": "github",
            "repo": "warpdotdev/claude-code-warp"
          }
        }
      },
      "theme": "auto"
    }
    """

    // MARK: - settingTopLevelValue: replace existing

    func testReplacesExistingStatusLinePreservingEverythingElseByteForByte() throws {
        let newValue = #"{"type": "command", "command": "bash \"/Users/x/.claude/claude-stats-statusline-cache.sh\""}"#
        let result = try JSONObjectSurgery.settingTopLevelValue(newValue, forKey: "statusLine", in: realisticSettings)

        // The new value is present...
        XCTAssertTrue(result.contains(#""statusLine": {"type": "command", "command": "bash \"/Users/x/.claude/claude-stats-statusline-cache.sh\""}"#))
        // ...nothing else moved: no alphabetical resort (permissions still
        // before hooks positionally as "model" precedes "hooks" in source),
        // no slash-escaping introduced into untouched values, unrelated keys
        // byte-identical.
        XCTAssertTrue(result.contains(#""repo": "warpdotdev/claude-code-warp""#))
        XCTAssertTrue(result.contains(#""cleanupPeriodDays": 90"#))
        XCTAssertTrue(result.contains(#""additionalDirectories": []"#))
        XCTAssertTrue(result.contains(#""model": "sonnet""#))

        // Round-trips as valid JSON with everything still present.
        let data = try XCTUnwrap(result.data(using: .utf8))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["theme"] as? String, "auto")
        XCTAssertNotNil(root["hooks"])
        XCTAssertNotNil(root["permissions"])
    }

    func testReplacingLeavesTextBeforeAndAfterUntouched() throws {
        let newValue = #"{"type": "command", "command": "x"}"#
        let result = try JSONObjectSurgery.settingTopLevelValue(newValue, forKey: "statusLine", in: realisticSettings)

        let prefix = realisticSettings.components(separatedBy: "\"statusLine\"").first!
        let suffix = realisticSettings.components(separatedBy: "\"theme\": \"auto\"").last!
        XCTAssertTrue(result.hasPrefix(prefix))
        XCTAssertTrue(result.hasSuffix("\"theme\": \"auto\"" + suffix))
    }

    // MARK: - settingTopLevelValue: insert fresh

    func testInsertsNewKeyWhenAbsentMatchingDetectedIndent() throws {
        let text = """
        {
          "foo": 1,
          "bar": 2
        }
        """
        let result = try JSONObjectSurgery.settingTopLevelValue(#"{"type": "command"}"#, forKey: "statusLine", in: text)
        XCTAssertEqual(
            result,
            """
            {
              "foo": 1,
              "bar": 2,
              "statusLine": {"type": "command"}
            }
            """
        )
    }

    func testInsertsIntoEmptyObject() throws {
        let result = try JSONObjectSurgery.settingTopLevelValue(#"{"type": "command"}"#, forKey: "statusLine", in: "{}")
        XCTAssertEqual(result, "{\n  \"statusLine\": {\"type\": \"command\"}\n}")
    }

    func testThrowsWhenRootIsNotAnObject() {
        XCTAssertThrowsError(try JSONObjectSurgery.settingTopLevelValue("1", forKey: "statusLine", in: "[1, 2, 3]")) { error in
            XCTAssertEqual(error as? JSONObjectSurgery.SurgeryError, .notAJSONObject)
        }
    }

    // MARK: - removingTopLevelValue

    func testRemovesMiddleMemberPreservingSiblings() throws {
        let text = """
        {
          "a": 1,
          "b": 2,
          "c": 3
        }
        """
        let result = try JSONObjectSurgery.removingTopLevelValue(forKey: "b", in: text)
        let data = try XCTUnwrap(result.data(using: .utf8))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root.count, 2)
        XCTAssertNil(root["b"])
        XCTAssertEqual(root["a"] as? Int, 1)
        XCTAssertEqual(root["c"] as? Int, 3)
    }

    func testRemovesLastMemberAbsorbingPrecedingComma() throws {
        let text = """
        {
          "a": 1,
          "statusLine": {"type": "command"}
        }
        """
        let result = try JSONObjectSurgery.removingTopLevelValue(forKey: "statusLine", in: text)
        XCTAssertEqual(
            result,
            """
            {
              "a": 1
            }
            """
        )
    }

    func testRemovesFirstMemberAbsorbingFollowingComma() throws {
        let text = """
        {
          "statusLine": {"type": "command"},
          "a": 1
        }
        """
        let result = try JSONObjectSurgery.removingTopLevelValue(forKey: "statusLine", in: text)
        let data = try XCTUnwrap(result.data(using: .utf8))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root.count, 1)
        XCTAssertEqual(root["a"] as? Int, 1)
    }

    func testRemovesSoleMemberLeavingEmptyObject() throws {
        let result = try JSONObjectSurgery.removingTopLevelValue(forKey: "statusLine", in: "{\"statusLine\": {}}")
        let data = try XCTUnwrap(result.data(using: .utf8))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(root.isEmpty)
    }

    func testRemovingAbsentKeyIsANoOp() throws {
        let text = """
        {
          "a": 1
        }
        """
        XCTAssertEqual(try JSONObjectSurgery.removingTopLevelValue(forKey: "statusLine", in: text), text)
    }

    func testRemovingFromRealisticFixturePreservesUnrelatedNestedStructures() throws {
        let result = try JSONObjectSurgery.removingTopLevelValue(forKey: "statusLine", in: realisticSettings)
        let data = try XCTUnwrap(result.data(using: .utf8))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(root["statusLine"])
        XCTAssertNotNil(root["hooks"])
        XCTAssertNotNil(root["permissions"])
        XCTAssertTrue(result.contains(#""repo": "warpdotdev/claude-code-warp""#), "unrelated slashes must stay unescaped")
    }

    // MARK: - Values containing braces/commas/escaped quotes in strings

    func testSkipsOverStringValuesContainingStructuralCharacters() throws {
        let text = """
        {
          "tricky": "a { b [ c , d } e ] f \\"g\\" h",
          "target": 1
        }
        """
        let result = try JSONObjectSurgery.removingTopLevelValue(forKey: "target", in: text)
        let data = try XCTUnwrap(result.data(using: .utf8))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(root["target"])
        XCTAssertEqual(root["tricky"] as? String, "a { b [ c , d } e ] f \"g\" h")
    }
}
