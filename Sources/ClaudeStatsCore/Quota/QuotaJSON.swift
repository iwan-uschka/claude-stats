import Foundation

/// Lenient coercion helpers for the rate-limit payloads Claude Code emits.
///
/// Two shapes flow through here, neither of them documented:
///
/// - the **statusline hook** payload — `used_percentage` with `resets_at` as
///   **Unix epoch seconds**, captured by our own helper script;
/// - Claude Code's own **`cachedUsageUtilization`** blob in `~/.claude.json` —
///   `utilization` as a bare number, `resets_at` as an ISO-8601 string with
///   fractional seconds and an offset, `fetchedAtMs` as epoch milliseconds.
///
/// Rather than pin one shape per source and break on the first upstream
/// rename, nothing here uses `Codable`: every reader accepts any of the key
/// spellings below, and ``date(_:)`` accepts every timestamp encoding seen so
/// far regardless of which payload it came from.
enum QuotaJSON {
    /// Percentage-consumed key spellings observed or plausible in the payload.
    static let percentKeys = [
        "used_percentage",  // statusLine hook payload
        "usedPercentage",
        "utilization",  // `cachedUsageUtilization` in ~/.claude.json
        "percent_used",
        "percentUsed",
        "used",
    ]

    /// Reset-timestamp key spellings.
    static let resetKeys = ["resets_at", "resetsAt", "reset_at", "resetAt"]

    /// Capture-timestamp key spellings, across both payloads: `captured_at`
    /// is what the statusline helper script writes, `fetchedAtMs` is what
    /// Claude Code stamps on `cachedUsageUtilization` (epoch **milliseconds** —
    /// ``date(_:)``'s magnitude heuristic already handles that).
    static let capturedAtKeys = ["captured_at", "capturedAt", "fetchedAtMs", "fetched_at_ms"]

    static func object(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    /// First non-`nil` nested object found under any of `keys`.
    static func nestedObject(in dict: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let nested = object(dict[key]) { return nested }
        }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        let result: Double?
        switch value {
        case let number as NSNumber: result = number.doubleValue
        case let double as Double: result = double
        case let int as Int: result = Double(int)
        case let string as String: result = Double(string)
        default: result = nil
        }
        // `Double("nan")`/`Double("inf")` parse successfully in Swift; reject
        // them here so a malformed upstream value fails the coercion instead
        // of silently propagating a NaN through `QuotaWindow.fractionUsed`.
        return result.flatMap { $0.isFinite ? $0 : nil }
    }

    /// Coerces a reset timestamp: epoch seconds, epoch milliseconds, or ISO-8601.
    static func date(_ value: Any?) -> Date? {
        if let string = value as? String {
            if let parsed = iso8601Date(string) { return parsed }
            // Some emitters stringify epochs.
            if let seconds = Double(string) { return epochDate(seconds) }
            return nil
        }
        if let seconds = double(value) { return epochDate(seconds) }
        return nil
    }

    /// Treats implausibly large values as milliseconds (year-5138 cutoff).
    private static func epochDate(_ value: Double) -> Date? {
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value)
    }

    private static func iso8601Date(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    /// Builds a window from a per-window object. Returns `nil` when no
    /// percentage is present — an all-`nil` window carries no information and
    /// should not be mistaken for "0% used".
    static func window(_ value: Any?) -> QuotaWindow? {
        guard let dict = object(value) else { return nil }
        guard let percent = percentKeys.lazy.compactMap({ double(dict[$0]) }).first else {
            return nil
        }
        let resetsAt = resetKeys.lazy.compactMap { date(dict[$0]) }.first
        return QuotaWindow(percentUsed: percent, resetsAt: resetsAt)
    }

    /// Extracts both windows from a container that holds `five_hour` /
    /// `seven_day` either directly or nested under a wrapper key.
    ///
    /// - Returns: `nil` when neither window is present at all.
    static func windows(in root: [String: Any]) -> (fiveHour: QuotaWindow, sevenDay: QuotaWindow)? {
        // Prefer the root's own keys; fall back to a wrapper only for whichever
        // window the root didn't have, so a root that already carries real
        // windows can't be shadowed by an unrelated object under a wrapper key.
        let wrapper = nestedObject(in: root, keys: ["rate_limits", "rateLimits", "usage", "data"])
        let fiveHour = window(root["five_hour"]) ?? window(root["fiveHour"])
            ?? wrapper.flatMap { window($0["five_hour"]) ?? window($0["fiveHour"]) }
        let sevenDay = window(root["seven_day"]) ?? window(root["sevenDay"])
            ?? wrapper.flatMap { window($0["seven_day"]) ?? window($0["sevenDay"]) }
        // Each window can be independently absent; require at least one.
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return (fiveHour ?? .empty, sevenDay ?? .empty)
    }
}
