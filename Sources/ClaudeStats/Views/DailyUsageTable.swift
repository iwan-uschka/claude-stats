import ClaudeStatsCore
import SwiftUI

/// The numbers under a ``DailyUsageChart``: one row per band, in stack order,
/// plus the total the bands add up to.
///
/// Both popover blocks use it, with the same columns in the same places, so the
/// two read as one table split in two rather than as two designs. Every number
/// in it is the *same window* as the chart above — thirty days at rest, the
/// hovered day while the pointer is in that chart — which is the rule that
/// replaced the popover's old mixture of 5-hour, fixed-24h and 30-day readings.
///
/// A dot in the band's own shade ties each row to its area in the plot; the
/// total row has none, because it is the stack's outline rather than a band in
/// it. Rows are in stack order, bottom band first, so the eye reading the chart
/// downwards meets the rows in the same sequence.
struct DailyUsageTable: View {
    /// Bands in stack order, bottom first — exactly what the chart was handed.
    let series: [DailyUsageSeries]

    /// The whole window's points, whatever their band. Summed independently of
    /// ``series`` rather than added up from it, so the `Total` row is the
    /// history's own total and a band the split dropped would show as a
    /// mismatch instead of hiding.
    let total: [DailyUsagePoint]

    /// The days the chart plots — the axis the hovered day is resolved against.
    let days: [Date]

    /// The day the pointer is on in *this block's* chart. Hovering one block
    /// leaves the other's table alone: a table rewriting itself under a pointer
    /// that is somewhere else entirely would be a surprise.
    var hoveredDay: Date?

    /// The caption at rest — `Last 30 days`, or fewer on a young corpus.
    let restingCaption: String

    /// One line of the table.
    struct Row: Equatable {
        let label: String
        /// The band's shade, or `nil` on the total row, which has no band.
        let color: Color?
        let usage: TokenUsage
        let cost: Double
    }

    /// Where the pointer is in the current window, or `nil` at rest.
    ///
    /// Re-resolved every render rather than remembered: a poll — or midnight
    /// sliding the window — must drop the readout back to resting instead of
    /// stranding a number from a window that has moved.
    var hoveredIndex: Int? { PopoverChartHover.index(of: hoveredDay, in: days) }

    /// The leading caption: which window every number in the table is for.
    ///
    /// This is the whole hover disclosure. The caption already made that claim,
    /// so swapping it says the numbers changed meaning — no floating tooltip
    /// over a 72 pt plot, and no second styling vocabulary.
    var caption: String {
        guard let index = hoveredIndex, index < days.count else { return restingCaption }
        return PopoverChartHover.label(for: days[index])
    }

    var bandRows: [Row] {
        series.map { band in
            let reading = reading(of: band.points)
            return Row(
                label: band.label,
                color: band.color,
                usage: reading.usage,
                cost: reading.estimatedCostUSD
            )
        }
    }

    var totalRow: Row {
        let reading = reading(of: total)
        return Row(label: "Total", color: nil, usage: reading.usage, cost: reading.estimatedCostUSD)
    }

    /// What the table is currently showing in total — what the cache-read note
    /// under the "By model" block is computed from, so the note describes the
    /// numbers on screen rather than a window nothing displays.
    var shownUsage: TokenUsage { totalRow.usage }

    /// One series' reading: the hovered day's point, or the whole window summed.
    ///
    /// ``Sequence/summed()`` rather than a second pass over the corpus — the
    /// points are already in hand, and folding them here is what let the tables
    /// be a pure UI change.
    private func reading(of points: [DailyUsagePoint]) -> DailyUsageTotals {
        if let index = hoveredIndex, index < points.count {
            let point = points[index]
            return DailyUsageTotals(usage: point.usage, estimatedCostUSD: point.estimatedCostUSD)
        }
        return points.summed()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverMetrics.tableRowSpacing) {
            captionRow
            ForEach(Array(bandRows.enumerated()), id: \.offset) { _, row in
                tableRow(row)
            }
            tableRow(totalRow)
        }
    }

    /// Caption on the left, column headings on the right.
    ///
    /// The headings are what lets the token column drop the `tok` suffix it
    /// used to carry on every row: a label above the column says it once
    /// instead of once per row, and the width that frees is what the spelled-out
    /// `Estimated cost` needs. Not `Est.` — it is the word doing the work, and
    /// an abbreviation is the first thing an eye skims past.
    private var captionRow: some View {
        HStack(spacing: PopoverMetrics.legendSwatchSpacing) {
            Text(caption)
                .lineLimit(1)
            Spacer(minLength: PopoverMetrics.rowSpacing)
            Text("Tokens")
                .frame(width: PopoverMetrics.tableTokenColumnWidth, alignment: .trailing)
            Text("Estimated cost")
                .frame(width: PopoverMetrics.tableCostColumnWidth, alignment: .trailing)
        }
        .font(PopoverMetrics.captionFont)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Window")
        .accessibilityValue(caption)
    }

    private func tableRow(_ row: Row) -> some View {
        HStack(spacing: PopoverMetrics.legendSwatchSpacing) {
            // The total row keeps the dot's width without its ink, so every
            // label in the column starts at the same x — the dot marks which
            // rows are bands, and an unindented total would read as one.
            Circle()
                .fill(row.color ?? .clear)
                .frame(width: PopoverMetrics.legendSwatchSize, height: PopoverMetrics.legendSwatchSize)
            Text(row.label)
                .font(PopoverMetrics.bodyFont)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: PopoverMetrics.rowSpacing)
            Text(DisplayFormat.tokens(row.usage.totalTokens))
                .font(PopoverMetrics.valueFont)
                .foregroundStyle(.secondary)
                .frame(width: PopoverMetrics.tableTokenColumnWidth, alignment: .trailing)
            Text(DisplayFormat.cost(row.cost))
                .font(PopoverMetrics.valueFont)
                .frame(width: PopoverMetrics.tableCostColumnWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        // The caption is in the label, not just on the caption row: VoiceOver
        // reads one row at a time, and a bare "18k, $0.42" says neither which
        // band nor which window.
        .accessibilityLabel("\(row.label), \(caption)")
        .accessibilityValue("\(DisplayFormat.tokens(row.usage.totalTokens)) tokens, \(DisplayFormat.cost(row.cost)) estimated")
        // The four-way token split, which used to hang on the old table's
        // cells. It follows the hovered day like everything else in the row, or
        // tooltip and row would contradict each other on screen.
        .help(DisplayFormat.tokenSplit(row.usage))
    }
}
