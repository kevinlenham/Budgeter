//
//  CategoryDonutCard.swift
//  Budgeter
//
//  Where the money went this period: a ring for the shape of it, a ranked list for
//  the numbers.
//
//  See `StatisticsView` for the colour rules these follow — in particular that the
//  list is not decoration but the colour-independent version of the same data, so
//  no slice is ever identified by its hue alone.
//

import Charts
import SwiftUI

/// A donut for the shape of the spending, and a ranked list for the numbers.
///
/// The pairing is deliberate rather than decorative. A donut is good at "roughly
/// half of it was one thing" and bad at "was groceries more than fuel"; the list
/// answers the second and doubles as the accessible, colour-independent version of
/// the same data.
struct CategoryBreakdownCard: View {
    let snapshot: StatisticsSnapshot

    /// Slices for the ring: every category that has a hue of its own, plus one
    /// aggregated slice for everything past the ramp. Without the aggregation the
    /// tail would be several separate grey wedges that look like one anyway.
    private struct Slice: Identifiable {
        var id: String
        var amount: Int64
        var colour: Color
    }

    private var slices: [Slice] {
        var hued: [Slice] = []
        var otherTotal: Int64 = 0
        for row in snapshot.categories {
            let colour = snapshot.palette.color(for: row.categoryId)
            if colour == Palette.seriesOther {
                otherTotal += row.amountMinor
            } else {
                hued.append(Slice(id: row.id, amount: row.amountMinor, colour: colour))
            }
        }
        if otherTotal > 0 {
            hued.append(Slice(id: "__other", amount: otherTotal, colour: Palette.seriesOther))
        }
        return hued
    }

    var body: some View {
        if snapshot.categories.isEmpty {
            EmptyStateCard(
                symbol: "chart.pie",
                title: "Nothing to chart",
                message: "Spending in this period will show up here."
            )
        } else {
            Card {
                VStack(alignment: .leading, spacing: 18) {
                    Chart(slices, id: \.id) { slice in
                        SectorMark(
                            angle: .value("Spent", Int(slice.amount)),
                            innerRadius: .ratio(0.62),
                            // A gap in the card colour between wedges, so two
                            // adjacent hues never touch and blend.
                            angularInset: 2
                        )
                        .foregroundStyle(slice.colour)
                        .cornerRadius(3)
                    }
                    .frame(height: 190)
                    .chartBackground { _ in
                        // The total sits in the hole rather than beside the chart:
                        // it is what the ring adds up to, and putting it anywhere
                        // else makes that a claim the reader has to take on trust.
                        VStack(spacing: 2) {
                            Text("Total")
                                .font(.caption)
                                .foregroundStyle(Palette.textSecondary)
                            AmountText(money: snapshot.total, font: .headline)
                        }
                    }
                    .accessibilityLabel("Spending by category")

                    VStack(spacing: 0) {
                        ForEach(Array(snapshot.categories.enumerated()), id: \.element.id) { index, row in
                            if index > 0 {
                                Rectangle().fill(Palette.separator).frame(height: 0.5)
                            }
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(snapshot.palette.color(for: row.categoryId))
                                    .frame(width: 9, height: 9)
                                Text(row.displayName)
                                    .font(.subheadline)
                                    .foregroundStyle(Palette.textPrimary)
                                Spacer(minLength: 8)
                                Text("\(Int((snapshot.share(of: row) * 100).rounded()))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(Palette.textSecondary)
                                AmountText(money: row.amount, font: .subheadline.weight(.semibold))
                                    .frame(minWidth: 78, alignment: .trailing)
                            }
                            .padding(.vertical, 9)
                        }
                    }
                }
            }
        }
    }
}
