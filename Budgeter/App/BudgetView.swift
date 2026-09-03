//
//  BudgetView.swift
//  Budgeter
//
//  DEC-043's whole-period budget, shown first — "$1,200 of $2,000" for everything,
//  the number Budgeter leads with — followed by "$340 of $500" per category for
//  anyone who wants the finer detail. Category budgets stay exactly as optional as
//  they always were; the whole-period figure is optional too, just promoted.
//
//  Everything here reads `period_category_status` and `period_overall_status`,
//  which both read `spending`, so the exclusions the invariants demand — transfers,
//  income, drafts, deleted rows — arrive already applied rather than being restated
//  in a view file where they could drift out of step with the rest of the app.
//

import GRDB
import SwiftUI

struct BudgetView: View {
    let database: AppDatabase

    @State private var period: BudgetPeriod?
    @State private var periodRecord: PeriodRecord?
    @State private var cadence: Cadence?
    @State private var overall: OverallBudgetLine?
    @State private var isEditingOverall = false
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

                Section {
                    Button {
                        isEditingOverall = true
                    } label: {
                        if let overall {
                            OverallBudgetRow(line: overall, daysRemaining: daysRemaining)
                        } else {
                            Text("Set an overall budget for this period")
                        }
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Overall")
                }

                if !lines.isEmpty {
                    Section("Categories") {
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
            .navigationTitle(cadence.map { "\($0.title) budget" } ?? "Budget")
            .sheet(item: $editingLimit) { line in
                LimitEditorView(database: database, line: line, period: periodRecord)
            }
            .sheet(isPresented: $isEditingOverall) {
                OverallLimitEditorView(database: database, line: overall, period: periodRecord)
            }
            .task { await observe() }
        }
    }

    private func periodTitle(_ period: BudgetPeriod) -> String {
        "\(shortDate(period.startsOn)) – \(shortDate(period.endsOn))"
    }

    private func shortDate(_ date: CivilDate) -> String {
        date.middayDate().formatted(.dateTime.day().month(.abbreviated))
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
                cadence = snapshot.cadence
                overall = snapshot.overall
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

/// Everything the budget screen draws, fetched in one observation so the period,
/// the overall line, the category lines and the leftover categories can never be a
/// frame out of step with each other.
nonisolated struct BudgetSnapshot: Equatable, Sendable {
    var period: PeriodRecord?
    var cadence: Cadence?
    var overall: OverallBudgetLine?
    var lines: [BudgetLine] = []
    var unbudgeted: [CategoryRecord] = []

    init(today: CivilDate, in db: Database) throws {
        let settings = try BudgetSettingsStore().load(db)
        cadence = settings.schedule?.cadence

        let categories = try CategoryStore().all(in: db)
        guard let record = try Queries.period(containing: today, in: db) else {
            unbudgeted = categories
            return
        }
        period = record
        overall = try Queries.overallStatus(periodID: record.id, in: db)
        lines = try Queries.budgetLines(periodID: record.id, in: db)
        let budgeted = Set(lines.map(\.categoryId))
        unbudgeted = categories.filter { !budgeted.contains($0.id) }
    }
}

struct OverallBudgetRow: View {
    let line: OverallBudgetLine
    let daysRemaining: Int

    private var safeToSpend: Money? {
        guard let remaining = line.remaining else { return nil }
        return try? SafeToSpend.daily(remaining: remaining, daysRemaining: daysRemaining)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let spent = line.spent, let limit = line.limit {
                Text("\(MoneyText.string(from: spent)) of \(MoneyText.string(from: limit))")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(line.isOverspent ? .red : .primary)
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
        .padding(.vertical, 4)
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
