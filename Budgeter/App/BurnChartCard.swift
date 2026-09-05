//
//  BurnChartCard.swift
//  Budgeter
//
//  Cumulative spending this period against the straight line the budget allows.
//
//  The pace line is a reference, not a forecast: it is the overall limit spread
//  evenly across the period, the same assumption the "safe per day" figure on the
//  Overview makes. Nothing here predicts what will be spent tomorrow.
//

import Charts
import SwiftUI

/// Cumulative spend this period against the straight line the budget allows.
///
/// The pace line is a reference, not a forecast — it is the limit spread evenly
/// across the period, which is the same assumption the "safe per day" figure makes.
/// The spend line stops at today rather than continuing flat to the end of the
/// period, because a flat run to the right edge reads as a fortnight of spending
/// nothing rather than as a fortnight that has not happened yet.
struct BurnCard: View {
    let points: [BurnPoint]
    let hasBudget: Bool

    private var elapsed: [BurnPoint] {
        points.filter(\.isElapsed)
    }

    var body: some View {
        if points.isEmpty {
            EmptyStateCard(
                symbol: "chart.xyaxis.line",
                title: "No period yet",
                message: "Pace shows up once a budget period is running."
            )
        } else {
            Card {
                VStack(alignment: .leading, spacing: 16) {
                    Chart {
                        if hasBudget {
                            ForEach(points) { point in
                                if let pace = point.pace {
                                    LineMark(
                                        x: .value("Day", point.date.middayDate()),
                                        y: .value("Allowed", Int(pace.minorUnits)),
                                        series: .value("Series", "Pace")
                                    )
                                    .foregroundStyle(Palette.textTertiary)
                                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 4]))
                                }
                            }
                        }

                        ForEach(elapsed) { point in
                            LineMark(
                                x: .value("Day", point.date.middayDate()),
                                y: .value("Spent", Int(point.spent.minorUnits)),
                                series: .value("Series", "Spent")
                            )
                            .foregroundStyle(tint)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                            .interpolationMethod(.monotone)
                        }

                        if let last = elapsed.last {
                            PointMark(
                                x: .value("Day", last.date.middayDate()),
                                y: .value("Spent", Int(last.spent.minorUnits))
                            )
                            .symbolSize(90)
                            .foregroundStyle(tint)
                            .annotation(position: .topLeading, spacing: 6) {
                                Text(MoneyText.string(from: last.spent))
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(Palette.textPrimary)
                            }
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
                        AxisMarks { value in
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
                    .accessibilityLabel("Cumulative spending against budget pace")

                    if hasBudget {
                        ChartLegend(items: [
                            ChartLegendItem(colour: tint, label: "Spent so far"),
                            ChartLegendItem(colour: Palette.textTertiary, label: "Budget pace", dashed: true),
                        ])
                        Text(verdict)
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(isAhead ? Palette.expense : Palette.income)
                    } else {
                        Text("Set an overall budget on Finances to see how this compares with the pace it allows.")
                            .font(.footnote)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
            }
        }
    }

    /// Whether spending has outrun the pace, which is what decides the line colour
    /// and the sentence under the chart.
    private var isAhead: Bool {
        guard let last = elapsed.last, let pace = last.pace else { return false }
        return last.spent.minorUnits > pace.minorUnits
    }

    private var tint: Color {
        isAhead ? Palette.expense : Palette.income
    }

    private var verdict: String {
        guard let last = elapsed.last, let pace = last.pace,
              let gap = try? last.spent.subtracting(pace)
        else { return "" }
        // The sentence already says which side of the pace you are on, so the
        // figure is stated as a size rather than repeating that as a minus sign.
        let magnitude = gap.isNegative ? ((try? gap.negated()) ?? gap) : gap
        let amount = MoneyText.string(from: magnitude)
        return isAhead
            ? "\(amount) ahead of pace for this point in the period."
            : "\(amount) behind pace — comfortably inside the budget."
    }

    private func compact(_ minorUnits: Int) -> String {
        let major = Double(minorUnits) / 100
        return major >= 1000
            ? String(format: "%.0fk", major / 1000)
            : String(format: "%.0f", major)
    }
}
