import SwiftUI

/// Shared layout constants for the popover, so the label columns of the quota
/// rows, the "This Mac" rows and the "By model" rows line up with each other.
enum PopoverMetrics {
    static let popoverWidth: CGFloat = 340
    static let contentPadding: CGFloat = 14
    /// Width of the leading label column shared by every row type.
    static let labelColumnWidth: CGFloat = 84
    /// Width of the trailing numeric column (token counts).
    static let valueColumnWidth: CGFloat = 74
    /// Width of the token column in the "By model" section — wider than
    /// ``valueColumnWidth`` to fit the larger all-time token counts shown there.
    static let modelTokenColumnWidth: CGFloat = valueColumnWidth + 24
    /// Width of the cost column in the "By model" section.
    static let costColumnWidth: CGFloat = 54
    static let rowSpacing: CGFloat = 8
    static let sectionSpacing: CGFloat = 10

    static let bodyFont = Font.system(size: 11)
    static let valueFont = Font.system(size: 11).monospacedDigit()
    static let sectionTitleFont = Font.system(size: 11, weight: .semibold)
    static let captionFont = Font.system(size: 10)
}
