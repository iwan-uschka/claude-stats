import SwiftUI

/// Shared layout constants for the popover, so the label columns of the quota
/// rows, the "This Mac" rows and the "By model" rows line up with each other.
enum PopoverMetrics {
    static let popoverWidth: CGFloat = 340
    static let contentPadding: CGFloat = 14
    /// Width of the leading label column shared by every row type.
    ///
    /// 80, sized to the widest label that is not the app's own: the scoped
    /// weekly rows are labelled from the payload, and `"Sonnet weekly"`
    /// measures 76.2 pt at ``bodyFont`` (`"Usage credits"` 72.4, the two fixed
    /// window labels far less). It was 92 while those rows read
    /// `"Sonnet (weekly)"` and the fixed ones said `"5-hour window"`; dropping
    /// the parentheses and the word "window" bought the bars 12 pt. A longer
    /// model name truncates (``WindowBarView`` pins its label to one line)
    /// rather than growing the row to two lines.
    static let labelColumnWidth: CGFloat = 80
    /// Width of the percentage column on a quota row — widest label `99.9%`,
    /// which measures 34.6 pt in the monospaced-digit ``valueFont``.
    static let percentColumnWidth: CGFloat = 38
    /// Width of the trailing reset-countdown column. Sized to the widest
    /// string it ever holds, the `reset pending` placeholder (66.5 pt at
    /// ``captionFont``); the countdowns themselves (`2h 14m`, `6d 23h`) are
    /// under 45 pt. It was 92 while the column read `resets in 2h 14m`; the
    /// width saved went to the bars. Not lower: the merged
    /// ``percentAndCountdownColumnWidth`` must still hold a usage-credits
    /// value such as `20,87 € of 33,00 €` (99.8 pt at ``valueFont``) on one
    /// line — at 38 + 8 + 70 it has 116 pt for it.
    static let countdownColumnWidth: CGFloat = 70
    /// The two trailing quota columns merged into one, for a row whose value is
    /// wider than a percentage and has no countdown to show — the usage-credits
    /// row's `€0.00 of €33.00`. Spans exactly the same pixels, so its value
    /// still ends flush with the countdowns above it.
    static let percentAndCountdownColumnWidth: CGFloat =
        percentColumnWidth + rowSpacing + countdownColumnWidth
    /// Width of one window column in the "This Mac" table, which shows all
    /// three windows side by side. Sized well past the widest count a row
    /// realistically carries (`40.6k` is 30.3 pt at ``valueFont``, `255M`
    /// less) so the three columns stay evenly spaced rather than sized to the
    /// busiest day; label 80 + 3 × 56 + 4 × 8 of spacing still leaves slack
    /// against 312 pt of content width.
    static let windowColumnWidth: CGFloat = 56
    /// Width of the token column in the "By model" section — wider than a
    /// "This Mac" column because the counts there carry a `tok` suffix and are
    /// all-time rather than windowed.
    static let modelTokenColumnWidth: CGFloat = 98
    /// Width of the cost column in the "By model" section. Wide enough for
    /// 4-digit spend (`$1234.56`) — a heavy cache-read day can push a single
    /// model's estimate well past the `$3.15`-sized figures this used to be
    /// sized for.
    static let costColumnWidth: CGFloat = 76
    static let rowSpacing: CGFloat = 8
    static let sectionSpacing: CGFloat = 10
    /// Gap between an account's active/inactive icon and its name.
    static let accountMarkerSpacing: CGFloat = 4
    /// Vertical gap between the rows inside one section.
    static let quotaRowSpacing: CGFloat = 6
    /// Gap above each *other*-account disclosure group, and between two of
    /// them. Deliberately double ``quotaRowSpacing``: the groups carry no
    /// divider of their own any more (a `Divider()` there read as a top-level
    /// section break, the same rule that separates "This Mac" from "By model"),
    /// so whitespace is the only thing left saying a collapsed row belongs to
    /// neither the bars above it nor the group below it.
    static let accountGroupSpacing: CGFloat = 12

    static let bodyFont = Font.system(size: 11)
    static let valueFont = Font.system(size: 11).monospacedDigit()
    static let sectionTitleFont = Font.system(size: 11, weight: .semibold)
    static let captionFont = Font.system(size: 10)

    /// Claude's brand terracotta, used for the promo notice link instead of
    /// `.accentColor` (which follows the user's system accent, usually blue,
    /// and reads as an unrelated OS affordance rather than Claude's own
    /// promo). Two literals switched on appearance, not one fixed color:
    /// `#CA7C5E` measured ≈3.17:1 against a light popover background, below
    /// the 4.5:1 WCAG 2.2 AA minimum for this caption-size text. `#A85E3E`
    /// clears 4.5:1 on white (≈4.84:1); `#E88A5C` clears it against the dark
    /// popover background (≈6.2:1).
    static let brandLinkColor = Color(NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(red: 0xE8 / 255, green: 0x8A / 255, blue: 0x5C / 255, alpha: 1)
            : NSColor(red: 0xA8 / 255, green: 0x5E / 255, blue: 0x3E / 255, alpha: 1)
    })
}
