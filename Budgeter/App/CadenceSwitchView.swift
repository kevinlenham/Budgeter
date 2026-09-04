//
//  CadenceSwitchView.swift
//  Budgeter
//
//  DEC-008's confirmation screen, and the one screen in the app whose entire reason
//  for existing is a decision recorded in the design doc rather than a feature
//  anyone asked for.
//
//  DEC-008 originally rejected switching immediately, on the grounds that it would
//  truncate the current period and make "spent this period" jump for invisible
//  reasons. DEC-043 revisits that: waiting for a boundary meant waiting up to three
//  weeks for a switch to monthly, which felt broken rather than careful. Truncating
//  is no longer invisible, because the switch is confirmed on a sheet that shows
//  exactly what it does before it happens — the current period ends today, a new
//  one starts today, and every budget the switch touches is shown and editable
//  there.
//
//  Silent scaling still produces numbers no human chose — DEC-008's objection to
//  it stands, and DEC-044 takes it further: the app does not guess at all any more,
//  it just asks. That is why the switch still passes through a confirmation rather
//  than happening from a plain cadence toggle.
//
//  The split between the two halves of this file is the point. The *screen* is a
//  cadence picker and nothing else: budgets are not what anyone came here to look
//  at, and having every category's limit sitting under the picker made the page
//  read as a budget editor that also happened to change the period. The *sheet* is
//  where the consequences live, and it appears only once the user has asked to
//  switch — at which point the two things DEC-008 demands are exactly what it has
//  to say:
//
//  - **that it is immediate**, because a switch with no visible effect looks broken
//    the other way;
//  - **every budget it affects** — the whole-period figure first, since DEC-043
//    made that the primary number, then each category — starting at zero with the
//    old figure shown beneath it, because the point is that the user chooses these
//    figures rather than finding them chosen.
//

import GRDB
import SwiftUI

struct CadenceSwitchView: View {
    let database: AppDatabase
    let current: Cadence
    /// Called after a successful switch, so the settings screen can re-read what it
    /// is showing.
    var onSwitched: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    @State private var chosen: Cadence
    @State private var pending: PendingSwitch?
    @State private var isPlanning = false
    @State private var errorMessage: String?

    init(database: AppDatabase, current: Cadence, onSwitched: @escaping () -> Void = {}) {
        self.database = database
        self.current = current
        self.onSwitched = onSwitched
        _chosen = State(initialValue: current)
    }

