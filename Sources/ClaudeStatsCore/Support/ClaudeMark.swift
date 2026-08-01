import CoreGraphics
import Foundation

/// The Claude wordmark glyph, used for the menu bar status item and as the
/// source geometry for generated app icon sizes.
///
/// ``pathData`` and ``viewBox`` are a verbatim copy of the single `<path d="…">`
/// and `viewBox` in `assets/claude-mark.svg`, which stays the source of truth
/// (see `AGENTS.md`). To update the mark, replace the SVG and re-copy both
/// values — only the line wrapping is cosmetic, the concatenated string must
/// stay character-identical to the attribute:
///
///     python3 -c "import re;print(re.search(r'\sd=\"([^\"]+)\"',
///       open('assets/claude-mark.svg').read()).group(1))"
///
/// `SVGPathParserTests.testClaudeMarkFillsItsViewBox` guards against the two
/// values drifting apart.
///
/// Embedded as a string rather than shipped as an asset-catalog image because
/// SwiftPM's CLI build does not run `actool`: this needs no resource bundle at
/// runtime, stays vector at every menu bar scale and app icon size, and renders
/// identically in SwiftUI previews and in AppKit.
public enum ClaudeMark {
    /// The SVG `viewBox`, i.e. the coordinate space ``pathData`` is authored in.
    public static let viewBox = CGRect(
        x: 0, y: 0, width: 24, height: 24
    )

    /// Raw SVG path data (`fill-rule: evenodd`).
    public static let pathData: String =
        "M4.709 15.955l4.72-2.647.08-.23-.08-.128H9.2l-.79-.048-2.698-.073-2.339-.097-2.266-.122-.571-.12" +
        "1L0 11.784l.055-.352.48-.321.686.06 1.52.103 2.278.158 1.652.097 2.449.255h.389l.055-.157-.134-." +
        "098-.103-.097-2.358-1.596-2.552-1.688-1.336-.972-.724-.491-.364-.462-.158-1.008.656-.722.881.06." +
        "225.061.893.686 1.908 1.476 2.491 1.833.365.304.145-.103.019-.073-.164-.274-1.355-2.446-1.446-2." +
        "49-.644-1.032-.17-.619a2.97 2.97 0 01-.104-.729L6.283.134 6.696 0l.996.134.42.364.62 1.414 1.002" +
        " 2.229 1.555 3.03.456.898.243.832.091.255h.158V9.01l.128-1.706.237-2.095.23-2.695.08-.76.376-.91" +
        ".747-.492.584.28.48.685-.067.444-.286 1.851-.559 2.903-.364 1.942h.212l.243-.242.985-1.306 1.652" +
        "-2.064.73-.82.85-.904.547-.431h1.033l.76 1.129-.34 1.166-1.064 1.347-.881 1.142-1.264 1.7-.79 1." +
        "36.073.11.188-.02 2.856-.606 1.543-.28 1.841-.315.833.388.091.395-.328.807-1.969.486-2.309.462-3" +
        ".439.813-.042.03.049.061 1.549.146.662.036h1.622l3.02.225.79.522.474.638-.079.485-1.215.62-1.64-" +
        ".389-3.829-.91-1.312-.329h-.182v.11l1.093 1.068 2.006 1.81 2.509 2.33.127.578-.322.455-.34-.049-" +
        "2.205-1.657-.851-.747-1.926-1.62h-.128v.17l.444.649 2.345 3.521.122 1.08-.17.353-.608.213-.668-." +
        "122-1.374-1.925-1.415-2.167-1.143-1.943-.14.08-.674 7.254-.316.37-.729.28-.607-.461-.322-.747.32" +
        "2-1.476.389-1.924.315-1.53.286-1.9.17-.632-.012-.042-.14.018-1.434 1.967-2.18 2.945-1.726 1.845-" +
        ".414.164-.717-.37.067-.662.401-.589 2.388-3.036 1.44-1.882.93-1.086-.006-.158h-.055L4.132 18.56l" +
        "-1.13.146-.487-.456.061-.746.231-.243 1.908-1.312-.006.006z"

    /// The mark in ``viewBox`` coordinates. Parsed once; `nil` only if the
    /// generated data were corrupted, which the unit tests guard against.
    public static let cgPath: CGPath? = try? SVGPathParser.cgPath(from: pathData)

    /// The mark scaled to fit `rect`, preserving aspect ratio and centred.
    /// `nil` for a degenerate `rect`, so callers can skip drawing rather than
    /// emit a collapsed path.
    ///
    /// Coordinates stay y-down (SVG convention), which matches SwiftUI's `Path`
    /// space directly; AppKit callers should draw into a flipped context.
    public static func path(fitting rect: CGRect) -> CGPath? {
        guard let cgPath, viewBox.width > 0, viewBox.height > 0 else { return nil }

        let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
        guard scale > 0, scale.isFinite else { return nil }
        let scaledWidth = viewBox.width * scale
        let scaledHeight = viewBox.height * scale
        var transform = CGAffineTransform(
            translationX: rect.minX + (rect.width - scaledWidth) / 2,
            y: rect.minY + (rect.height - scaledHeight) / 2
        )
        .scaledBy(x: scale, y: scale)
        .translatedBy(x: -viewBox.minX, y: -viewBox.minY)

        return cgPath.copy(using: &transform)
    }
}
