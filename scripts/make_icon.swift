// Regenerates Sources/ClaudeStats/Assets.xcassets/AppIcon.appiconset/*.png.
//
// Usage (from the repo root):
//
//     bash scripts/make_icon.sh
//
// Deliberately generic: the app icon does NOT use the Claude mark
// (assets/claude-mark.svg, still used for the menu-bar glyph in
// MenuBarGlyph.swift) — a third-party app can't put Anthropic's logo on its
// own icon. Instead this draws three rounded vertical bars, echoing the
// menu-bar glyph's own bar language, on a neutral dark-slate background with
// no brand color reference.
//
// Design: rounded square on the Big Sur icon grid (the artwork square is
// 824/1024 of the canvas, corner radius 185.4/824 of that square), bars
// knocked out in white and inset so nothing touches the edges.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Layout constants

/// Fraction of the full canvas occupied by the rounded square. Apple's macOS
/// icon template draws app artwork at 824pt inside a 1024pt canvas; the
/// surrounding margin is where the system expects the drop shadow to fall.
let squareFraction = 824.0 / 1024.0
/// Corner radius as a fraction of the rounded square's side (185.4 / 824).
let cornerFraction = 185.4 / 824.0

/// Neutral dark-slate gradient, top and bottom — no brand color reference.
let gradientTop = (r: 0.20, g: 0.22, b: 0.26) // #333842
let gradientBottom = (r: 0.10, g: 0.11, b: 0.14) // #1A1C24

/// Bar heights as fractions of the rounded square's side, short-tall-medium
/// (matches the previewed "Option A" candidate), before `groupScale`.
let barHeightFractions: [CGFloat] = [0.45, 0.78, 0.60]
let barWidthFraction = 0.14
let barGapFraction = 0.10
/// Uniform shrink applied to the whole bar group (width, gap, and heights
/// together) so proportions stay the same but the group reads smaller and
/// leaves more quiet zone around it.
let groupScale: CGFloat = 0.62

let sizes = [16, 32, 64, 128, 256, 512, 1024]

let outputDirectory: URL = {
    let repoRoot = URL(fileURLWithPath: CommandLine.arguments.count > 1
        ? CommandLine.arguments[1]
        : FileManager.default.currentDirectoryPath)
    return repoRoot
        .appendingPathComponent("Sources/ClaudeStats/Assets.xcassets/AppIcon.appiconset")
}()

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

// MARK: - Rendering

func renderIcon(size: Int) throws -> CGImage {
    let side = CGFloat(size)
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "make_icon", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "could not create a \(size)×\(size) bitmap context",
        ])
    }

    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    // Flip to a y-down, top-left origin space so the SVG path draws upright.
    context.translateBy(x: 0, y: side)
    context.scaleBy(x: 1, y: -1)

    let squareSide = side * squareFraction
    let squareRect = CGRect(
        x: (side - squareSide) / 2,
        y: (side - squareSide) / 2,
        width: squareSide,
        height: squareSide
    )
    let radius = squareSide * cornerFraction

    let backgroundPath = CGPath(
        roundedRect: squareRect,
        cornerWidth: radius,
        cornerHeight: radius,
        transform: nil
    )

    context.saveGState()
    context.addPath(backgroundPath)
    context.clip()
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    if let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(colorSpace: colorSpace, components: [gradientTop.r, gradientTop.g, gradientTop.b, 1])!,
            CGColor(colorSpace: colorSpace, components: [gradientBottom.r, gradientBottom.g, gradientBottom.b, 1])!,
        ] as CFArray,
        locations: [0, 1]
    ) {
        // y-down space: start at the square's top edge.
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: squareRect.midX, y: squareRect.minY),
            end: CGPoint(x: squareRect.midX, y: squareRect.maxY),
            options: []
        )
    }
    context.restoreGState()

    // Three rounded vertical bars, short-tall-medium, centred as a group on
    // both axes — the group's own bounding box (not each bar's individual
    // height) is what gets centred, so the visual "weight" sits in the
    // middle of the square rather than sitting on a bottom baseline.
    let barWidth = squareSide * barWidthFraction * groupScale
    let barGap = squareSide * barGapFraction * groupScale
    let totalWidth = CGFloat(barHeightFractions.count) * barWidth + CGFloat(barHeightFractions.count - 1) * barGap
    let startX = squareRect.midX - totalWidth / 2

    let groupHeight = squareRect.height * (barHeightFractions.max() ?? 0) * groupScale
    let baseline = squareRect.midY + groupHeight / 2

    context.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1])!)
    for (index, heightFraction) in barHeightFractions.enumerated() {
        let barHeight = squareRect.height * heightFraction * groupScale
        let barRect = CGRect(
            x: startX + CGFloat(index) * (barWidth + barGap),
            y: baseline - barHeight,
            width: barWidth,
            height: barHeight
        )
        let barPath = CGPath(
            roundedRect: barRect,
            cornerWidth: barWidth / 2,
            cornerHeight: barWidth / 2,
            transform: nil
        )
        context.addPath(barPath)
    }
    context.fillPath()

    guard let image = context.makeImage() else {
        throw NSError(domain: "make_icon", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "could not snapshot the \(size)×\(size) context",
        ])
    }
    return image
}

func write(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw NSError(domain: "make_icon", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "could not create a PNG destination at \(url.path)",
        ])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "make_icon", code: 5, userInfo: [
            NSLocalizedDescriptionKey: "could not finalize \(url.path)",
        ])
    }
}

for size in sizes {
    let url = outputDirectory.appendingPathComponent("AppIcon-\(size).png")
    let image = try renderIcon(size: size)
    try write(image, to: url)
    let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
    print("  ✓ AppIcon-\(size).png (\(bytes) bytes)")
}

print("✓ wrote \(sizes.count) PNGs to \(outputDirectory.path)")
