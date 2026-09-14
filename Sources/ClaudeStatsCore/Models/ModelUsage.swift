import Foundation

/// Model family, used to group per-model usage into the popover's "By model"
/// bands and the table under them. Raw values match the family token in
/// Anthropic model IDs
/// (`claude-sonnet-5`, `claude-opus-5`, `claude-haiku-4-5`, `claude-fable-5`).
public enum ModelFamily: String, Sendable, Hashable, Codable, CaseIterable {
    case sonnet
    case opus
    case haiku
    case fable

    /// Band and row label in the popover's "By model" block.
    public var displayName: String {
        switch self {
        case .sonnet: return "Sonnet"
        case .opus: return "Opus"
        case .haiku: return "Haiku"
        case .fable: return "Fable"
        }
    }

    /// Stack order for the popover's "By model" bands, bottom band first — and
    /// so the order of the rows under them. Filtered to the families a window
    /// actually holds; see `DailyUsageSeries.modelKeys(in:)`.
    public static let displayOrder: [ModelFamily] = [.sonnet, .opus, .haiku, .fable]

    /// Best-effort family for a raw model ID from the JSONL (e.g.
    /// `claude-sonnet-5`, `claude-opus-4-8`). Returns `nil` for IDs whose
    /// family this version doesn't recognise.
    ///
    /// Matched over UTF-8 bytes rather than with
    /// `modelID.lowercased().contains(family.rawValue)`, deliberately, and the
    /// gap is not small: Foundation shadows the stdlib's `contains` with a
    /// locale-aware `range(of:options:)`, measured at ~1.2 µs per call against
    /// ~35 ns for the byte scan, with a string allocated per call for the
    /// `lowercased()` on top. Every event pays one of these on every rebuild —
    /// through ``UsageEvent/estimatedCostUSD`` and the two folds in
    /// `LocalLogUsageStore` — and those folds run on the main thread, so the
    /// cost showed up as a stalled popover rather than as background work.
    ///
    /// Folding ASCII case is all the locale-aware search was buying for an ID
    /// that can occur: the raw values above are ASCII, and so is everything
    /// Claude Code writes into `message.model`. The two do decide one input
    /// class differently — a family token carrying a combining mark, which the
    /// grapheme-aware search refuses and this accepts — pinned in
    /// `ModelFamilyInferenceTests`.
    public static func inferred(fromModelID modelID: String) -> ModelFamily? {
        var modelID = modelID
        return modelID.withUTF8 { id in
            allCases.first { family in
                var rawValue = family.rawValue
                return rawValue.withUTF8 { id.containsASCIICaseInsensitive($0) }
            }
        }
    }
}

private extension UnsafeBufferPointer where Element == UInt8 {

    /// Whether `needle` appears anywhere in this buffer, comparing ASCII letters
    /// without regard to case and every other byte exactly.
    ///
    /// A plain O(n·m) scan: both operands are a handful of bytes, so any of the
    /// cleverer substring algorithms would spend more on its skip table than the
    /// whole search costs.
    func containsASCIICaseInsensitive(_ needle: UnsafeBufferPointer<UInt8>) -> Bool {
        guard !needle.isEmpty, needle.count <= count else { return false }
        for start in 0...(count - needle.count) {
            var offset = 0
            while offset < needle.count,
                  asciiLowercased(self[start + offset]) == asciiLowercased(needle[offset]) {
                offset += 1
            }
            if offset == needle.count { return true }
        }
        return false
    }

    /// `A`–`Z` folded to lower case; every other byte left alone, including
    /// every byte of a multi-byte UTF-8 sequence — those all have the high bit
    /// set, so they can never be mistaken for an ASCII letter.
    func asciiLowercased(_ byte: UInt8) -> UInt8 {
        byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte | 0x20 : byte
    }
}

/// Token count and estimated spend for one model, over a fixed window.
///
/// Not what the popover draws: its "By model" block stacks
/// ``DailyUsageHistory/byModelFamily`` over thirty days. This is the data
/// layer's own per-model query, and the only reader of the retention fold's
/// ``HistoricalModelUsage`` totals.
public struct ModelUsage: Sendable, Hashable, Codable, Identifiable {
    /// Raw model ID as it appears in the JSONL, e.g. `claude-sonnet-5`.
    public let modelID: String
    /// Family the ID maps to, or `nil` for unrecognised IDs.
    public let family: ModelFamily?
    /// Summed token counts attributed to this model, kept split so the popover
    /// can explain how much of the total is replayed cache reads.
    public let usage: TokenUsage
    /// Cost in USD, computed locally from per-model pricing.
    public let estimatedCostUSD: Double

    public var id: String { modelID }

    /// Total tokens attributed to this model — the row's headline number.
    public var tokens: Int { usage.totalTokens }

    public init(
        modelID: String,
        family: ModelFamily? = nil,
        usage: TokenUsage,
        estimatedCostUSD: Double
    ) {
        self.modelID = modelID
        self.family = family ?? ModelFamily.inferred(fromModelID: modelID)
        self.usage = usage
        self.estimatedCostUSD = estimatedCostUSD
    }

    /// Label for the row: the family name when known, otherwise the raw ID.
    public var displayName: String {
        family?.displayName ?? modelID
    }
}
