import AppKit
import ClaudeStatsCore
import SwiftUI
import XCTest

@testable import ClaudeStats

/// Renders the README's images from the real views and the real mocks.
///
/// Not a test in the assert-something sense — it is the repo's screenshot
/// generator, parked in the test target because that is the only place the
/// app's UI is reachable: `ClaudeStats` is an `executableTarget`, so no second
/// executable can depend on it, and `@testable import` here already grants the
/// internal access a library split would otherwise cost a wide `public` sweep
/// to get. Nothing in this file ships — test targets are never bundled into
/// `ClaudeStats.app`.
///
/// Skipped unless `CLAUDE_STATS_RENDER_ASSETS` names an output directory, so a
/// plain `swift test` neither writes files nor pays for the render. Drive it
/// with `bash scripts/render-readme-assets.sh`.
@MainActor
final class ReadmeAssetRenderTests: XCTestCase {
    /// Pinned so every time-derived string in the popover (the reset
    /// countdowns, "2h 14m") is identical on every run — the PNGs are committed, and a
    /// live clock would dirty the tree on each render.
    private static let renderDate = Date(timeIntervalSince1970: 1_756_600_000)

    /// 4× so the images stay crisp on a Retina README at their natural size.
    private static let renderScale: CGFloat = 4

    // MARK: - Composite geometry (points; scaled up at draw time)

    /// Menu bar strip height. macOS's own is 24 pt, and ``MenuBarGlyph/height``
    /// is 18, so the glyph sits with a 3 pt margin top and bottom exactly as it
    /// does on screen.
    private static let menuBarHeight: CGFloat = 24
    /// Clearance between the strip and the popover's tail, as AppKit leaves.
    private static let menuBarToTail: CGFloat = 5
    /// Room for the card's shadow to fall.
    private static let sidePadding: CGFloat = 18
    private static let bottomPadding: CGFloat = 18

    func testRenderReadmeAssets() throws {
        guard let outPath = ProcessInfo.processInfo.environment["CLAUDE_STATS_RENDER_ASSETS"] else {
            throw XCTSkip("set CLAUDE_STATS_RENDER_ASSETS=<dir> to render the README assets")
        }
        let outDir = URL(fileURLWithPath: outPath, isDirectory: true)

        let now = Self.renderDate
        // One snapshot behind every image, so the glyph's bars and the
        // popover's rows can never show different numbers.
        let snapshot = MockQuotaProvider.sampleShowcaseSnapshot(now: now)
        let glyph = MenuBarGlyph.image(for: snapshot)

        for theme in Theme.all {
            let ink = try XCTUnwrap(tinted(glyph, with: theme.ink), "\(theme.name) glyph")

            let composite = try renderComposite(theme: theme, glyph: ink, now: now)
            try write(composite, to: outDir, named: "screenshot-popover-\(theme.name).png")
        }
    }

    // MARK: - Themes

    /// One rendered appearance, end to end.
    ///
    /// Both are produced every run: GitHub serves READMEs in a light and a dark
    /// theme, and a single image is wrong in one of them — the menu bar strip
    /// especially, which is the desktop tint showing through and so is lighter
    /// or darker with the system appearance rather than a fixed color.
    private struct Theme {
        let name: String
        let appearance: NSAppearance.Name
        let colorScheme: ColorScheme
        /// Glyph ink — the status item is a template image, tinted by the menu
        /// bar to contrast with it.
        let ink: NSColor
        let cardFill: Color
        let cardStroke: Color
        /// Left-to-right gradient across the menu bar strip. Horizontal, not
        /// vertical: these are the desktop's own colors showing through, and a
        /// wallpaper sweeps across the screen — over 24 pt of height a vertical
        /// fade would not read at all.
        let menuBarStops: [NSColor]

        static let all: [Theme] = [light, dark]

