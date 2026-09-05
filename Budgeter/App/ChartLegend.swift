//
//  ChartLegend.swift
//  Budgeter
//
//  The written key that sits under a chart with more than one series.
//
//  It is not optional decoration. A chart that distinguishes its series by colour
//  alone is unreadable to anyone who cannot tell those colours apart, so every
//  multi-series chart in the app carries one of these, and the swatch matches how
//  the line is actually drawn — dashed for a dashed line, solid for a solid one.
//

import SwiftUI

/// One entry in a chart legend.
struct ChartLegendItem: Identifiable {
    let colour: Color
    let label: String
    /// Draws the swatch dashed, to match a dashed line in the chart.
    var dashed = false

    /// The label is the identity: no chart shows the same series twice.
    var id: String { label }
}

/// A written legend. Charts with more than one series always carry one, so nothing
/// on this screen is identified by colour alone.
struct ChartLegend: View {
    let items: [ChartLegendItem]

    var body: some View {
        HStack(spacing: 16) {
            ForEach(items) { item in
                HStack(spacing: 6) {
                    if item.dashed {
                        Capsule()
                            .strokeBorder(item.colour, style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                            .frame(width: 16, height: 2)
                    } else {
                        Capsule()
                            .fill(item.colour)
                            .frame(width: 16, height: 3)
                    }
                    Text(item.label)
                        .font(.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            Spacer()
        }
    }
}
