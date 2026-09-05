//
//  FinancesCards.swift
//  Budgeter
//
//  The cards the Finances screen is built from: the summary figure at the top, the
//  pace line that stands in for a limit at the narrower scales, and one row per
//  category.
//
//  They are `internal` rather than private only because they live in their own
//  file now; nothing outside Finances draws them.
//

import SwiftUI

/// The figure the screen leads with: what this window cost, and — at the period
/// scale — what it was allowed to cost.
struct SpendSummaryCard: View {
    let snapshot: FinancesSnapshot
    let onSetBudget: () -> Void

    private var overspent: Bool {
        snapshot.overall?.isOverspent ?? false
    }

    private var tint: Color {
        overspent ? Palette.expense : Palette.income
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Spent")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Palette.textSecondary)
                        AmountText(
                            money: snapshot.spent,
                            font: .system(size: 34, weight: .bold),
                            tint: Palette.textPrimary
                        )
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    }

                    Spacer(minLength: 12)

                    if let overall = snapshot.overall {
                        VStack(spacing: 6) {
                            ProgressRing(fraction: overall.fractionSpent, tint: tint, size: 56)
                            Pill(text: "\(Int((overall.fractionSpent * 100).rounded()))%", tint: tint)
                        }
                    }
                }

                if let overall = snapshot.overall, let limit = overall.limit {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressBar(fraction: overall.fractionSpent, tint: tint)
                        HStack {
                            Text(remainingText(overall))
                                .foregroundStyle(overspent ? Palette.expense : Palette.textSecondary)
                            Spacer()
                            Text("of \(MoneyText.string(from: limit))")
                                .foregroundStyle(Palette.textSecondary)
                        }
                        .font(.caption.monospacedDigit())
                    }
                } else if let pace = snapshot.pace, let spent = snapshot.spent {
                    // A narrower window has no limit of its own, so it is measured
                    // against the share of the period's budget it represents.
                    PaceRow(spent: spent, pace: pace)
                } else if snapshot.isPeriodScale {
                    Button("Set a budget for this period", action: onSetBudget)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Palette.accent.opacity(0.16), in: .capsule)
                        .foregroundStyle(Palette.accent)
                }

                if let income = snapshot.income, !income.isZero {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right")
                        Text("\(MoneyText.string(from: income)) in")
                    }
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(Palette.income)
                }
            }
        }
        .contentShape(.rect)
        .onTapGesture { if snapshot.isPeriodScale { onSetBudget() } }
    }

    private func remainingText(_ overall: OverallBudgetLine) -> String {
        guard let remaining = overall.remaining else { return "" }
        return overall.isOverspent
            ? "\(MoneyText.string(from: remaining)) over"
            : "\(MoneyText.string(from: remaining)) left"
    }
}

/// "$120 of the $180 this week allows" — the narrower scales' answer to a limit.
struct PaceRow: View {
    let spent: Money
    let pace: Money

    private var fraction: Double {
        guard pace.minorUnits > 0 else { return spent.minorUnits > 0 ? 1 : 0 }
        return Double(spent.minorUnits) / Double(pace.minorUnits)
    }

    private var isBehind: Bool {
        spent.minorUnits > pace.minorUnits
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressBar(fraction: fraction, tint: isBehind ? Palette.warning : Palette.income)
            Text(isBehind
                ? "Over the \(MoneyText.string(from: pace)) this window allows"
                : "of the \(MoneyText.string(from: pace)) this window allows")
                .font(.caption.monospacedDigit())
                .foregroundStyle(isBehind ? Palette.warning : Palette.textSecondary)
        }
    }
}

/// One category's line in the breakdown: its colour, its name, what it cost, and
/// how much of the window it accounts for.
struct CategoryBreakdownRow: View {
    let row: CategorySpend
    let colour: Color
    let share: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle().fill(colour).frame(width: 9, height: 9)
                Text(row.displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Palette.textPrimary)
                Spacer(minLength: 8)
                AmountText(money: row.amount, font: .callout.weight(.semibold))
            }
            ProgressBar(fraction: share, tint: colour, height: 4)
        }
        .padding(.vertical, 10)
    }
}
