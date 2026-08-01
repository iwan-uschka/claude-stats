import Foundation

/// Per-model-family API list price, used to turn local token counts into a USD
/// estimate. One rate pair per family; the cache rates are derived from the
/// input rate via the multipliers below rather than stored separately, so
/// updating a family means editing two numbers.
///
/// Rates are Anthropic first-party API list prices per million tokens as of
/// 2026-08 (Sonnet's $2/$10 introductory rate through 2026-08-31 is
/// deliberately ignored in favour of the standard $3/$15). Subscription users
/// aren't billed per token at all — treat every number here as an estimate of
/// equivalent API spend, and update ``table`` when prices change.
public struct ModelPricing: Sendable, Hashable {
    /// USD per million uncached input tokens.
    public var inputPerMillionUSD: Double
    /// USD per million output tokens.
    public var outputPerMillionUSD: Double

    public init(inputPerMillionUSD: Double, outputPerMillionUSD: Double) {
        self.inputPerMillionUSD = inputPerMillionUSD
        self.outputPerMillionUSD = outputPerMillionUSD
    }

    /// Cache reads cost ~0.1× an input token.
    public static let cacheReadMultiplier: Double = 0.1
    /// Cache writes with the default 5-minute TTL cost 1.25× an input token.
    public static let cacheWrite5mMultiplier: Double = 1.25
    /// Cache writes with the 1-hour TTL cost 2× an input token.
    public static let cacheWrite1hMultiplier: Double = 2.0

    /// USD per million tokens read from the prompt cache.
    public var cacheReadPerMillionUSD: Double {
        inputPerMillionUSD * ModelPricing.cacheReadMultiplier
    }

    /// USD per million tokens written to the prompt cache at the 5-minute TTL.
    public var cacheWrite5mPerMillionUSD: Double {
        inputPerMillionUSD * ModelPricing.cacheWrite5mMultiplier
    }

    /// USD per million tokens written to the prompt cache at the 1-hour TTL.
    public var cacheWrite1hPerMillionUSD: Double {
        inputPerMillionUSD * ModelPricing.cacheWrite1hMultiplier
    }

    /// Estimated cost of one message's token counts.
    ///
    /// Cache writes are split by TTL when the line carries the
    /// `usage.cache_creation` breakdown; writes not attributed to either TTL
    /// are charged at the 5-minute rate (the API default).
    public func costUSD(for usage: TokenUsage) -> Double {
        let write5m = usage.ephemeral5mInputTokens
        let write1h = usage.ephemeral1hInputTokens
        let unattributedWrites = max(0, usage.cacheCreationInputTokens - write5m - write1h)

        let millions = 1_000_000.0
        return (Double(usage.inputTokens) / millions) * inputPerMillionUSD
            + (Double(usage.outputTokens) / millions) * outputPerMillionUSD
            + (Double(write5m + unattributedWrites) / millions) * cacheWrite5mPerMillionUSD
            + (Double(write1h) / millions) * cacheWrite1hPerMillionUSD
            + (Double(usage.cacheReadInputTokens) / millions) * cacheReadPerMillionUSD
    }

    /// Input/output list price per family. Edit here when Anthropic changes prices.
    public static let table: [ModelFamily: ModelPricing] = [
        .sonnet: ModelPricing(inputPerMillionUSD: 3, outputPerMillionUSD: 15),
        .opus: ModelPricing(inputPerMillionUSD: 5, outputPerMillionUSD: 25),
        .haiku: ModelPricing(inputPerMillionUSD: 1, outputPerMillionUSD: 5),
        .fable: ModelPricing(inputPerMillionUSD: 10, outputPerMillionUSD: 50),
    ]

    /// Pricing for a family, or `nil` if the family has no entry yet.
    public static func forFamily(_ family: ModelFamily) -> ModelPricing? {
        table[family]
    }

    /// Pricing for a raw model ID from the JSONL. `nil` when the ID's family
    /// isn't recognised — callers should then report `0` rather than guess.
    public static func forModelID(_ modelID: String) -> ModelPricing? {
        ModelFamily.inferred(fromModelID: modelID).flatMap(forFamily)
    }
}