        /// The strip's stops are the desktop tint measured off the real menu
        /// bar on the maintainer's machine.
        static let dark = Theme(
            name: "dark",
            appearance: .darkAqua,
            colorScheme: .dark,
            ink: .white,
            cardFill: Color(white: 0.07),
            cardStroke: Color.white.opacity(0.16),
            menuBarStops: [
                NSColor(srgbRed: 0x7E / 255, green: 0x78 / 255, blue: 0xA7 / 255, alpha: 1),
                NSColor(srgbRed: 0x48 / 255, green: 0x85 / 255, blue: 0xBA / 255, alpha: 1),
                NSColor(srgbRed: 0x28 / 255, green: 0x6A / 255, blue: 0xA7 / 255, alpha: 1),
            ]
        )

        /// Same wallpaper, light appearance: macOS lays a light wash over the
        /// menu bar instead of a dark one, so every stop is blended 40% toward
        /// white and the glyph flips to black ink.
        static let light = Theme(
            name: "light",
            appearance: .aqua,
            colorScheme: .light,
            ink: .black,
            cardFill: Color(white: 0.96),
            cardStroke: Color.black.opacity(0.12),
            menuBarStops: [
                NSColor(srgbRed: 0xB2 / 255, green: 0xAE / 255, blue: 0xCA / 255, alpha: 1),
                NSColor(srgbRed: 0x91 / 255, green: 0xB6 / 255, blue: 0xD6 / 255, alpha: 1),
                NSColor(srgbRed: 0x7E / 255, green: 0xA6 / 255, blue: 0xCA / 255, alpha: 1),
            ]
        )
    }

    // MARK: - Composite

    /// Menu bar strip, the status item glyph sitting in it, and the popover
    /// hanging below with its tail pointing back up at the glyph.
    private func renderComposite(theme: Theme, glyph: CGImage, now: Date) throws -> CGImage {
        let card = try renderCard(theme: theme, now: now)
        let scale = Self.renderScale

        let menuBarHeight = (Self.menuBarHeight * scale).rounded()
        let gap = (Self.menuBarToTail * scale).rounded()
        let sidePadding = (Self.sidePadding * scale).rounded()
        let bottomPadding = (Self.bottomPadding * scale).rounded()

        let cardSize = CGSize(width: CGFloat(card.width), height: CGFloat(card.height))
        let width = cardSize.width + sidePadding * 2
        let height = menuBarHeight + gap + cardSize.height + bottomPadding

        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: Int(width),
            height: Int(height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))

