import AppKit
import SwiftUI
import XCTest

@testable import ClaudeStats

/// Pixels per point in every render the pixel tests do. 4×, so a tolerance
/// under a point is still whole pixels — and the same ratio
/// ``ReadmeAssetRenderTests`` uses, so what these measure is what the committed
/// screenshots show.
let popoverRenderScale: CGFloat = 4

/// The width a chart gets inside the popover. Every offset measured off these
/// renders is a fraction of the plot, so it has to be measured at the shipping
/// size.
///
/// File scope rather than a member of ``PopoverPixels``, so it can be a default
/// argument of a `nonisolated` signature.
let popoverContentWidth = PopoverMetrics.popoverWidth - 2 * PopoverMetrics.contentPadding

/// Draws a popover view offscreen and hands back its pixels.
///
/// Shared by ``PopoverChartAlignmentTests``, which measures where a chart put
/// its marks, and ``PopoverInkTests``, which measures what colour things came
/// out — two questions, one draw path. That path is an `NSHostingView` in a
/// borderless window, which is what the shipping popover uses and what carries
/// the `NSAppearance` every dynamic `NSColor` in the tree resolves against;
/// `ImageRenderer` offers a SwiftUI environment instead and would paint the
/// wrong theme's terracotta.
@MainActor
enum PopoverPixels {
    /// Pixels of a rendered popover view, and the measurements the pixel tests
    /// take off them.
    ///
    /// Luminance for everything about *where* ink landed, the raw channels for the
    /// one question that is about hue — whether a pixel is a terracotta band or
    /// something else the popover drew.
    struct Bitmap {
        let width: Int
        let height: Int
        /// 0 is black, 1 is white, row-major.
        let luminance: [Double]
        /// The same pixels unmixed, for the one measurement that is about hue
        /// rather than brightness — telling a chart band from everything else
        /// the popover draws.
        let channels: [(red: Double, green: Double, blue: Double)]

        /// Faint on purpose: a gridline is drawn at 0.12 opacity, so a
        /// threshold anywhere near mid-grey would miss the plot's own edges.
        private static let inkThreshold = 0.97

        func isInk(_ x: Int, _ y: Int) -> Bool { luminance[y * width + x] < Self.inkThreshold }

        /// One pixel's luminance.
        func luminance(_ x: Int, _ y: Int) -> Double { luminance[y * width + x] }

        /// Whether this pixel is a chart band painted at full strength: band
        /// ink is terracotta, and a band the card is bleeding into is darker
        /// than the palest shade the ramp can produce.
        ///
        /// The hue test alone is not enough — the quota bars and the Claude
        /// mark are terracotta too — which is why the seam scan also restricts
        /// itself to ``bandRows()``.
        func isBandInk(_ x: Int, _ y: Int, floor: Double) -> Bool {
            isTerracotta(x, y) && luminance(x, y) >= floor
        }

        /// One pixel's colour, unmixed.
        func rgb(_ x: Int, _ y: Int) -> (red: Double, green: Double, blue: Double) {
            channels[y * width + x]
        }

        /// Terracotta rather than ink or card: red clearly over green, green
        /// clearly over blue. The thresholds are set against the *palest* shade
        /// of the muted ramp seen through ``PopoverMetrics/chartBandOpacity``
        /// (red−green ≈ 0.085 there), which is the tightest pixel the popover
        /// paints; the card, the text and the gridlines are neutral and clear
        /// none of it.
        func isTerracotta(_ x: Int, _ y: Int) -> Bool {
            let pixel = channels[y * width + x]
            return pixel.red > pixel.green + 0.05 && pixel.green > pixel.blue + 0.02
        }

        /// Rows that a chart band crosses — the only rows in the popover with a
        /// terracotta run most of the card wide.
        ///
        /// A stacked band spans the plot, which is ~250 of the 312 pt content
        /// width. The widest terracotta thing that is *not* a band is a full
        /// quota bar at 100 pt, so 60% of the card separates them with room to
        /// spare.
        func bandRows() -> Set<Int> {
            var rows: Set<Int> = []
            let needed = Int(0.6 * Double(width))
            for y in 0..<height {
                var run = 0
                for x in 0..<width {
                    run = isTerracotta(x, y) ? run + 1 : 0
                    if run > needed {
                        rows.insert(y)
                        break
                    }
                }
            }
            return rows
        }

        /// The x of the tallest column of pixels that differ from `other` — the
        /// hover rule, which spans the plot's whole height while the dots on it
        /// are a few rows each.
        ///
        /// The centre of the run rather than its darkest column: a 0.5 pt
        /// stroke is 2 px here and anti-aliasing spreads it over three.
        func tallestDifference(from other: Bitmap) -> CGFloat? {
            guard other.width == width, other.height == height else { return nil }
            let changed = (0..<width).map { x in
                (0..<height).reduce(0) { $0 + (abs(luminance[$1 * width + x] - other.luminance[$1 * width + x]) > 0.01 ? 1 : 0) }
            }
            let floor = height / 4
            guard let peak = changed.indices.max(by: { changed[$0] < changed[$1] }), changed[peak] > floor else { return nil }
            var left = peak, right = peak
            while left > 0, changed[left - 1] > floor { left -= 1 }
            while right < width - 1, changed[right + 1] > floor { right += 1 }
            return CGFloat(left + right) / 2
        }

