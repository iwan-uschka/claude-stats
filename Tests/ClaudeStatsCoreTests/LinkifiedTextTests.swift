import XCTest

@testable import ClaudeStatsCore

/// Pure string work — nothing here touches the filesystem.
final class LinkifiedTextTests: XCTestCase {
    /// The exact string cached on a real machine.
    private let realNotice = "+50% weekly limits promo through Aug 31 · clau.de/cc-50-promo"

    /// `prefix + linkLabel + suffix` must always reconstruct `plainText`, or the
    /// popover renders something the accessibility label and tooltip disagree with.
    private func assertRoundTrips(
        _ text: LinkifiedText,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            text.plainText,
            text.prefix + (text.linkLabel ?? "") + text.suffix,
            file: file,
            line: line
        )
    }

    private func linkify(
        _ raw: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> LinkifiedText {
        let result = try XCTUnwrap(LinkifiedText.linkify(raw), file: file, line: line)
        assertRoundTrips(result, file: file, line: line)
        return result
    }

    // MARK: - The real string

    func testRealPromoStringSplitsAroundItsBareURL() throws {
        let text = try linkify(realNotice)

        XCTAssertEqual(text.prefix, "+50% weekly limits promo through Aug 31 · ")
        XCTAssertEqual(text.linkLabel, "clau.de/cc-50-promo")
        XCTAssertEqual(text.linkURL?.absoluteString, "https://clau.de/cc-50-promo")
        XCTAssertEqual(text.suffix, "")
        XCTAssertEqual(text.plainText, realNotice)
    }

    // MARK: - Plain degradation

    func testTextWithoutAnyURLDegradesToPlain() throws {
        let text = try linkify("+50% weekly limits promo through Aug 31")

        XCTAssertNil(text.linkLabel)
        XCTAssertNil(text.linkURL)
        XCTAssertEqual(text.prefix, "+50% weekly limits promo through Aug 31")
        XCTAssertEqual(text.suffix, "")
    }

    /// Bare words are syntactically valid hosts — nothing in a sentence of
    /// ordinary prose may become clickable.
    func testOrdinaryWordsAreNotLinkified() throws {
        for raw in ["see promo for details", "version 3.5 is out", "e.g. nothing here"] {
            let text = try linkify(raw)
            XCTAssertNil(text.linkLabel, "unexpectedly linkified: \(raw)")
        }
    }

    // MARK: - Schemes

    func testExplicitHTTPSIsKeptAndLabelPreserved() throws {
        let text = try linkify("go to https://clau.de/x now")

        XCTAssertEqual(text.prefix, "go to ")
        XCTAssertEqual(text.linkLabel, "https://clau.de/x")
        XCTAssertEqual(text.linkURL?.absoluteString, "https://clau.de/x")
        XCTAssertEqual(text.suffix, " now")
    }

    func testHTTPIsUpgradedButTheLabelStillReadsAsWritten() throws {
        let text = try linkify("go to http://clau.de/x now")

        XCTAssertEqual(text.linkLabel, "http://clau.de/x")
        XCTAssertEqual(text.linkURL?.absoluteString, "https://clau.de/x")
    }

    func testNonHTTPSchemesAreRejectedOutrightRatherThanPrefixed() throws {
        for raw in [
            "javascript:alert(1)",
            "data:text/html;base64,AAAA",
            "file:///etc/passwd",
            "about:blank",
            "mailto:someone@clau.de",
        ] {
            let text = try linkify(raw)
            XCTAssertNil(text.linkLabel, "unexpectedly linkified: \(raw)")
            XCTAssertNil(text.linkURL, "unexpectedly linkified: \(raw)")
        }
    }

    // MARK: - Enclosing punctuation

    func testEnclosingPunctuationStaysOutOfTheLabel() throws {
        let trailingStop = try linkify("… clau.de/x.")
        XCTAssertEqual(trailingStop.prefix, "… ")
        XCTAssertEqual(trailingStop.linkLabel, "clau.de/x")
        XCTAssertEqual(trailingStop.suffix, ".")

        let parenthesised = try linkify("promo (clau.de/x) ends soon")
        XCTAssertEqual(parenthesised.prefix, "promo (")
        XCTAssertEqual(parenthesised.linkLabel, "clau.de/x")
        XCTAssertEqual(parenthesised.suffix, ") ends soon")

        let comma = try linkify("clau.de/x, and more")
        XCTAssertEqual(comma.prefix, "")
        XCTAssertEqual(comma.linkLabel, "clau.de/x")
        XCTAssertEqual(comma.suffix, ", and more")
    }

    // MARK: - Authority guards

    func testUserinfoIsRejected() throws {
        let text = try linkify("user:pass@clau.de/x")
        XCTAssertNil(text.linkLabel)
    }

    /// The label reads `clau.de`, the browser would go to `evil.test`.
    func testHostSpoofViaUserinfoIsRejected() throws {
        let text = try linkify("clau.de@evil.test/x")
        XCTAssertNil(text.linkLabel)
    }

    func testNonDefaultPortIsRejected() throws {
        for raw in ["clau.de:8443/x", "https://clau.de:8443/x"] {
            let text = try linkify(raw)
            XCTAssertNil(text.linkLabel, "unexpectedly linkified: \(raw)")
        }
    }

    /// Cyrillic `с` (U+0441) in place of Latin `c`.
    func testIDNHomographIsRejected() throws {
        let text = try linkify("\u{0441}lau.de/x")
        XCTAssertNil(text.linkLabel)
        XCTAssertNil(text.linkURL)
    }

    // MARK: - First match wins

    func testOnlyTheFirstCandidateIsLinked() throws {
        let text = try linkify("visit clau.de/a and clau.de/b")

        XCTAssertEqual(text.prefix, "visit ")
        XCTAssertEqual(text.linkLabel, "clau.de/a")
        XCTAssertEqual(text.suffix, " and clau.de/b")
    }

    // MARK: - Sanitising

    func testWhitespaceRunsAndControlCharactersAreNormalised() throws {
        let text = try linkify("+50%\n\nweekly\tlimits\u{0007} · clau.de/x")

        XCTAssertEqual(text.plainText, "+50% weekly limits · clau.de/x")
        XCTAssertEqual(text.linkLabel, "clau.de/x")
    }

    /// A right-to-left override can render a URL reversed next to unrelated
    /// text, so it never survives into anything the popover draws.
    func testBidiOverridesAreStripped() throws {
        let text = try linkify("promo \u{202E}clau.de/x\u{202C}")

        XCTAssertFalse(text.plainText.unicodeScalars.contains { (0x202A...0x202E).contains($0.value) })
        XCTAssertEqual(text.linkLabel, "clau.de/x")
    }

    func testWhitespaceOnlyTextIsNotRendered() {
        XCTAssertNil(LinkifiedText.linkify("   \n\t "))
        XCTAssertNil(LinkifiedText.linkify(""))
    }

    /// Rejected, never truncated: a cut-off notice could end mid-URL.
    func testOverLongTextIsRejectedRatherThanTruncated() {
        let atLimit = String(repeating: "a", count: LinkifiedText.maximumLength)
        XCTAssertNotNil(LinkifiedText.linkify(atLimit))

        let overLimit = String(repeating: "a", count: LinkifiedText.maximumLength + 1)
        XCTAssertNil(LinkifiedText.linkify(overLimit))
    }
}
