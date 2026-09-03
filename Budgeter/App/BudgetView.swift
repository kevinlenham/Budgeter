//
//  BudgetView.swift
//  Budgeter
//
//  "$340 of $500", days remaining, and safe-to-spend — DEC-009's
//  `remaining_limit / days_remaining_inclusive`, computed per category.
//
//  Everything here reads `period_category_status`, which reads `spending`, so the
//  exclusions the invariants demand — transfers, income, drafts, deleted rows —
//  arrive already applied rather than being restated in a view file where they could
//  drift out of step with the rest of the app.
//

import GRDB
import SwiftUI

struct BudgetView: View {
    let database: AppDatabase

    @State private var period: BudgetPeriod?
    @State private var periodRecord: PeriodRecord?
    @State private var lines: [BudgetLine] = []
    @State private var editingLimit: BudgetLine?
    @State private var unbudgeted: [CategoryRecord] = []
    @State private var message: String?

    private var daysRemaining: Int {
        period.map { SafeToSpend.daysRemaining(in: $0, asOf: .today()) } ?? 0
    }

    var body: some View {
        NavigationStack {
            List {
                if let period {
                    Section {
                        LabeledContent("Period", value: periodTitle(period))
                        LabeledContent("Days left", value: "\(daysRemaining)")
                    }
                }

                if lines.isEmpty {
                    Section {
                        Text("No budgets set yet. Choose a category below to set one.")
                            .foregroundStyle(.secondary)
                    }
                }

                if !lines.isEmpty {
                    Section("This period") {
                        ForEach(lines) { line in
                            Button { editingLimit = line } label: {
                                BudgetLineRow(line: line, daysRemaining: daysRemaining)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !unbudgeted.isEmpty {
                    Section("Not budgeted") {
                        ForEach(unbudgeted, id: \.id) { category in
                            Button(category.name) {
                                editingLimit = BudgetLine(
                                    categoryId: category.id,
                                    categoryName: category.name,
                                    currency: Currency.aud.rawValue,
                                    limitMinor: 0,
                                    spentMinor: 0,
                                    remainingMinor: 0
                                )
                            }
                        }
                    }
                }

                if let message {
                    Section { Text(message).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Budget")
            .sheet(item: $editingLimit) { line in
                LimitEditorView(database: database, line: line, period: periodRecord)
            }
            .task { await observe() }
        }
    }

    private func periodTitle(_ period: BudgetPeriod) -> String {
        let start = period.startsOn.middayDate().formatted(.dateTime.day().month(.abbreviated))
        let end = period.endsOn.middayDate().formatted(.dateTime.day().month(.abbreviated))
        return "\(start) – \(end)"
    }

    private func observe() async {
        let today = CivilDate.today()
        let observation = ValueObservation.tracking { db in
            try BudgetSnapshot(today: today, in: db)
        }

        do {
            for try await snapshot in observation.values(in: database.writer) {
                lines = snapshot.lines
                periodRecord = snapshot.period
                period = snapshot.period?.dates.map {
                    BudgetPeriod(index: 0, startsOn: $0.start, endsOn: $0.end)
                }
                unbudgeted = snapshot.unbudgeted
            }
        } catch {
            message = String(describing: error)
        }
    }
}

/// Everything the budget screen draws, fetched in one observation so the period, its
/// lines and the leftover categories can never be a frame out of step with each other.
nonisolated struct BudgetSnapshot: Equatable, Sendable {
    var period: PeriodRecord?
    var lines: [BudgetLine] = []
    var unbudgeted: [CategoryRecord] = []

    init(today: CivilDate, in db: Database) throws {
        let categories = try CategoryStore().all(in: db)
        guard let record = try Queries.period(containing: today, in: db) else {
            unbudgeted = categories
            return
        }
        period = record
        lines = try Queries.budgetLines(periodID: record.id, in: db)
        let budgeted = Set(lines.map(\.categoryId))
        unbudgeted = categories.filter { !budgeted.contains($0.id) }
    }
}

struct BudgetLineRow: View {
    let line: BudgetLine
    let daysRemaining: Int

    private var safeToSpend: Money? {
        guard let remaining = line.remaining else { return nil }
        return try? SafeToSpend.daily(remaining: remaining, daysRemaining: daysRemaining)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(line.categoryName).font(.headline)
                Spacer()
                if let spent = line.spent, let limit = line.limit {
                    Text("\(MoneyText.string(from: spent)) of \(MoneyText.string(from: limit))")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(line.isOverspent ? .red : .secondary)
                }
            }

            ProgressView(value: line.fractionSpent)
                .tint(line.isOverspent ? .red : .accentColor)

            HStack {
                if let remaining = line.remaining {
                    Text(line.isOverspent
                        ? "\(MoneyText.string(from: remaining)) over"
                        : "\(MoneyText.string(from: remaining)) left")
                }
                Spacer()
                if let safeToSpend, daysRemaining > 0 {
                    Text("\(MoneyText.string(from: safeToSpend))/day")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Setting a limit for the current period.
///
/// DEC-008 keeps limits as effective-dated rows and has each period snapshot the
/// ones in force at its start. Editing here writes a limit effective from *this*
/// period's start and re-snapshots this period only — so the number the user just
/// typed is the number this screen shows, while every period already behind it keeps
/// the limit that applied then.
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
