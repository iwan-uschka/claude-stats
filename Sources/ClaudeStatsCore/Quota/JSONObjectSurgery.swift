import Foundation

/// Replaces or removes a single top-level member of a JSON object's raw text,
/// leaving every other byte — indentation, key order, quote/escaping style,
/// unrelated nested structures — untouched.
///
/// `JSONSerialization` round-trips (parse the whole file into a dictionary,
/// reserialize it) can't do this: `Dictionary` has no ordering, so writing one
/// back out reshuffles every key, and `JSONSerialization`'s default writer
/// escapes `/` as `\/`. For a file like `~/.claude/settings.json` — hand-edited,
/// shared with other tools, full of the user's own formatting choices — that's
/// a much bigger footprint than "changed the statusline hook". This type does
/// textual surgery instead: find the exact span of one top-level key's
/// `"key": value` (string/bracket/brace-aware, so it correctly skips over
/// deeply nested sibling values like `hooks` or `permissions`), and splice
/// only that span.
enum JSONObjectSurgery {
    enum SurgeryError: Error, Equatable {
        /// The text isn't a JSON object at its root (or isn't valid JSON at
        /// all) — nothing safe to splice into.
        case notAJSONObject
    }

    /// Replaces the top-level member `key` with `valueJSON` (a complete,
    /// already-valid JSON value), inserting it as a new member if `key` isn't
    /// present yet. New members are appended matching the indentation the
    /// file's other members already use.
    static func settingTopLevelValue(_ valueJSON: String, forKey key: String, in text: String) throws -> String {
        guard let interior = rootObjectInterior(of: text) else { throw SurgeryError.notAJSONObject }
        let existingMembers = members(of: text, in: interior)
        let newMemberText = "\"\(key)\": \(valueJSON)"

        if let existing = existingMembers.first(where: { $0.key == key }) {
            var result = text
            result.replaceSubrange(existing.range, with: newMemberText)
            return result
        }

        var result = text
        if let last = existingMembers.last {
            let prefix = memberIndentPrefix(of: text, interior: interior, firstMember: existingMembers[0])
            result.insert(contentsOf: "," + prefix + newMemberText, at: last.range.upperBound)
        } else {
            result.replaceSubrange(interior, with: "\n  " + newMemberText + "\n")
        }
        return result
    }

    /// Removes the top-level member `key` entirely (no-op if it isn't
    /// present).
    static func removingTopLevelValue(forKey key: String, in text: String) throws -> String {
        guard let interior = rootObjectInterior(of: text) else { throw SurgeryError.notAJSONObject }
        let existingMembers = members(of: text, in: interior)
        guard let index = existingMembers.firstIndex(where: { $0.key == key }) else { return text }
        let existing = existingMembers[index]

        var result = text
        if existingMembers.count == 1 {
            result.replaceSubrange(interior, with: "")
        } else if index < existingMembers.count - 1 {
            // Not the last member: absorb the separating comma/whitespace that
            // follows it, up to the next member's key.
            let next = existingMembers[index + 1]
            result.replaceSubrange(existing.range.lowerBound..<next.range.lowerBound, with: "")
        } else {
            // Last member: absorb the comma/whitespace that precedes it,
            // trailing back from the previous member's value.
            let previous = existingMembers[index - 1]
            result.replaceSubrange(previous.range.upperBound..<existing.range.upperBound, with: "")
        }
        return result
    }

    // MARK: - Scanning

    private struct Member {
        let key: String
        /// Span of `"key": value` — no surrounding comma or whitespace.
        let range: Range<String.Index>
    }

    /// The range strictly between the root object's `{` and its matching `}`,
    /// or `nil` if the text's root isn't a JSON object.
    private static func rootObjectInterior(of text: String) -> Range<String.Index>? {
        var idx = text.startIndex
        while idx < text.endIndex, text[idx].isWhitespace { idx = text.index(after: idx) }
        guard idx < text.endIndex, text[idx] == "{" else { return nil }
        guard let closeIdx = matchingBracketIndex(in: text, openIndex: idx) else { return nil }
        return text.index(after: idx)..<closeIdx
    }

