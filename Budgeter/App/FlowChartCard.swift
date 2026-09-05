//
//  FlowChartCard.swift
//  Budgeter
//
//  Money in against money out, one pair of bars per budget period.
//
//  Both series are amounts in the same currency, so they share one y-axis. That is
//  the whole reason this is readable: two scales would let the bars be drawn to
//  whatever heights made the picture look balanced, and the gap between them would
//  stop meaning the surplus.
//

import Charts
import SwiftUI

/// Money in against money out, one pair of bars per period.
///
/// Two measures on one axis, not two axes: both are amounts in the same currency,
/// so they belong on the same scale and the gap between the bars is the surplus.
struct FlowCard: View {
    let flows: [PeriodFlow]

    var body: some View {
        if flows.isEmpty {
            EmptyStateCard(
                symbol: "chart.bar",
                title: "Not enough history",
                message: "Once a period or two has passed, income and spending will be compared here."
            )
        } else {
            Card {
                VStack(alignment: .leading, spacing: 16) {
                    Chart {
                        ForEach(flows) { flow in
                            BarMark(
                                x: .value("Period", flow.startsOn.middayDate(), unit: .day),
                                y: .value("Amount", Int(flow.income.minorUnits)),
                                width: 10
                            )
                            .position(by: .value("Flow", "In"))
                            .foregroundStyle(Palette.income)
                            .cornerRadius(4)

                            BarMark(
                                x: .value("Period", flow.startsOn.middayDate(), unit: .day),
                                y: .value("Amount", Int(flow.expenses.minorUnits)),
                                width: 10
                            )
                            .position(by: .value("Flow", "Out"))
                            .foregroundStyle(Palette.expense)
                            .cornerRadius(4)
                        }
                    }
                    .chartLegend(.hidden)
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine().foregroundStyle(Palette.separator)
                            AxisValueLabel {
                                if let minor = value.as(Int.self) {
                                    Text(compact(minor))
                                        .font(.caption2)
                                        .foregroundStyle(Palette.textTertiary)
                                }
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: flows.map { $0.startsOn.middayDate() }) { value in
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(date.formatted(.dateTime.day().month(.abbreviated)))
                                        .font(.caption2)
                                        .foregroundStyle(Palette.textTertiary)
                                }
                            }
                        }
                    }
                    .frame(height: 190)
                    .accessibilityLabel("Income and expenses by period")

                    ChartLegend(items: [
                        ChartLegendItem(colour: Palette.income, label: "Money in"),
                        ChartLegendItem(colour: Palette.expense, label: "Money out"),
                    ])

                    if let latest = flows.last, let surplus = latest.surplus {
                        Text(surplus.isNegative
                            ? "This period is \(MoneyText.string(from: surplus)) short."
                            : "This period is \(MoneyText.string(from: surplus)) ahead.")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(surplus.isNegative ? Palette.expense : Palette.income)
                    }
                }
            }
        }
    }

    /// Axis labels in whole units — cents on a y-axis are noise at this scale.
    private func compact(_ minorUnits: Int) -> String {
        let major = Double(minorUnits) / 100
        return major >= 1000
            ? String(format: "%.0fk", major / 1000)
            : String(format: "%.0f", major)
    }
}
