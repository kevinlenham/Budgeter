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
//  is no longer invisible, because this screen shows exactly what it does before it
//  happens — the current period ends today, a new one starts today, and every
//  budget the switch touches is shown and editable in the same place.
//
//  Silent scaling still produces numbers no human chose, and resetting every limit
//  still throws away the user's setup — DEC-008's other two objections stand, which
//  is why this screen still exists rather than the switch happening from a plain
//  cadence toggle.
//
//  Two things this screen must communicate, and does:
//
//  - **that it is immediate**, because a switch with no visible effect looks broken
//    the other way;
//  - **every budget it affects** — the whole-period figure first, since DEC-043
//    made that the primary number, then each category — with an editable
//    suggestion, because the point is that the user chooses these figures rather
//    than finding them chosen.
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
    @State private var plan: CadenceSwitchPlan?
    @State private var overallAmount = ""
    @State private var amounts: [UUID: String] = [:]
    @State private var errorMessage: String?
    @State private var isSaving = false

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
                if let plan, plan.from != plan.to {
                    Text(switchDescription(plan))
                } else {
                    Text(Self.cadenceDescription(chosen))
                }
            }

            if let plan, plan.from != plan.to {
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
                            LimitSuggestionRow(line: line, text: binding(for: line))
                        }
                    } header: {
                        Text("Category budgets")
                    } footer: {
                        Text("Suggestions are your current limits scaled to the new period "
                            + "length and rounded. Change anything that looks wrong — these are "
                            + "the figures that will apply.")
                    }
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
                Button("Switch", action: apply)
                    .disabled(chosen == current || isSaving)
            }
        }
        .task(id: chosen) { await reload() }
    }

    private func shortDate(_ date: CivilDate) -> String {
        date.middayDate().formatted(.dateTime.day().month(.abbreviated))
    }

    private func switchDescription(_ plan: CadenceSwitchPlan) -> String {
        "Switching takes effect immediately: today's period ends today, and your "
            + "new \(plan.to.title.lowercased()) period starts right now. Anything you've "
            + "already spent or logged stays exactly where it is."
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

    /// Recomputed whenever the cadence picker moves, because every suggestion on
    /// screen depends on which cadence is being switched *to*. Writes nothing —
    /// `CadenceSwitch.plan` exists precisely so this screen can show the
    /// consequences before any of them happen.
    private func reload() async {
        do {
            let today = CivilDate.today()
            let cadence = chosen
            let loaded = try await database.writer.read { db in
                try CadenceSwitch().plan(to: cadence, asOf: today, in: db)
            }
            plan = loaded
            // No suggestion means nothing to scale, and the field shows its "None"
            // placeholder — the honest reading, since a zero would be a decision
            // nobody made.
            overallAmount = loaded.overallSuggested.map { MoneyText.editableString(from: $0) } ?? ""
            amounts = loaded.lines.reduce(into: [:]) { result, line in
                if let suggested = line.suggestedLimit {
                    result[line.categoryID] = MoneyText.editableString(from: suggested)
                }
            }
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func binding(for line: CadenceSwitchLine) -> Binding<String> {
        Binding(
            get: { amounts[line.categoryID] ?? "" },
            set: { amounts[line.categoryID] = $0 }
        )
    }

    private func apply() {
        guard let plan else { return }
        isSaving = true

        let overallCurrency = plan.overallCurrent?.currency ?? plan.overallSuggested?.currency ?? .aud
        let overallLimit = overallAmount.trimmedOrNil
            .flatMap { try? MoneyText.money(from: $0, currency: overallCurrency) }

        // A blank field is "leave this category alone", not "set it to zero": the
        // suggestion is absent exactly when there was no limit to scale, and
        // inventing a zero limit would budget the user to nothing without them
        // typing a number.
        var collected: [UUID: Money] = [:]
        for line in plan.lines {
            let currency = line.currentLimit?.currency ?? line.suggestedLimit?.currency ?? .aud
            guard let text = amounts[line.categoryID]?.trimmedOrNil,
                  let amount = try? MoneyText.money(from: text, currency: currency)
            else { continue }
            collected[line.categoryID] = amount
        }
        let limits = collected

        Task {
            do {
                try await database.writer.write { db in
                    try CadenceSwitch().apply(plan, overallLimit: overallLimit, limits: limits, in: db)
                }
                onSwitched()
                dismiss()
            } catch {
                errorMessage = String(describing: error)
                isSaving = false
            }
        }
    }
}

private struct LimitSuggestionRow: View {
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
