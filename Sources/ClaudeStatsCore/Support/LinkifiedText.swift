import Foundation

/// A short run of text with at most one embedded link, pre-split into the three
/// pieces a `Text(AttributedString)` needs.
///
/// Split at *parse* time, not at render time: the popover re-renders on every
/// clock tick, and re-scanning a string for URLs sixty times a minute to
/// produce the same answer is wasted work. It also means the view does no index
/// math on attacker-influenced text — it only concatenates three stored runs.
///
/// ## Trust model
///
/// The text this wraps comes from `~/.claude.json`, which is user-writable:
/// any local process running as the user can plant a string here and have it
/// rendered, clickable, inside a Claude-branded popover. That risk is accepted
/// deliberately — the alternative (a host allowlist) would break the moment
/// upstream changes the promo's short link, and a local process running as the
/// user has far better attacks available than this one. What is *not* accepted
/// is the link resolving somewhere other than where its label reads, so:
///
/// - only `https` ever survives (`http://` is upgraded; any *other* explicit
///   `scheme:` is rejected outright rather than having `https://` pasted in
///   front of it, so `javascript:`/`data:`/`file:` can never become a link);
/// - userinfo, passwords and explicit ports are rejected, killing
///   `clau.de@evil.test/x`;
/// - the host must be pure ASCII and must equal the parser's own idea of the
///   host, which kills IDN homographs (`сlau.de`) deterministically rather than
///   relying on how a given OS version happens to normalise them;
/// - bidi overrides and control characters are stripped before anything else,
///   so a URL can't be rendered reversed next to an unrelated label.
///
/// The popover additionally discloses the resolved `https://` URL in a tooltip,
/// which is the real anti-phishing affordance for a scheme-less label.
///
/// ## Degradation
///
/// Text that has no linkable token degrades to plain (``linkLabel`` `nil`) —
/// never to a dead or wrong link. ``linkify(_:)`` returns `nil` only when the
/// notice should not be rendered at all.
///
/// Hand-rolled rather than `NSDataDetector`: whether that matches a
/// scheme-less `clau.de/cc-50-promo` is unverified and OS-version-dependent,
/// and its accept set is far wider than anything wanted here.
public struct LinkifiedText: Sendable, Hashable, Codable {
    /// Everything before the link. Equal to ``plainText`` when there is no link.
    public let prefix: String
    /// The link token exactly as written — `clau.de/cc-50-promo`, not
    /// `https://clau.de/cc-50-promo`. `nil` when nothing was linkable.
    public let linkLabel: String?
    /// Where ``linkLabel`` actually goes. Always `https`.
    public let linkURL: URL?
    /// Everything after the link.
    public let suffix: String

    public init(prefix: String, linkLabel: String?, linkURL: URL?, suffix: String) {
        self.prefix = prefix
        self.linkLabel = linkLabel
        self.linkURL = linkURL
        self.suffix = suffix
    }

    /// The sanitised text as one string. Invariant:
    /// `plainText == prefix + (linkLabel ?? "") + suffix`.
    public var plainText: String { prefix + (linkLabel ?? "") + suffix }

    /// Longest text accepted. Rejected, never truncated — a truncated notice
    /// could end mid-URL and read as a different destination.
    public static let maximumLength = 200

    /// Sanitises `rawText`, then links its first acceptable token.
    ///
    /// - Returns: `nil` when the text is empty after sanitising or longer than
    ///   ``maximumLength`` — i.e. when nothing should be rendered at all.
    public static func linkify(_ rawText: String) -> LinkifiedText? {
        guard let text = sanitized(rawText) else { return nil }

        let tokens = text.split(separator: " ").map(String.init)
        for (index, token) in tokens.enumerated() {
            let (leading, core, trailing) = trimmingEnclosingPunctuation(token)
            guard let url = httpsURL(for: core) else { continue }

            let before = tokens[..<index].joined(separator: " ")
            let after = tokens[(index + 1)...].joined(separator: " ")
            return LinkifiedText(
                prefix: (before.isEmpty ? "" : before + " ") + leading,
                linkLabel: core,
                linkURL: url,
                suffix: trailing + (after.isEmpty ? "" : " " + after)
            )
        }

        return LinkifiedText(prefix: text, linkLabel: nil, linkURL: nil, suffix: "")
    }

    // MARK: - Sanitising

