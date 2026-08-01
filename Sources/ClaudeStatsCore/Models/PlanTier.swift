import Foundation

/// Subscription tier, auto-detected from local history against known 5-hour
/// window thresholds (with a P90 fallback for unclear/custom plans).
public enum PlanTier: Sendable, Hashable, Codable {
    case pro
    case max5
    case max20
    /// Unknown or non-standard plan; `tokens` is the estimated 5-hour budget
    /// (e.g. P90 of the last 8 days of local history).
    case custom(tokens: Int)

    /// The three tiers with known thresholds.
    public static let knownTiers: [PlanTier] = [.pro, .max5, .max20]

    /// Approximate token budget per 5-hour window.
    public var fiveHourTokenBudget: Int {
        switch self {
        case .pro: return 19_000
        case .max5: return 88_000
        case .max20: return 220_000
        case .custom(let tokens): return tokens
        }
    }

    /// Name shown in the popover ("Plan: Max20 (auto-detected)").
    public var displayName: String {
        switch self {
        case .pro: return "Pro"
        case .max5: return "Max5"
        case .max20: return "Max20"
        case .custom: return "Custom"
        }
    }

    /// Whether this tier came from a known threshold rather than a local estimate.
    public var isKnownTier: Bool {
        if case .custom = self { return false }
        return true
    }

    /// Closest known tier for a measured 5-hour token budget, or `.custom`
    /// when the value is nowhere near a published threshold.
    ///
    /// - Parameter tolerance: Fractional distance from a known threshold that
    ///   still counts as a match (default 25%).
    public static func nearestKnownTier(
        forFiveHourTokens tokens: Int,
        tolerance: Double = 0.25
    ) -> PlanTier {
        let match = knownTiers.min { lhs, rhs in
            abs(lhs.fiveHourTokenBudget - tokens) < abs(rhs.fiveHourTokenBudget - tokens)
        }
        guard let match else { return .custom(tokens: tokens) }
        let budget = Double(match.fiveHourTokenBudget)
        guard budget > 0, abs(Double(tokens) - budget) / budget <= tolerance else {
            return .custom(tokens: tokens)
        }
        return match
    }
}