        // Core Graphics is y-up: the strip is at the *top* of the canvas.
        let strip = CGRect(x: 0, y: height - menuBarHeight, width: width, height: menuBarHeight)
        let stops = theme.menuBarStops
        let locations = stops.indices.map { CGFloat($0) / CGFloat(stops.count - 1) }
        let gradient = try XCTUnwrap(CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            colors: stops.map(\.cgColor) as CFArray,
            locations: locations
        ))
        context.saveGState()
        context.clip(to: strip)
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: strip.minX, y: strip.midY),
            end: CGPoint(x: strip.maxX, y: strip.midY),
            options: []
        )
        context.restoreGState()

        // Centred, so it lines up with the popover's tail below it — the card
        // is centred on the canvas and its tail is centred on the card.
        let glyphRect = CGRect(
            x: ((width - CGFloat(glyph.width)) / 2).rounded(),
            y: (strip.minY + (menuBarHeight - CGFloat(glyph.height)) / 2).rounded(),
            width: CGFloat(glyph.width),
            height: CGFloat(glyph.height)
        )
        context.draw(glyph, in: glyphRect)

        // Drawn last, and with the shadow, so the popover casts onto the strip
        // the way the real one does.
        context.setShadow(
            // y-up, so a negative dy falls *downward* on screen.
            offset: CGSize(width: 0, height: -4 * scale),
            blur: 10 * scale,
            color: NSColor.black.withAlphaComponent(theme.colorScheme == .dark ? 0.5 : 0.28).cgColor
        )
        context.draw(
            card,
            in: CGRect(x: sidePadding, y: bottomPadding, width: cardSize.width, height: cardSize.height)
        )

        return try XCTUnwrap(context.makeImage())
    }

    /// The popover card on its own, transparent outside the rounded body.
    ///
    /// Rendered through a real `NSHostingView` in an offscreen window rather
    /// than `ImageRenderer`. That started as a hard requirement — the "This Mac"
    /// section had a `.pickerStyle(.segmented)` `Picker`, an AppKit
    /// `NSSegmentedControl` behind an `NSViewRepresentable`, which
    /// `ImageRenderer` paints as SwiftUI's yellow "unsupported view"
    /// placeholder. That picker is gone (the section is a chart now), but
    /// the hosting view stays: it is the same AppKit draw path the shipping
    /// popover uses, and it is what carries the `NSAppearance` the next
    /// comment depends on — `ImageRenderer` exposes a SwiftUI environment, not
    /// an AppKit appearance, and `PopoverMetrics.brandLinkColor` resolves
    /// against the latter.
    ///
    /// The 4× comes from the `NSBitmapImageRep` being allocated at
    /// `pixelsWide/High = points × scale` while its `size` stays in points —
    /// `cacheDisplay(in:to:)` then draws into it at that resolution.
    private func renderCard(theme: Theme, now: Date) throws -> CGImage {
        let card = PopoverCard(
            model: .previewShowcase(now: now),
            clock: PopoverClock(now: now),
            colorScheme: theme.colorScheme,
            fill: theme.cardFill,
            stroke: theme.cardStroke
        )
        let appearance = try XCTUnwrap(NSAppearance(named: theme.appearance))

        let hosting = NSHostingView(rootView: card)
        // Drives both the AppKit controls and, through NSHostingView, SwiftUI's
        // colorScheme — and resolves `PopoverMetrics.brandLinkColor`, a dynamic
        // `NSColor(name:)` that reads the AppKit appearance rather than the
        // SwiftUI environment.
        hosting.appearance = appearance
        hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)

        // A window, not a bare view: AppKit controls draw their backdrop and
        // appearance-derived colors off the window they belong to.
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        let scale = Self.renderScale
        let bounds = hosting.bounds
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((bounds.width * scale).rounded()),
            pixelsHigh: Int((bounds.height * scale).rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        rep.size = bounds.size
        hosting.cacheDisplay(in: bounds, to: rep)

        return try XCTUnwrap(rep.cgImage)
    }

    // MARK: - Glyph

    /// Recolors the status item's template image (black ink + alpha) into
    /// `color`, at ``renderScale``, keeping the background transparent.
    ///
    /// The dev-build dot is not drawn here and cannot be: it is a separate
    /// `NSView` overlay that ``StatusItemController`` adds to the status
    /// button, never part of ``MenuBarGlyph``'s image.
    ///
    /// `.sourceIn` rather than a second draw: it repaints only where the glyph
    /// already put ink, so the alpha ramp on the anti-aliased mark edges and on
    /// the bars' faint unused tracks survives intact.
    private func tinted(_ template: NSImage, with color: NSColor) -> CGImage? {
        let size = template.size
        let scale = Self.renderScale
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((size.width * scale).rounded()),
            pixelsHigh: Int((size.height * scale).rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context

        let rect = NSRect(origin: .zero, size: size)
        template.draw(in: rect)

        let cgContext = context.cgContext
        cgContext.setBlendMode(.sourceIn)
        cgContext.setFillColor(color.cgColor)
        cgContext.fill(rect)

        return rep.cgImage
    }

    // MARK: - Output

    private func write(_ image: CGImage, to directory: URL, named name: String) throws {
        let data = try XCTUnwrap(
            NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
            "could not encode \(name)"
        )
        try data.write(to: directory.appendingPathComponent(name))
    }
}

