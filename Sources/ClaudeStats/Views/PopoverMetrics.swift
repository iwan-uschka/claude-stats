import SwiftUI

/// Shared layout constants for the popover, so the label columns of the quota
/// rows, the "This Mac" rows and the "By model" rows line up with each other.
enum PopoverMetrics {
    static let popoverWidth: CGFloat = 340
    static let contentPadding: CGFloat = 14
    /// Width of the leading label column shared by every row type.
    ///
    /// 92, not the 84 the two fixed window labels needed: the scoped weekly rows
    /// are labelled from the payload, and `"Sonnet (weekly)"` measures 84.7 pt at
    /// ``bodyFont`` — it would have wrapped at 84. 92 clears every one-word model
    /// name with margin; anything longer truncates (``WindowBarView`` pins its
    /// label to one line) rather than growing the row to two lines.
    static let labelColumnWidth: CGFloat = 92
    /// Width of the percentage column on a quota row (`62%`).
    static let percentColumnWidth: CGFloat = 34
    /// Width of the trailing reset-countdown column (`resets in 2h 14m`).
    static let countdownColumnWidth: CGFloat = 92
    /// The two trailing quota columns merged into one, for a row whose value is
    /// wider than a percentage and has no countdown to show — the usage-credits
    /// row's `€0.00 of €33.00`. Spans exactly the same pixels, so its value
    /// still ends flush with the countdowns above it.
    static let percentAndCountdownColumnWidth: CGFloat =
        percentColumnWidth + rowSpacing + countdownColumnWidth
    /// Width of the trailing numeric column (token counts).
    static let valueColumnWidth: CGFloat = 74
    /// Width of the token column in the "By model" section — wider than
    /// ``valueColumnWidth`` to fit the larger all-time token counts shown there.
    static let modelTokenColumnWidth: CGFloat = valueColumnWidth + 24
    /// Width of the cost column in the "By model" section. Wide enough for
    /// 4-digit spend (`$1234.56`) — a heavy cache-read day can push a single
    /// model's estimate well past the `$3.15`-sized figures this used to be
    /// sized for.
    static let costColumnWidth: CGFloat = 76
    static let rowSpacing: CGFloat = 8
    static let sectionSpacing: CGFloat = 10

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
