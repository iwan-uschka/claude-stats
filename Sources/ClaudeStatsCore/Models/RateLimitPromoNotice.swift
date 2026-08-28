import Foundation

/// One entry of Claude Code's `tengu_rate_limit_promo_notices` GrowthBook flag —
/// the promo line the CLI renders above its own weekly bar.
///
/// Shape as cached in `~/.claude.json`:
///
/// ```json
/// { "bar": "seven_day",
///   "text": "+50% weekly limits promo through Aug 31 · clau.de/cc-50-promo",
///   "variant": "claude" }
/// ```
///
/// The promotion raises the weekly *ceiling* itself, so the percentage we show
/// is already measured against the boosted limit — the notice is copy, not a
/// correction to apply to any number.
public struct RateLimitPromoNotice: Sendable, Hashable, Codable {
    /// Which bar the notice belongs under. Never inferred — an entry whose
    /// `bar` we don't recognise is dropped instead (see
    /// ``QuotaWindowKind/init(promoBarValue:)``).
    public let bar: QuotaWindowKind
    /// The notice text, pre-split around its link.
    public let body: LinkifiedText
    /// Upstream's copy label (`"claude"` on this machine). Stored for fidelity
    /// and **deliberately not used for styling**: it's an undocumented string
    /// whose design intent we can't see, so mapping it to colours or icons
    /// would be guessing at an upstream visual language.
    public let variant: String?

    public init(bar: QuotaWindowKind, body: LinkifiedText, variant: String?) {
        self.bar = bar
        self.body = body
        self.variant = variant
    }

    /// The notice as one plain string — what accessibility and tooltips read.
    public var text: String { body.plainText }

    /// Builds a notice from one raw JSON entry.
    ///
    /// - Returns: `nil` when the entry names an unknown bar, or when its text
    ///   is missing, empty, or too long to be a one-line notice. Callers
    ///   `compactMap` over this, so a bad sibling entry never takes out a good
    ///   one.
    public init?(json: [String: Any]) {
        guard let barValue = json["bar"] as? String,
            let bar = QuotaWindowKind(promoBarValue: barValue)
        else { return nil }
        guard let rawText = json["text"] as? String,
            let body = LinkifiedText.linkify(rawText)
        else { return nil }
        self.init(bar: bar, body: body, variant: json["variant"] as? String)
    }
}
