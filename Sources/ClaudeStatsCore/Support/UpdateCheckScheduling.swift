import Foundation

/// Decides whether a periodic update check is due. Pure — no `Date()` call
/// hidden inside — so the boundary and elapsed/not-elapsed cases are
/// unit-testable without waiting on a real clock.
public func shouldRunUpdateCheck(lastCheck: Date?, now: Date, interval: TimeInterval) -> Bool {
    guard let lastCheck else { return true }
    return now.timeIntervalSince(lastCheck) >= interval
}
