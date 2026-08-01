import ClaudeStatsCore
import SwiftUI

/// The Claude mark as a SwiftUI `Shape`, so it inherits `foregroundStyle` and
/// scales to whatever frame it is given — monochrome by construction.
///
/// Geometry comes from ``ClaudeMark`` (generated from `assets/claude-mark.svg`).
struct ClaudeMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        guard let cgPath = ClaudeMark.path(fitting: rect) else { return Path() }
        return Path(cgPath)
    }
}

extension ClaudeMarkShape {
    /// The mark fills its frame; `fill` must use even-odd to match the SVG's
    /// `fill-rule`.
    static let fillStyle = FillStyle(eoFill: true)
}

/// Convenience wrapper that applies the correct fill rule and keeps the mark
/// square, since callers almost always want exactly that.
struct ClaudeMarkView: View {
    var size: CGFloat

    var body: some View {
        ClaudeMarkShape()
            .fill(style: ClaudeMarkShape.fillStyle)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Claude mark") {
    HStack(spacing: 12) {
        ClaudeMarkView(size: 12)
        ClaudeMarkView(size: 16)
        ClaudeMarkView(size: 32)
        ClaudeMarkView(size: 64)
    }
    .padding()
}
#endif
