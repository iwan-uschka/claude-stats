import Foundation

/// Model family, used to group per-model usage into the popover's "By model"
/// rows. Raw values match the family token in Anthropic model IDs
/// (`claude-sonnet-5`, `claude-opus-5`, `claude-haiku-4-5`, `claude-fable-5`).
public enum ModelFamily: String, Sendable, Hashable, Codable, CaseIterable {
    case sonnet
    case opus
    case haiku
    case fable

    /// Row label in the popover.
    public var displayName: String {
        switch self {
        case .sonnet: return "Sonnet"
        case .opus: return "Opus"
        case .haiku: return "Haiku"
        case .fable: return "Fable"
        }
    }

    /// Display order for the "By model" rows.
    public static let displayOrder: [ModelFamily] = [.sonnet, .opus, .haiku, .fable]

    /// Best-effort family for a raw model ID from the JSONL (e.g.
    /// `claude-sonnet-5`, `claude-opus-4-8`). Returns `nil` for IDs whose
    /// family this version doesn't recognise.
    public static func inferred(fromModelID modelID: String) -> ModelFamily? {
        let id = modelID.lowercased()
        return allCases.first { id.contains($0.rawValue) }
    }
}

/// Token count and estimated spend for one model, over a fixed window
/// (the popover's "By model" section uses a fixed 24h window, independent of
/// the `TimeWindow` toggle above it).
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
