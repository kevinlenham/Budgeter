//
//  FinancesView.swift
//  Budgeter
//
//  One screen at three zoom levels: a day, a week, or a whole budget period.
//
//  This replaces the separate Ledger and Budget tabs, which were the same data cut
//  two ways. "What did today cost", "what has this week cost" and "how am I doing
//  against my limits" differ only in how wide a range they ask about, so they are
//  one screen with a scale selector rather than three screens with three layouts.
//
//  Limits only appear at the period scale, and that restraint is the point: a limit
//  is defined per period, so showing a category's limit next to one day's spending
//  would invite reading "$12 of $400" as though the day had a budget of its own.
//  At the narrower scales the same rows show spending alone, and the summary card
//  compares against the pace the period's budget implies instead.
//
//  See `DateScale` for why the widest scale is the budget period rather than a
//  calendar month.
//

import GRDB
import SwiftUI

struct FinancesView: View {
    let database: AppDatabase

    @State private var scale = DateScale.day
    /// Zero is the current window; negative steps back. Never positive — there is
    /// nothing to show in the future.
    @State private var offset = 0
    @State private var snapshot = FinancesSnapshot()
    @State private var isAdding = false
    @State private var editing: UUID?
    @State private var editingLimit: BudgetLine?
    @State private var isEditingOverall = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.stackSpacing) {
                    scalePicker
                    windowStepper
                    SpendSummaryCard(snapshot: snapshot) { isEditingOverall = true }
                    categoriesSection
                    transactionsSection
                }
                .pageInsets()
                .padding(.vertical, 8)
            }
            .screenBackground()
            .navigationTitle("Finances")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { isAdding = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add transaction")
                }
            }
            .sheet(isPresented: $isAdding) {
                TransactionFormView(database: database)
            }
            .sheet(item: $editing) { id in
                TransactionFormView(database: database, editing: id)
            }
            .sheet(item: $editingLimit) { line in
                LimitEditorView(database: database, line: line, period: snapshot.window?.period)
            }
            .sheet(isPresented: $isEditingOverall) {
                OverallLimitEditorView(
                    database: database,
                    line: snapshot.overall,
                    period: snapshot.window?.period
                )
            }
            // Re-observes whenever the range changes. Both pieces of range state
            // are in the id, so switching scale and stepping back both restart the
            // observation rather than leaving the previous window's numbers under
            // the new window's heading.
            .task(id: TaskKey(scale: scale, offset: offset)) {
                await observe()
            }
        }
    }

    // MARK: - Controls

    private var scalePicker: some View {
        Picker("Scale", selection: $scale) {
            ForEach(DateScale.available(for: snapshot.cadence)) { option in
                Text(option.title(cadence: snapshot.cadence)).tag(option)
            }
        }
        .pickerStyle(.segmented)
        // Stepping back three days then switching to weeks should not land on
        // "three weeks ago" — the user changed the question, not the date.
        .onChange(of: scale) { offset = 0 }
    }

    private var windowStepper: some View {
        HStack {
            Button { offset -= 1 } label: {
                Image(systemName: "chevron.left").font(.body.weight(.semibold))
            }
            .accessibilityLabel("Previous \(scale.title(cadence: snapshot.cadence).lowercased())")

            Spacer()

            Text(snapshot.window?.title ?? " ")
                .font(.headline)
                .foregroundStyle(Palette.textPrimary)
                .contentTransition(.numericText())

            Spacer()

            Button { offset += 1 } label: {
                Image(systemName: "chevron.right").font(.body.weight(.semibold))
            }
            .disabled(!(snapshot.window?.canGoForward ?? false))
            .accessibilityLabel("Next \(scale.title(cadence: snapshot.cadence).lowercased())")
        }
        .foregroundStyle(Palette.accent)
        .padding(.horizontal, 4)
    }

    // MARK: - Sections

    @ViewBuilder
    private var categoriesSection: some View {
        if !snapshot.categories.isEmpty {
            SectionHeader(title: "Categories").padding(.top, 4)
            Card(padding: 8) {
                VStack(spacing: 0) {
                    ForEach(Array(snapshot.categories.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Rectangle().fill(Palette.separator).frame(height: 0.5)
                        }
                        CategoryBreakdownRow(
                            row: row,
                            colour: snapshot.palette.color(for: row.categoryId),
                            share: snapshot.share(of: row)
                        )
                        .padding(.horizontal, 8)
                        // Only the period scale can edit a limit, and only a real
                        // category can have one — "Uncategorised" is not a row the
                        // user can budget against.
                        .modifier(TapToEditLimit(line: snapshot.budgetLine(for: row)) { line in
                            editingLimit = line
                        })
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var transactionsSection: some View {
        SectionHeader(title: "Transactions").padding(.top, 4)

        if snapshot.entries.isEmpty {
            EmptyStateCard(
                symbol: "tray",
                title: "Nothing here",
                message: emptyMessage
            )
        } else {
            Card(padding: 8) {
                TransactionList(entries: snapshot.entries, palette: snapshot.palette) { entry in
                    editing = entry.transactionId.asUUID
                }
                .padding(.horizontal, 8)
            }
        }
    }

    private var emptyMessage: String {
        switch scale {
        case .day: "Nothing logged on this day."
        case .week: "Nothing logged this week."
        case .period: "Nothing logged in this period."
        }
    }

    // MARK: - Observation

    /// Both bits of range state in one `Equatable` value, so `task(id:)` restarts
    /// on either.
    private struct TaskKey: Equatable {
        var scale: DateScale
        var offset: Int
    }

    private func observe() async {
        let today = CivilDate.today()
        let scale = scale
        let offset = offset
        let observation = ValueObservation.tracking { db in
            try FinancesSnapshot(scale: scale, offset: offset, today: today, in: db)
        }
        do {
            for try await value in observation.values(in: database.writer) {
                snapshot = value
            }
        } catch {
            // Leaves the previous window on screen; see the note in `OverviewView`.
        }
    }
}

/// Attaches a tap gesture only when there is a limit to edit, so rows that cannot
/// be edited do not advertise a tap target that does nothing.
private struct TapToEditLimit: ViewModifier {
    let line: BudgetLine?
    let edit: (BudgetLine) -> Void

    func body(content: Content) -> some View {
        if let line {
            Button { edit(line) } label: { content.contentShape(.rect) }
                .buttonStyle(.plain)
        } else {
            content
        }
    }
}
