//
//  TransactionRow.swift
//  Budgeter
//
//  One entry, drawn the same way wherever it appears — the Overview's recent list
//  and the Finances screen's full list are the same rows, so a transaction never
//  looks like two different things depending on which screen found it.
//
//  Money in is green and carries a leading plus; money out is left in the primary
//  ink rather than painted red. Red is reserved for *over budget*, and if every
//  expense were red the one that actually matters would not stand out.
//

import SwiftUI

struct TransactionRow: View {
    let entry: LedgerEntry
    let palette: CategoryPalette

    private var isIncoming: Bool {
        entry.amount.map { !$0.isNegative } ?? false
    }

    var body: some View {
        HStack(spacing: 12) {
            // The category's colour, as a dot rather than a full tile: a list of
            // twenty rows with twenty coloured squares reads as a chart, not a list.
            Circle()
                .fill(palette.color(for: entry.categoryId))
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.merchant ?? entry.categoryName ?? "—")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let category = entry.categoryName {
                        Text(category)
                    }
                    if entry.isDraft {
                        Pill(text: "Draft", tint: Palette.warning)
                    }
                }
                .font(.caption)
                .foregroundStyle(Palette.textSecondary)
            }

            Spacer(minLength: 8)

            Text(amountText)
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(isIncoming ? Palette.income : Palette.textPrimary)
        }
        .padding(.vertical, 8)
        .contentShape(.rect)
    }

    /// Incoming money gets an explicit "+". `MoneyText` already writes outgoing
    /// amounts with the locale's minus sign, so only the positive case needs help
    /// telling the two apart at a glance.
    private var amountText: String {
        guard let amount = entry.amount else { return "—" }
        let formatted = MoneyText.string(from: amount)
        return isIncoming && !amount.isZero ? "+\(formatted)" : formatted
    }
}

/// A run of rows inside one card, hairline-separated.
///
/// The separator is drawn between rows rather than under all of them, so the last
/// row does not end on a line floating above the card's padding.
struct TransactionList: View {
    let entries: [LedgerEntry]
    let palette: CategoryPalette
    let onSelect: (LedgerEntry) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 {
                    Rectangle()
                        .fill(Palette.separator)
                        .frame(height: 0.5)
                }
                Button { onSelect(entry) } label: {
                    TransactionRow(entry: entry, palette: palette)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