    /// Given the index of an opening `{`/`[`, finds its matching closer,
    /// scanning string-aware (so brackets inside string values don't count).
    private static func matchingBracketIndex(in text: String, openIndex: String.Index) -> String.Index? {
        var depth = 0
        var idx = openIndex
        var inString = false
        var escaped = false
        while idx < text.endIndex {
            let c = text[idx]
            if inString {
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
            } else if c == "\"" {
                inString = true
            } else if c == "{" || c == "[" {
                depth += 1
            } else if c == "}" || c == "]" {
                depth -= 1
                if depth == 0 { return idx }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    /// Splits an object's interior into its top-level `"key": value` members,
    /// each spanning from the key's opening quote to the end of its value
    /// (comma separators and surrounding whitespace excluded).
    private static func members(of text: String, in interior: Range<String.Index>) -> [Member] {
        var result: [Member] = []
        var idx = interior.lowerBound

        while true {
            while idx < interior.upperBound, text[idx].isWhitespace || text[idx] == "," {
                idx = text.index(after: idx)
            }
            guard idx < interior.upperBound, text[idx] == "\"" else { break }

            let keyStart = idx
            guard let keyEnd = stringLiteralEnd(in: text, quoteIndex: idx, limit: interior.upperBound) else { break }
            idx = keyEnd
            let key = decodeStringLiteral(String(text[keyStart..<keyEnd]))

            while idx < interior.upperBound, text[idx].isWhitespace { idx = text.index(after: idx) }
            guard idx < interior.upperBound, text[idx] == ":" else { break }
            idx = text.index(after: idx)
            while idx < interior.upperBound, text[idx].isWhitespace { idx = text.index(after: idx) }
            guard idx < interior.upperBound else { break }

            let valueStart = idx
            let valueEnd: String.Index
            let c = text[idx]
            if c == "{" || c == "[" {
                guard let close = matchingBracketIndex(in: text, openIndex: idx) else { break }
                valueEnd = text.index(after: close)
            } else if c == "\"" {
                guard let end = stringLiteralEnd(in: text, quoteIndex: idx, limit: interior.upperBound) else { break }
                valueEnd = end
            } else {
                var scan = idx
                while scan < interior.upperBound, text[scan] != "," {
                    scan = text.index(after: scan)
                }
                var end = scan
                while end > valueStart, text[text.index(before: end)].isWhitespace {
                    end = text.index(before: end)
                }
                valueEnd = end
            }

            result.append(Member(key: key, range: keyStart..<valueEnd))
            idx = valueEnd
        }
        return result
    }

    /// Index just past the closing quote of the string literal starting at
    /// `quoteIndex`, escape-aware.
    private static func stringLiteralEnd(in text: String, quoteIndex: String.Index, limit: String.Index) -> String.Index? {
        var idx = text.index(after: quoteIndex)
        while idx < limit {
            if text[idx] == "\\" {
                idx = text.index(idx, offsetBy: 2, limitedBy: limit) ?? limit
                continue
            }
            if text[idx] == "\"" { return text.index(after: idx) }
            idx = text.index(after: idx)
        }
        return nil
    }

    /// Decodes a quoted JSON string literal (e.g. `"foo\"bar"`) to its Swift
    /// string value, via `JSONSerialization` rather than hand-rolling unicode
    /// escape handling.
    private static func decodeStringLiteral(_ literal: String) -> String {
        guard let data = "[\(literal)]".data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [String],
              let value = array.first
        else { return literal }
        return value
    }

    /// The whitespace (including its leading newline) between the object's
    /// `{` and its first member's key — reused so a newly-inserted member
    /// lines up with its siblings' indentation. Falls back to two spaces if
    /// that whitespace doesn't actually contain a newline (a single-line
    /// object).
    private static func memberIndentPrefix(of text: String, interior: Range<String.Index>, firstMember: Member) -> String {
        let whitespace = text[interior.lowerBound..<firstMember.range.lowerBound]
        return whitespace.contains("\n") ? String(whitespace) : "\n  "
    }
}
