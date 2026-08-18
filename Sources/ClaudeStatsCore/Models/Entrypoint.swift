import Foundation

/// Where a session originated, mapped from the `entrypoint` field present on
/// every line of Claude Code's session JSONL.
///
/// Raw values are the on-disk JSONL values, so `Entrypoint(rawValue:)` decodes
/// a raw log field directly.
public enum Entrypoint: String, Sendable, Hashable, Codable, CaseIterable {
    /// `cli` — interactive terminal sessions.
    case cli = "cli"
    /// `claude-vscode` — the VS Code extension.
    case vscode = "claude-vscode"
    /// `sdk-cli` — Agent SDK, subagents, workflows, headless `-p` runs.
    case sdkAgent = "sdk-cli"

    /// Decode from a raw JSONL `entrypoint` value. Returns `nil` for values
    /// this version doesn't know about (forward compatibility — callers should
    /// bucket unknowns rather than crash).
    public init?(rawJSONLValue: String) {
        self.init(rawValue: rawJSONLValue)
    }

    /// Row label in the popover's "This Mac" breakdown.
    public var displayName: String {
        switch self {
        case .cli: return "CLI"
        case .vscode: return "VS Code"
        case .sdkAgent: return "SDK/agents"
        }
    }

    /// Display order for the breakdown rows.
    public static let displayOrder: [Entrypoint] = [.cli, .vscode, .sdkAgent]
}

/// The rolling window selected by the "This Mac" breakdown toggle.
public enum TimeWindow: String, Sendable, Hashable, Codable, CaseIterable {
    case fiveHour = "5h"
    case twentyFourHour = "24h"
    case sevenDay = "7d"

    /// Length of the window in seconds.
    public var duration: TimeInterval {
        switch self {
        case .fiveHour: return 5 * 60 * 60
        case .twentyFourHour: return 24 * 60 * 60
        case .sevenDay: return 7 * 24 * 60 * 60
        }
    }

    /// Column header in the popover ("5h", "24h", "7d").
    public var displayName: String { rawValue }

    /// Earliest timestamp still inside the window.
    public func startDate(endingAt end: Date = Date()) -> Date {
        end.addingTimeInterval(-duration)
    }
}

/// Per-entrypoint token counts for one ``TimeWindow``.
public struct EntrypointBreakdown: Sendable, Hashable, Codable {
    public let window: TimeWindow
    /// Summed token counts per entrypoint, kept split so the popover can
    /// explain how much of a row's total is replayed cache reads.
    public let usageByEntrypoint: [Entrypoint: TokenUsage]

    public init(window: TimeWindow, usageByEntrypoint: [Entrypoint: TokenUsage]) {
        self.window = window
        self.usageByEntrypoint = usageByEntrypoint
    }

    /// Token split attributed to `entrypoint`, all-zero when it had no activity.
    public func usage(for entrypoint: Entrypoint) -> TokenUsage {
        usageByEntrypoint[entrypoint] ?? .zero
    }

    /// Tokens attributed to `entrypoint`, or 0 when it had no activity.
    public func tokens(for entrypoint: Entrypoint) -> Int {
        usage(for: entrypoint).totalTokens
    }

    /// Field-wise sum across all entrypoints — what the breakdown-wide
    /// cache-read caption is computed from.
    public var totalUsage: TokenUsage {
        usageByEntrypoint.values.reduce(.zero, +)
    }

    /// Sum across all entrypoints.
    public var totalTokens: Int {
        totalUsage.totalTokens
    }

    /// Rows in ``Entrypoint/displayOrder``, including zero-token entrypoints.
    public var orderedRows: [(entrypoint: Entrypoint, usage: TokenUsage)] {
        Entrypoint.displayOrder.map { ($0, usage(for: $0)) }
    }

    /// Empty breakdown for `window` — every entrypoint at zero.
    public static func empty(window: TimeWindow) -> EntrypointBreakdown {
        EntrypointBreakdown(window: window, usageByEntrypoint: [:])
    }
}