    /// Whitespace runs (including newlines and tabs) collapse to one space;
    /// C0/C1 controls and bidi overrides/isolates are dropped entirely.
    ///
    /// Whitespace is mapped *before* controls are dropped, so `a\nb` becomes
    /// two tokens rather than the single word `ab`.
    private static func sanitized(_ rawText: String) -> String? {
        var scalars = String.UnicodeScalarView()
        for scalar in rawText.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                scalars.append(" ")
            } else if !isStripped(scalar) {
                scalars.append(scalar)
            }
        }

        let collapsed = String(scalars)
            .split(separator: " ")
            .joined(separator: " ")
        guard !collapsed.isEmpty, collapsed.count <= maximumLength else { return nil }
        return collapsed
    }

    private static func isStripped(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F:
            return true  // C0 and C1 controls
        case 0x202A...0x202E, 0x2066...0x2069:
            return true  // bidi embeddings/overrides and isolates
        default:
            return false
        }
    }

    /// Punctuation that can enclose a URL in running prose. Trimmed off the
    /// token before it is parsed and kept in `prefix`/`suffix`, so the label
    /// never includes the sentence's own full stop or closing bracket.
    private static let enclosingPunctuation: Set<Character> = [
        "(", ")", "[", "]", "{", "}", "<", ">", "\"", "'", "«", "»", "\u{201C}", "\u{201D}",
        "\u{2018}", "\u{2019}", ",", ".", ";", ":", "!", "?", "·", "…", "|", "•", "—", "–",
    ]

    private static func trimmingEnclosingPunctuation(
        _ token: String
    ) -> (leading: String, core: String, trailing: String) {
        var core = Substring(token)
        var leading = ""
        var trailing = ""
        while let first = core.first, enclosingPunctuation.contains(first) {
            leading.append(first)
            core = core.dropFirst()
        }
        while let last = core.last, enclosingPunctuation.contains(last) {
            trailing = String(last) + trailing
            core = core.dropLast()
        }
        return (leading, String(core), trailing)
    }

    // MARK: - URL acceptance

    private static let httpsPrefix = "https://"
    private static let httpPrefix = "http://"

    /// The whole accept/reject decision for one token. See the type's trust
    /// model for why each guard is here.
    private static func httpsURL(for token: String) -> URL? {
        guard !token.isEmpty else { return nil }

        let lowered = token.lowercased()
        let candidate: String
        if lowered.hasPrefix(httpsPrefix) {
            candidate = token
        } else if lowered.hasPrefix(httpPrefix) {
            candidate = httpsPrefix + token.dropFirst(httpPrefix.count)
        } else if hasExplicitScheme(token) {
            // `javascript:`, `data:`, `file:`, `about:` — and also `host:port`,
            // which is a rejected shape anyway. Never prefix `https://` onto
            // something that already declared a scheme.
            return nil
        } else {
            candidate = httpsPrefix + token
        }

        // The authority exactly as the token spells it, before any parser gets
        // to normalise it. Includes userinfo and port when present.
        let authority = candidate.dropFirst(httpsPrefix.count).prefix {
            $0 != "/" && $0 != "?" && $0 != "#"
        }
        guard !authority.isEmpty, authority.allSatisfy(\.isASCII) else { return nil }

        guard let components = URLComponents(string: candidate),
            components.scheme?.lowercased() == "https",
            components.user == nil,
            components.password == nil,
            components.port == nil,
            let host = components.host,
            // Kills IDN homographs and every userinfo/port shape in one
            // comparison: after the guards above the authority *is* the host,
            // so anything the parser read differently is not what the label says.
            host.lowercased() == authority.lowercased(),
            isPlausibleHost(host),
            let url = components.url
        else { return nil }

        return url
    }

    /// `true` when the token already declares an RFC-3986 scheme.
    private static func hasExplicitScheme(_ token: String) -> Bool {
        guard let colon = token.firstIndex(of: ":") else { return false }
        let scheme = token[token.startIndex..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter else { return false }
        return scheme.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".")
        }
    }

    /// Keeps ordinary prose from becoming a link: a bare word like `promo` is a
    /// syntactically valid host, so a dotted name with a letters-only TLD of at
    /// least two characters is required before anything is linkified.
    private static func isPlausibleHost(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return false }
        guard let tld = labels.last, tld.count >= 2,
            tld.allSatisfy({ $0.isASCII && $0.isLetter })
        else { return false }
        return labels.allSatisfy { label in
            label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}