// MARK: - Popover chrome

/// The popover's frame — rounded body, tail, hairline border — redrawn for the
/// screenshot.
///
/// `NSPopover` owns all of this at runtime; ``PopoverView`` is only the
/// content, so rendering it alone would produce a bare stack of rows. The drop
/// shadow is not here: it is a Core Graphics pass in the composite, because
/// `cacheDisplay(in:to:)` captures the view's own drawing and does not reliably
/// composite the layer-level shadow SwiftUI installs for a `.shadow`.
///
/// Deliberately confined to this file rather than added to the app: the real
/// popover must keep AppKit's own chrome (vibrancy, the tail aligned to the
/// actual status item), not a hand-drawn copy of it.
private struct PopoverCard: View {
    let model: AppModel
    let clock: PopoverClock
    let colorScheme: ColorScheme
    let fill: Color
    let stroke: Color

    private static let cornerRadius: CGFloat = 12
    private static let tailWidth: CGFloat = 22
    private static let tailHeight: CGFloat = 11

    var body: some View {
        let shape = PopoverCardShape(
            cornerRadius: Self.cornerRadius,
            tailWidth: Self.tailWidth,
            tailHeight: Self.tailHeight
        )
        return PopoverView(model: model, clock: clock)
            .padding(.top, Self.tailHeight)
            .background(shape.fill(fill))
            .overlay(shape.stroke(stroke, lineWidth: 1))
            // 1pt inset so the border stroke is not clipped by the view bounds.
            .padding(1)
            .environment(\.colorScheme, colorScheme)
    }
}

/// Rounded rectangle with a pointed, round-tipped tail centred on its top edge
/// — one closed path, so the border strokes the tail's sides too rather than
/// cutting straight across its base.
private struct PopoverCardShape: Shape {
    let cornerRadius: CGFloat
    let tailWidth: CGFloat
    let tailHeight: CGFloat
    /// Rounds the tail's point; the real popover's is not a sharp spike.
    private let tipRadius: CGFloat = 2.5

    func path(in rect: CGRect) -> Path {
        let body = CGRect(
            x: rect.minX,
            y: rect.minY + tailHeight,
            width: rect.width,
            height: rect.height - tailHeight
        )
        let midX = rect.midX

        var path = Path()
        path.move(to: CGPoint(x: body.minX, y: body.minY + cornerRadius))
        path.addArc(
            tangent1End: CGPoint(x: body.minX, y: body.minY),
            tangent2End: CGPoint(x: body.minX + cornerRadius, y: body.minY),
            radius: cornerRadius
        )
        path.addLine(to: CGPoint(x: midX - tailWidth / 2, y: body.minY))
        path.addArc(
            tangent1End: CGPoint(x: midX, y: rect.minY),
            tangent2End: CGPoint(x: midX + tailWidth / 2, y: body.minY),
            radius: tipRadius
        )
        path.addLine(to: CGPoint(x: midX + tailWidth / 2, y: body.minY))
        path.addLine(to: CGPoint(x: body.maxX - cornerRadius, y: body.minY))
        path.addArc(
            tangent1End: CGPoint(x: body.maxX, y: body.minY),
            tangent2End: CGPoint(x: body.maxX, y: body.minY + cornerRadius),
            radius: cornerRadius
        )
        path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - cornerRadius))
        path.addArc(
            tangent1End: CGPoint(x: body.maxX, y: body.maxY),
            tangent2End: CGPoint(x: body.maxX - cornerRadius, y: body.maxY),
            radius: cornerRadius
        )
        path.addLine(to: CGPoint(x: body.minX + cornerRadius, y: body.maxY))
        path.addArc(
            tangent1End: CGPoint(x: body.minX, y: body.maxY),
            tangent2End: CGPoint(x: body.minX, y: body.maxY - cornerRadius),
            radius: cornerRadius
        )
        path.closeSubpath()
        return path
    }
}
