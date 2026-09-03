//
//  LimitEditorViews.swift
//  Budgeter
//
//  The two sheets the Budget tab presents: one for a category's limit, one for
//  DEC-043's whole-period figure. Same rules, one with a category and one without,
//  which is why they sit together rather than next to the screen that presents them.
//
//  Both write a limit effective from the *current period's start* and re-snapshot
//  that period only. DEC-008 keeps limits as effective-dated rows and has each
//  period snapshot the ones in force at its start; editing here revises the period
//  in progress, so the number the user just typed is the number the screen shows,
//  while every period already behind it keeps the limit that applied then.
//

import GRDB
import SwiftUI

struct LimitEditorView: View {
    let database: AppDatabase
    let line: BudgetLine
    let period: PeriodRecord?

    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    @State private var message: String?

    private var currency: Currency {
        Currency(rawValue: line.currency) ?? .aud
    }

    private var amount: Money? {
        try? MoneyText.money(from: amountText, currency: currency)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(currency.rawValue).foregroundStyle(.secondary)
                        TextField("0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.title2.monospacedDigit())
                    }
                } header: {
                    Text("Limit for \(line.categoryName)")
                } footer: {
                    Text("Applies from the start of the period you are in. "
                        + "Periods you have already finished keep the limit they had.")
                }

                if let message {
                    Section { Text(message).foregroundStyle(.red) }
                }
            }
            .navigationTitle(line.categoryName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(amount == nil || period == nil)
                }
            }
            .onAppear {
                if line.limitMinor > 0 {
                    amountText = MoneyText.editableString(
                        from: Money(minorUnits: line.limitMinor, currency: currency)
                    )
                }
            }
        }
    }

    private func save() {
        guard let amount, let period, let categoryID = line.categoryId.asUUID,
              let startsOn = CivilDate(iso: period.startsOn) else { return }
        Task {
            do {
                try await database.writer.write { db in
                    try CategoryLimits().setLimit(
                        categoryID: categoryID,
                        amount: amount,
                        effectiveFrom: startsOn,
                        in: db
                    )
                    try PeriodGenerator().resnapshot(period: period, in: db)
                }
                dismiss()
            } catch {
                message = String(describing: error)
            }
        }
    }
}

/// The overall-budget twin of `LimitEditorView`. Same rules, no category.
struct OverallLimitEditorView: View {
    let database: AppDatabase
    let line: OverallBudgetLine?
    let period: PeriodRecord?

    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    @State private var message: String?

    private var currency: Currency {
        line.flatMap { Currency(rawValue: $0.currency) } ?? .aud
    }

    private var amount: Money? {
        try? MoneyText.money(from: amountText, currency: currency)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(currency.rawValue).foregroundStyle(.secondary)
                        TextField("0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.title2.monospacedDigit())
                    }
                } header: {
                    Text("Overall budget")
                } footer: {
                    Text("Applies from the start of the period you are in. "
                        + "Periods you have already finished keep the limit they had.")
                }

                if let message {
                    Section { Text(message).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Overall budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(amount == nil || period == nil)
                }
            }
            .onAppear {
                if let line, line.limitMinor > 0 {
                    amountText = MoneyText.editableString(
                        from: Money(minorUnits: line.limitMinor, currency: currency)
                    )
                }
            }
        }
    }

    private func save() {
        guard let amount, let period, let startsOn = CivilDate(iso: period.startsOn) else { return }
        Task {
            do {
                try await database.writer.write { db in
                    try OverallLimits().setLimit(amount: amount, effectiveFrom: startsOn, in: db)
                    try PeriodGenerator().resnapshot(period: period, in: db)
                }
                dismiss()
            } catch {
                message = String(describing: error)
            }
        }
    }
}
