import ClaudeStatsCore
import SwiftUI

/// The numbers under a ``DailyUsageChart``: one row per band, in display order,
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
/// it. The dot is the band colour at full strength, where the plot paints the
/// band at ``PopoverMetrics/chartBandOpacity`` to let the gridlines through —
/// a 6 pt circle has nothing behind it to show.
///
/// **The first row is the chart's top band**, and the last the bottom one: the
/// table reads downwards from its first row, the stack reads downwards from its
/// top band, so the two run the same way. It is the stack that is reversed for
/// this, not the table — see ``DailyUsageChart/stackOrder``.
struct DailyUsageTable: View {
    /// Bands in display order, first row first — exactly what the chart was
    /// handed, which draws them bottom-up.
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

    /// The caption at rest — `Last 30 days`, or fewer on a young corpus. Not
    /// shown when ``restingRange`` is ``DefaultDisplayRange/latestDay``, whose
    /// resting caption is the day itself.
    let restingCaption: String

    /// Which window the table reads when the pointer is elsewhere — the
    /// Settings preference, see ``DefaultDisplayRange``.
    ///
    /// It moves the *resting* reading only: hovering a day still shows that
    /// day in either setting, and the chart above draws the whole window
    /// either way, since a one-day plot is a single point with no shape to
    /// read.
    var restingRange: DefaultDisplayRange = .last30Days

    /// One line of the table.
    struct Row: Equatable {
        let label: String
        /// The band's shade, or `nil` on the total row, which has no band.
        let color: Color?
        let usage: TokenUsage
        let cost: Double
    }

    /// One of the two value columns every row ends in.
    ///
    /// A column rather than two hand-written `Text`s per row: the heading, the
    /// width, the figure and what VoiceOver says all belong to the same column,
    /// and the caption row and the value rows have to agree on their order —
    /// which they can only do by construction if there is one order to read.
    enum Column: CaseIterable {
        case estimatedCost
        case tokens

        /// The heading over the column, in the caption row.
        var heading: String {
            switch self {
            case .estimatedCost: return "Estimated cost"
            case .tokens: return "Tokens"
            }
        }

        /// Reserved width — see ``PopoverMetrics/tableCostColumnWidth`` and
        /// ``PopoverMetrics/tableTokenColumnWidth`` for how each was measured.
        var width: CGFloat {
            switch self {
            case .estimatedCost: return PopoverMetrics.tableCostColumnWidth
            case .tokens: return PopoverMetrics.tableTokenColumnWidth
            }
        }

        /// Whether the figure is set in secondary ink. The token counts are:
        /// money is the reading the "By model" block exists for, and two
        /// columns at full strength make the row read as two headlines.
        var isSecondary: Bool {
            switch self {
            case .estimatedCost: return false
            case .tokens: return true
            }
        }

        func text(of row: Row) -> String {
            switch self {
            case .estimatedCost: return DisplayFormat.cost(row.cost)
            case .tokens: return DisplayFormat.tokens(row.usage.totalTokens)
            }
        }

        /// The same figure with its unit spelled out, for VoiceOver — which
        /// reads a row without the headings above it.
        func spokenValue(of row: Row) -> String {
            switch self {
            case .estimatedCost: return "\(DisplayFormat.cost(row.cost)) estimated"
            case .tokens: return "\(DisplayFormat.tokens(row.usage.totalTokens)) tokens"
            }
        }
    }

    /// The value columns left to right: **money first, tokens second**.
    ///
    /// The two used to run the other way. Cost is the figure a reader of this
    /// card comes for and the wider column of the two (74 pt against 48, sized
    /// by its spelled-out heading), so putting it first ends the rows on the
    /// narrow column and leaves the slack next to the labels — which is where
    /// a sparkline or a bar at the head of a table would have to go.
    ///
    /// One order for both blocks and for the caption row, so "same columns in
    /// the same places" stays a fact rather than a convention two pieces of
    /// code happen to agree on.
    static let columnOrder: [Column] = [.estimatedCost, .tokens]

    /// Where the pointer is in the current window, or `nil` at rest.
    ///
    /// Re-resolved every render rather than remembered: a poll — or midnight
    /// sliding the window — must drop the readout back to resting instead of
    /// stranding a number from a window that has moved.
    var hoveredIndex: Int? { PopoverChartHover.index(of: hoveredDay, in: days) }

    /// The day the table reads at rest, or `nil` when it reads the whole
    /// window — the last plotted day under ``DefaultDisplayRange/latestDay``.
    ///
    /// The *last* day rather than a stored date: "latest" has to follow the
    /// window, or the setting would strand the table on yesterday the moment
    /// midnight slid it.
    var restingIndex: Int? {
        guard restingRange == .latestDay else { return nil }
        return days.indices.last
    }

    /// The day every figure in the table is for, or `nil` for the whole
    /// window. Hover wins over the resting preference: the pointer is a
    /// deliberate act, the setting is a default.
    var shownIndex: Int? { hoveredIndex ?? restingIndex }

    /// The leading caption: which window every number in the table is for.
    ///
    /// This is the whole hover disclosure. The caption already made that claim,
    /// so swapping it says the numbers changed meaning — no floating tooltip
    /// over a 72 pt plot, and no second styling vocabulary. It is also what
    /// says the table is showing one day rather than the window when the
    /// preference is set that way — a single day's figures under `Last 30 days`
    /// would simply be wrong.
    var caption: String {
        guard let index = shownIndex, index < days.count else { return restingCaption }
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

    /// One series' reading: the shown day's point (hovered, or the latest one
    /// when the preference asks for a single day), or the whole window summed.
    ///
    /// ``Sequence/summed()`` rather than a second pass over the corpus — the
    /// points are already in hand, and folding them here is what let the tables
    /// be a pure UI change.
    private func reading(of points: [DailyUsagePoint]) -> DailyUsageTotals {
        if let index = shownIndex, index < points.count {
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
                // The caption is a *number* half the time — the hovered day's
                // date, and a day count at rest — so it takes the monospaced
                // digits every other figure in the table is set in. The
                // headings beside it are words and keep the proportional font.
                .font(PopoverMetrics.captionValueFont)
            Spacer(minLength: PopoverMetrics.rowSpacing)
            ForEach(Self.columnOrder, id: \.self) { column in
                Text(column.heading)
                    .frame(width: column.width, alignment: .trailing)
            }
        }
        .font(PopoverMetrics.captionFont)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Window")
        .accessibilityValue(caption)
    }

    /// What VoiceOver reads for one row: both figures, in ``columnOrder``.
    func spokenValue(of row: Row) -> String {
        Self.columnOrder.map { $0.spokenValue(of: row) }.joined(separator: ", ")
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
            ForEach(Self.columnOrder, id: \.self) { column in
                Text(column.text(of: row))
                    .font(PopoverMetrics.valueFont)
                    .foregroundStyle(column.isSecondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .frame(width: column.width, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .combine)
        // The caption is in the label, not just on the caption row: VoiceOver
        // reads one row at a time, and a bare "18k, $0.42" says neither which
        // band nor which window.
        .accessibilityLabel("\(row.label), \(caption)")
        // Spoken in column order, so what VoiceOver reads and what the eye
        // sees can't disagree about which figure comes first.
        .accessibilityValue(spokenValue(of: row))
        // The four-way token split, which used to hang on the old table's
        // cells. It follows the hovered day like everything else in the row, or
        // tooltip and row would contradict each other on screen.
        .help(DisplayFormat.tokenSplit(row.usage))
    }
}
