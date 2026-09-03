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
                    .disabled(!isSwitchable || isSaving)
            }
        }
        .task(id: chosen) { await reload() }
    }

    /// Enabled only when there is a loaded plan that describes *this* picker
    /// selection and actually changes something.
    ///
    /// Deliberately not `chosen != current`. `current` is what Settings believed
    /// the cadence was when it built this screen; `plan` is what the database says,
    /// for the cadence currently selected. Keying the button off the plan is what
    /// makes it impossible to commit a plan for a cadence that is no longer on
    /// screen — the failure below.
    private var isSwitchable: Bool {
        guard let plan else { return false }
        return plan.to == chosen && plan.from != plan.to
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
    ///
    /// Clears `plan` *before* reading, and never leaves a stale one behind on
    /// failure. A plan is a proposal for one specific cadence, so a plan for the
    /// previous selection is not a worse version of this one — it is an answer to a
    /// different question, and `apply` cannot tell the difference. GRDB 7 cancels an
    /// in-flight read when `.task(id:)` cancels this task, which is what a quick
    /// second tap on the segmented picker does, so "the read for the cadence on
    /// screen failed while an older one succeeded" is the ordinary case, not an
    /// exotic one.
    private func reload() async {
        plan = nil
        errorMessage = nil
        overallAmount = ""
        amounts = [:]
        do {
            let today = CivilDate.today()
            let cadence = chosen
            let loaded = try await database.writer.read { db in
                try CadenceSwitch().plan(to: cadence, asOf: today, in: db)
            }
            // The picker may have moved again while the read was in flight.
            guard cadence == chosen else { return }
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
        } catch is CancellationError {
            // The picker moved again and this read was superseded. Not a failure to
            // report — another reload is already running for the new selection.
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
        // Re-asserted rather than trusted to `isSwitchable` having disabled the
        // button: a plan for the wrong cadence commits a switch the user did not
        // ask for, and a plan whose `from` equals its `to` truncates the period in
        // progress to change nothing at all — a switch that looks like it did
        // nothing while quietly ending today's period. Neither is worth leaving to
        // the toolbar. Reported, never a silent `return`: "the button did nothing"
        // is the symptom this whole guard exists to stop.
        guard let plan, plan.to == chosen, plan.from != plan.to else {
            errorMessage = "Could not read your current budget period. Go back and try again."
            return
        }
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
