import Foundation

/// Token counts for a single assistant message, as reported by the `usage`
/// object on Claude Code's session JSONL lines.
///
/// Field names mirror the on-disk keys (`input_tokens`,
/// `cache_creation_input_tokens`, …) so the mapping stays obvious. The two
/// `ephemeral*` counts are the `usage.cache_creation` breakdown — they sum to
/// ``cacheCreationInputTokens`` when present, and are both zero on older lines
/// that don't carry the breakdown.
public struct TokenUsage: Sendable, Hashable, Codable {
    /// Uncached prompt tokens (`input_tokens`).
    public var inputTokens: Int
    /// Generated tokens (`output_tokens`).
    public var outputTokens: Int
    /// Tokens written to the prompt cache (`cache_creation_input_tokens`).
    public var cacheCreationInputTokens: Int
    /// Tokens served from the prompt cache (`cache_read_input_tokens`).
    public var cacheReadInputTokens: Int
    /// Cache writes with the 5-minute TTL (`cache_creation.ephemeral_5m_input_tokens`).
    public var ephemeral5mInputTokens: Int
    /// Cache writes with the 1-hour TTL (`cache_creation.ephemeral_1h_input_tokens`).
    public var ephemeral1hInputTokens: Int

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheCreationInputTokens: Int = 0,
        cacheReadInputTokens: Int = 0,
        ephemeral5mInputTokens: Int = 0,
        ephemeral1hInputTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.ephemeral5mInputTokens = ephemeral5mInputTokens
        self.ephemeral1hInputTokens = ephemeral1hInputTokens
    }

    /// Every token the request touched: uncached input + output + cache writes
    /// + cache reads. This is the number the popover's token columns show — it
    /// is *not* quota- or cost-weighted (see ``quotaWeightedTokens`` and
    /// ``ModelPricing/costUSD(for:)`` for those).
    public var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationInputTokens + cacheReadInputTokens
    }

    /// Tokens weighted the way billing weights them: cache writes cost 1.25×
    /// (5-minute TTL) or 2× (1-hour TTL) of an input token, cache reads 0.1×.
    /// Used for plan-tier detection, whose published thresholds (~19k/88k/220k
    /// per 5-hour window) are far below raw cached-token volumes.
    public var quotaWeightedTokens: Int {
        let write5m = ephemeral5mInputTokens
        let write1h = ephemeral1hInputTokens
        // Lines without the `cache_creation` breakdown: charge the whole write at the 5m rate.
        let unattributedWrites = max(0, cacheCreationInputTokens - write5m - write1h)
        let weighted =
            Double(inputTokens)
            + Double(outputTokens)
            + Double(write5m + unattributedWrites) * ModelPricing.cacheWrite5mMultiplier
            + Double(write1h) * ModelPricing.cacheWrite1hMultiplier
            + Double(cacheReadInputTokens) * ModelPricing.cacheReadMultiplier
        return Int(weighted.rounded())
    }

    /// `true` when the line reported no tokens at all — e.g. Claude Code's
    /// `<synthetic>` assistant messages, which carry an all-zero `usage`.
    public var isEmpty: Bool { totalTokens == 0 }

    /// Field-wise sum, for aggregating many messages into one row.
    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheCreationInputTokens: lhs.cacheCreationInputTokens + rhs.cacheCreationInputTokens,
            cacheReadInputTokens: lhs.cacheReadInputTokens + rhs.cacheReadInputTokens,
            ephemeral5mInputTokens: lhs.ephemeral5mInputTokens + rhs.ephemeral5mInputTokens,
            ephemeral1hInputTokens: lhs.ephemeral1hInputTokens + rhs.ephemeral1hInputTokens
        )
    }

    public static let zero = TokenUsage()
}

/// One token-bearing line from a session JSONL, reduced to just what the stats
/// layer needs: when it happened, where it came from, which model answered, and
/// how many tokens it burned.
///
/// Only `assistant` lines carrying a `message.usage` object become events —
/// `user`, `attachment`, `system`, `summary`, `queue-operation`, and the other
/// bookkeeping line types have no token counts to attribute.
public struct UsageEvent: Sendable, Hashable {
    /// The line's `timestamp`, parsed from ISO8601.
    public let timestamp: Date

    /// Mapped `entrypoint`. `nil` when the field is absent or holds a value
    /// this version doesn't know (forward compatibility — unknown sources are
    /// excluded from ``EntrypointBreakdown`` but still counted in token, cost,
    /// and burn-rate totals).
    public let entrypoint: Entrypoint?

    /// Raw `message.model`, e.g. `claude-sonnet-5`. `nil` when absent.
    public let modelID: String?

    /// Token counts from `message.usage`.
    public let usage: TokenUsage

    /// `isSidechain` — `true` for subagent/sidechain turns. These are separate
    /// API calls with their own token spend, so they are counted normally; the
    /// flag is kept only so callers can slice by it if they ever need to.
    public let isSidechain: Bool

    /// `sessionId`, for grouping or debugging.
    public let sessionID: String?

    public init(
        timestamp: Date,
        entrypoint: Entrypoint? = nil,
        modelID: String? = nil,
        usage: TokenUsage,
        isSidechain: Bool = false,
        sessionID: String? = nil
    ) {
        self.timestamp = timestamp
        self.entrypoint = entrypoint
        self.modelID = modelID
        self.usage = usage
        self.isSidechain = isSidechain
        self.sessionID = sessionID
    }

    /// Family the ``modelID`` maps to, or `nil` for IDs this version doesn't
    /// recognise (including Claude Code's `<synthetic>` placeholder).
    public var modelFamily: ModelFamily? {
        modelID.flatMap(ModelFamily.inferred(fromModelID:))
    }

    /// Estimated USD cost of this message, `0` when the model is unpriced.
    public var estimatedCostUSD: Double {
        guard let modelID, let pricing = ModelPricing.forModelID(modelID) else { return 0 }
        return pricing.costUSD(for: usage)
    }
}
