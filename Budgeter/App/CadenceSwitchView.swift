//
//  CadenceSwitchView.swift
//  Budgeter
//
//  DEC-008's confirmation screen, and the one screen in the app whose entire reason
//  for existing is a decision recorded in the design doc rather than a feature
//  anyone asked for.
//
//  DEC-008 rejected three simpler options. Switching immediately would truncate the
//  current period, so "spent this period" jumps for invisible reasons. Silent
//  scaling produces numbers no human chose. Resetting every limit throws away the
//  user's setup, and most people abandon the switch rather than redo it. What is
//  left — wait for the boundary, and prompt with a sensible pre-fill — is the only
//  option that is both correct and kind, and it costs exactly this screen.
//
//  Two things it must therefore communicate, and does:
//
//  - **when** the change takes effect, in words ("your new cadence starts 14 March"),
//    because a switch that appears to do nothing today looks broken;
//  - **every category**, with an editable suggestion, because the whole point is
//    that the user chooses the numbers rather than finding them chosen.
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
                    Text("Your \(plan.to.title.lowercased()) periods start on "
                        + "\(plan.effectiveFrom.middayDate().formatted(.dateTime.day().month(.wide))). "
                        + "The period you are in now finishes on the cadence it started on — "
                        + "nothing already spent moves.")
                } else {
                    Text("Changing this takes effect at your next period boundary, never "
                        + "part-way through a period.")
                }
            }

            if let plan, plan.from != plan.to, !plan.lines.isEmpty {
                Section {
                    ForEach(plan.lines) { line in
                        LimitSuggestionRow(line: line, text: binding(for: line))
                    }
                } header: {
                    Text("Limits from \(shortDate(plan.effectiveFrom))")
                } footer: {
                    Text("Suggestions are your current limits scaled to the new period "
                        + "length and rounded. Change anything that looks wrong — these are "
                        + "the figures that will apply.")
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
            // A category with no limit to scale gets no text, and the field shows
            // its "None" placeholder — which is the honest thing, because there is
            // nothing to suggest and a zero would be a decision nobody made.
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
                    try CadenceSwitch().apply(plan, limits: limits, in: db)
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