    var body: some View {
        Form {
            Section {
                Picker("Cadence", selection: $chosen) {
                    ForEach(Cadence.allCases, id: \.self) { cadence in
                        Text(cadence.title).tag(cadence)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Budget period")
            } footer: {
                Text(Self.cadenceDescription(chosen))
            }

            if chosen != current {
                Section {
                    Text("Switching takes effect immediately: today's period ends today, and "
                        + "your new \(chosen.title.lowercased()) period starts right now. "
                        + "You'll get a chance to set your budgets for it first.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Budget period")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Switch") { Task { await beginSwitch() } }
                    .disabled(chosen == current || isPlanning)
            }
        }
        // `item:` rather than a bool: the sheet is built from one specific plan, and
        // binding it to the plan itself is what makes it impossible to show a sheet
        // for a cadence the plan was not computed for.
        .sheet(item: $pending) { pending in
            NavigationStack {
                CadenceSwitchConfirmation(
                    database: database,
                    plan: pending.plan,
                    onSwitched: {
                        onSwitched()
                        dismiss()
                    }
                )
            }
        }
        // Choosing a different cadence and changing your mind should not leave a
        // stale failure on screen.
        .onChange(of: chosen) { _, _ in errorMessage = nil }
    }

    private static func cadenceDescription(_ cadence: Cadence) -> String {
        switch cadence {
        case .weekly:
            "Monday to Sunday, every week."
        case .fortnightly:
            "Two calendar weeks at a time."
        case .monthly:
            "The full calendar month, every month."
        }
    }

    // MARK: - Actions

    /// Reads the plan for the chosen cadence and opens the confirmation. Writes
    /// nothing — `CadenceSwitch.plan` exists precisely so this screen can show the
    /// consequences before any of them happen.
    ///
    /// The plan is read here rather than on every move of the picker because a plan
    /// is a proposal for one specific cadence, and the only moment one is needed is
    /// the moment the user asks to switch to it. Reading it on demand is also what
    /// leaves nothing on screen to keep in sync: the sheet owns the plan it was
    /// opened with, so `apply` cannot commit a plan for a cadence that has since
    /// moved on.
    private func beginSwitch() async {
        guard chosen != current else { return }
        isPlanning = true
        errorMessage = nil
        defer { isPlanning = false }
        do {
            let today = CivilDate.today()
            let cadence = chosen
            let plan = try await database.writer.read { db in
                try CadenceSwitch().plan(to: cadence, asOf: today, in: db)
            }
            // The picker may have moved again while the read was in flight, and a
            // plan for a cadence that is no longer selected is an answer to a
            // different question.
            guard cadence == chosen else { return }
            // `plan.from` is what the database says the cadence is, which is the
            // only opinion that counts; `current` is what Settings believed when it
            // built this screen. A plan that changes nothing would still truncate
            // the period in progress — a switch that looks like it did nothing
            // while quietly ending today's period.
            guard plan.from != plan.to else {
                errorMessage = "You are already budgeting \(plan.to.title.lowercased())."
                return
            }
            pending = PendingSwitch(plan: plan)
        } catch is CancellationError {
            // Superseded or dismissed; nothing to report.
        } catch {
            errorMessage = String(describing: error)
        }
    }
}

/// Wraps a plan so `.sheet(item:)` can present it. `CadenceSwitchPlan` is a value
/// from the database layer and has no business carrying an identity for SwiftUI's
/// benefit.
private struct PendingSwitch: Identifiable {
    let id = UUID()
    let plan: CadenceSwitchPlan
}

/// The confirmation: what the switch does, and every budget it touches, editable.
private struct CadenceSwitchConfirmation: View {
    let database: AppDatabase
    let plan: CadenceSwitchPlan
    let onSwitched: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var overallAmount: String
    @State private var amounts: [UUID: String]
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(database: AppDatabase, plan: CadenceSwitchPlan, onSwitched: @escaping () -> Void) {
        self.database = database
        self.plan = plan
        self.onSwitched = onSwitched
        // Every budget starts at zero, and every budget the user had is shown
        // underneath it as "now $x" so they have something to type against. DEC-044:
        // a figure carried over or scaled from a different period length is a number
        // nobody chose, and the app has no idea what the right one is — a fortnight's
        // groceries is not half a month's for anyone who shops weekly.
        //
        // Zero rather than blank, because these are the figures that will apply and a
        // blank one would quietly leave the old cadence's limit in force. Categories
        // with no limit at all stay blank: they were not budgeted before, and starting
        // to budget them is a decision for the user, not a side effect of a switch.
        _overallAmount = State(
            initialValue: plan.overallCurrent.map { Self.zero(like: $0) } ?? ""
        )
        _amounts = State(initialValue: plan.lines.reduce(into: [:]) { result, line in
            if let current = line.currentLimit {
                result[line.categoryID] = Self.zero(like: current)
            }
        })
    }

    /// "0" in the currency's own precision, so the field opens with something the
    /// money parser will accept back unchanged.
    private static func zero(like money: Money) -> String {
        MoneyText.editableString(from: Money(minorUnits: 0, currency: money.currency))
    }

    var body: some View {
        Form {
            Section {
                Text("Your \(plan.from.title.lowercased()) period ends today, and your first "
                    + "\(plan.to.title.lowercased()) period starts right now. Anything you've "
                    + "already spent or logged stays exactly where it is.")
            }

            Section {
                HStack {
                    Text("Overall budget")
                    Spacer()
                    TextField("None", text: $overallAmount)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospacedDigit())
                        .frame(maxWidth: 110)
                }
                if let current = plan.overallCurrent {
                    Text("now \(MoneyText.string(from: current))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("From \(shortDate(plan.effectiveFrom))")
            } footer: {
                Text("The whole-period number the Budget tab leads with. Category "
                    + "budgets below are optional on top of this, not instead of it.")
            }

            if !plan.lines.isEmpty {
                Section {
                    ForEach(plan.lines) { line in
                        CategoryLimitRow(line: line, text: binding(for: line))
                    }
                } header: {
                    Text("Category budgets")
                } footer: {
                    Text("Budgets start at zero because a limit set for a "
                        + "\(plan.from.title.lowercased()) period does not mean the same thing "
                        + "over a \(plan.to.title.lowercased()) one. What you type here is what "
                        + "will apply.")
                }
            }

            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Switch to \(plan.to.title.lowercased())")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(isSaving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(isSaving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Switch", action: apply)
                    .disabled(isSaving)
            }
        }
    }

    private func shortDate(_ date: CivilDate) -> String {
        date.middayDate().formatted(.dateTime.day().month(.abbreviated))
    }

    private func binding(for line: CadenceSwitchLine) -> Binding<String> {
        Binding(
            get: { amounts[line.categoryID] ?? "" },
            set: { amounts[line.categoryID] = $0 }
        )
    }

    private func apply() {
        isSaving = true
        errorMessage = nil

        let overallCurrency = plan.overallCurrent?.currency ?? .aud
        let overallLimit = overallAmount.trimmedOrNil
            .flatMap { try? MoneyText.money(from: $0, currency: overallCurrency) }

        // A blank field is "leave this category alone", not "set it to zero". It is
        // blank exactly when the category had no limit to begin with, and inventing
        // a zero limit for one the user never budgeted would put it over budget on
        // the first dollar without them typing a number.
        var collected: [UUID: Money] = [:]
        for line in plan.lines {
            let currency = line.currentLimit?.currency ?? .aud
            guard let text = amounts[line.categoryID]?.trimmedOrNil,
                  let amount = try? MoneyText.money(from: text, currency: currency)
            else { continue }
            collected[line.categoryID] = amount
        }
        let limits = collected
        let plan = self.plan

        Task {
            do {
                try await database.writer.write { db in
                    try CadenceSwitch().apply(plan, overallLimit: overallLimit, limits: limits, in: db)
                }
                dismiss()
                onSwitched()
            } catch {
                errorMessage = String(describing: error)
                isSaving = false
            }
        }
    }
}

private struct CategoryLimitRow: View {
    let line: CadenceSwitchLine
    @Binding var text: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(line.categoryName)
                if let current = line.currentLimit {
                    Text("now \(MoneyText.string(from: current))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            TextField("None", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
                .frame(maxWidth: 110)
        }
    }
}