        /// The leftmost and rightmost columns that differ from `other` — the
        /// full width of what hover drew, rule and dots together.
        func differenceExtent(from other: Bitmap) -> (first: CGFloat, last: CGFloat)? {
            guard other.width == width, other.height == height else { return nil }
            let changed = (0..<width).filter { x in
                (0..<height).contains { abs(luminance[$0 * width + x] - other.luminance[$0 * width + x]) > 0.01 }
            }
            guard let first = changed.first, let last = changed.last else { return nil }
            return (CGFloat(first), CGFloat(last))
        }

        /// The x each x-axis tick is centred on, left to right.
        ///
        /// Sampled from a row halfway down the ticks' own 3 pt — below the plot,
        /// above the dated labels — with everything left of the plot dropped,
        /// since the leading y-axis labels reach into those rows too.
        func axisTickColumns() throws -> [CGFloat] {
            let plot = try plotEdges()
            let tickRow = plot.bottom + Int(PopoverMetrics.chartTickLength * popoverRenderScale) / 2
            // Loud rather than clamped: a layout leaving fewer rows below the
            // baseline than half a tick would index past the bitmap and crash
            // inside `isInk`, while sampling the last row instead would
            // quietly measure something that is not the ticks.
            let row = try XCTUnwrap(
                tickRow < height ? tickRow : nil,
                "tick row \(tickRow) is outside the \(height) px render"
            )
            let columns = inkColumns(inRow: row).filter { $0 >= plot.left }
            return runs(in: columns).map { CGFloat($0.first! + $0.last!) / 2 }
        }

        /// Where the plotted days start — the leading end of the horizontal
        /// lines, which run from the first day to the last.
        func dataLeadingEdge() throws -> CGFloat { CGFloat(try plotEdges().left) }

        /// Both ends of the chart's horizontal lines.
        func horizontalLineExtent() throws -> (first: CGFloat, last: CGFloat) {
            let edges = try plotEdges()
            return (CGFloat(edges.left), CGFloat(edges.right))
        }

        /// The plot's own edges and its baseline.
        ///
        /// All three read off the widest rows of ink in the image, which are
        /// the chart's horizontal lines: they run the length of the data and
        /// nothing else in the chart is that wide.
        private func plotEdges() throws -> (left: Int, right: Int, bottom: Int) {
            var widest: [Int] = []
            var bottom = 0
            for y in 0..<height {
                let columns = inkColumns(inRow: y)
                guard columns.count > width / 2 else { continue }
                if columns.count >= widest.count { widest = columns }
                bottom = max(bottom, y)
            }
            let gridline = try XCTUnwrap(runs(in: widest).max { $0.count < $1.count }, "no gridline to measure the plot by")
            return (gridline.first!, gridline.last!, bottom)
        }

        private func inkColumns(inRow row: Int) -> [Int] {
            (0..<width).filter { isInk($0, row) }
        }

        /// Consecutive columns grouped, so a 2 px stroke smeared over three
        /// columns by anti-aliasing counts once.
        private func runs(in columns: [Int]) -> [[Int]] {
            columns.reduce(into: [[Int]]()) { runs, column in
                if runs.last?.last == column - 1 {
                    runs[runs.count - 1].append(column)
                } else {
                    runs.append([column])
                }
            }
        }
    }

    /// Draws `view` on an opaque card at ``popoverRenderScale``.
    ///
    /// White and `.light` by default rather than the popover's own material:
    /// the alignment measurements are after `Color.primary` strokes at low
    /// opacity, and finding a faint line's centre wants the most contrast
    /// available. The seam and ink measurements ask for a real card instead,
    /// because what they are after is which colour landed where — and a seam is
    /// the *background* showing between two bands, which only the dark card is
    /// dark enough to reveal.
    static func render(
        _ view: some View,
        width: CGFloat = popoverContentWidth,
        appearance: NSAppearance.Name = .aqua,
        background: Color = .white
    ) throws -> Bitmap {
        let hosting = NSHostingView(
            rootView: view
                .frame(width: width)
                .background(background)
                .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
        )
        hosting.appearance = NSAppearance(named: appearance)
        hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)

        // A window, not a bare view: AppKit resolves appearance-derived colors
        // off the window a view belongs to.
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = hosting.appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        let bounds = hosting.bounds
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((bounds.width * popoverRenderScale).rounded()),
            pixelsHigh: Int((bounds.height * popoverRenderScale).rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        // Points for `size`, pixels for the buffer — `cacheDisplay(in:to:)`
        // then draws at `scale`, the trick ``ReadmeAssetRenderTests`` uses.
        rep.size = bounds.size
        hosting.cacheDisplay(in: bounds, to: rep)

        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        let bytesPerRow = rep.bytesPerRow
        let samples = rep.samplesPerPixel
        let data = try XCTUnwrap(rep.bitmapData)
        var luminance = [Double](repeating: 1, count: width * height)
        var channels = [(red: Double, green: Double, blue: Double)](
            repeating: (1, 1, 1),
            count: width * height
        )
        for y in 0..<height {
            for x in 0..<width {
                let pixel = data + y * bytesPerRow + x * samples
                luminance[y * width + x] = Double(Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / (3 * 255)
                channels[y * width + x] = (
                    Double(pixel[0]) / 255,
                    Double(pixel[1]) / 255,
                    Double(pixel[2]) / 255
                )
            }
        }
        return Bitmap(width: width, height: height, luminance: luminance, channels: channels)
    }
}
