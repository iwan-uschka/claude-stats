import Charts
import SwiftUI

/// Hover rules shared by both popover charts: which day the pointer is on, and
/// whether a day picked up earlier still exists.
///
/// Pure and free of SwiftUI state on purpose. The hovered day is view state
/// owned by ``PopoverView``, the charts only report and draw it, and the part
/// worth testing is exactly this arithmetic.
enum PopoverChartHover {
    /// The plotted day nearest `date`, or `nil` when there is nothing plotted.
    ///
    /// Snapping is the mechanism, not a refinement: thirty days across a plot
    /// roughly 250 pt wide is about 8 pt per day, so there is no such thing as
    /// pointing at a day exactly. Nearest-midnight is the right measure because
    /// every mark is plotted on a plain date and therefore sits on its own
    /// midnight, the same instant its axis tick is drawn at — the day under the
    /// pointer at noon is already half-way to its successor's mark.
    ///
    /// Plain dates, note, not `unit: .day`: binning a date draws the mark at
    /// the *centre* of its bin, half a day right of the tick naming it. See
    /// ``PopoverChartAlignmentTests``.
    static func nearestDay(to date: Date, in days: [Date]) -> Date? {
        guard var best = days.first else { return nil }
        var bestDistance = abs(best.timeIntervalSince(date))
        for day in days.dropFirst() {
            let distance = abs(day.timeIntervalSince(date))
            if distance < bestDistance {
                best = day
                bestDistance = distance
            }
        }
        return best
    }

    /// Where `day` sits in `days`, or `nil` when it is not in there at all.
    ///
    /// The nil case is the one that matters. A poll replaces `dailyHistory`
    /// under a pointer that never moved, and around local midnight the window
    /// slides by a whole day — so a hovered day resolved once and remembered
    /// would keep showing a number from a window that has moved on. Resolving
    /// every render against the *current* history makes the stale case fall
    /// back to resting instead.
    static func index(of day: Date?, in days: [Date]) -> Int? {
        guard let day else { return nil }
        return days.firstIndex(of: day)
    }

    /// How every dated label in the popover spells a day — `Sep 3`, `16. Aug.`
    /// where the locale puts it that way. Month and day only: the window is at
    /// most a year and the year would cost width the axis hasn't got.
    ///
    /// One constant, used by both charts' x-axis ticks *and* by the rows that
    /// read a hovered day, so an axis tick and the readout beneath it can't
    /// spell the same day two ways.
    static let dayLabelFormat = Date.FormatStyle.dateTime.month(.abbreviated).day()

    /// A hovered day as the row below the chart names it.
    static func label(for day: Date) -> String {
        day.formatted(dayLabelFormat)
    }
}

extension View {
    /// Reports the day under the pointer, and `nil` once the pointer leaves.
    ///
    /// `.chartOverlay` rather than `.chartXSelection`: selection is a
    /// click/drag gesture on macOS, and this has to answer to hover alone. The
    /// overlay converts the pointer's x through the proxy, which needs the
    /// plot's own origin subtracted — the overlay spans the whole chart,
    /// axis labels included, and the proxy measures from the plot's leading
    /// edge.
    func chartHoverTracking(days: [Date], onHover: @escaping (Date?) -> Void) -> some View {
        chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard
                                let plotFrame = proxy.plotFrame,
                                let date: Date = proxy.value(atX: location.x - geometry[plotFrame].origin.x)
                            else {
                                onHover(nil)
                                return
                            }
                            onHover(PopoverChartHover.nearestDay(to: date, in: days))
                        case .ended:
                            onHover(nil)
                        }
                    }
            }
        }
    }
}
