//
//  OnboardingView.swift
//  Budgeter
//
//  The questions the app cannot answer for itself: which account, which currency,
//  and how the budget period runs.
//
//  DEC-043 superseded DEC-007's "anchor to payday" — periods are calendar-anchored
//  now, so weekly and monthly need no date input at all: any Monday produces
//  Monday–Sunday periods forever, and any 1st-of-a-month produces full calendar
//  months forever (`CalendarCadence`). Fortnightly keeps one genuine question,
//  because nothing on a calendar says which of two adjacent Mondays starts "week
//  1" of a cycle already in progress — that is down to the user's own habit or pay
//  rhythm, and only they know it.
//
//  Payday itself is no longer asked here. DEC-036's reminder needs a *real* payday
//  date, which is a different question from "how should the budget period run",
//  and conflating them was exactly what DEC-036 already separated at the schema
//  level. It is configured later, in Settings → Payday, at the point the user
//  actually wants a reminder — never bundled into first launch.
//

import SwiftUI

struct OnboardingView: View {
    let onFinish: (OnboardingAnswers) -> Void

    @State private var accountName = "Everyday"
    @State private var currency: Currency = .aud
    @State private var cadence: Cadence = .fortnightly
    /// Only asked about for fortnightly (`CalendarCadence.anchor`), and only read
    /// when `cadence == .fortnightly`.
    @State private var isSecondWeek = false
    @State private var chosenCategories = Set(CategoryStore.starters)
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Account name", text: $accountName)
                        .textInputAutocapitalization(.words)
                    Picker("Currency", selection: $currency) {
                        ForEach(Currency.allCases, id: \.self) { currency in
                            Text(currency.rawValue).tag(currency)
                        }
                    }
                } header: {
                    Text("Your account")
                } footer: {
                    Text("You can add more accounts later.")
                }

                Section {
                    Picker("How often", selection: $cadence) {
                        ForEach(Cadence.allCases, id: \.self) { cadence in
                            Text(cadence.title).tag(cadence)
                        }
                    }

                    if cadence == .fortnightly {
                        Picker("Where are you in the cycle", selection: $isSecondWeek) {
                            Text("This week starts a new fortnight").tag(false)
                            Text("We're in the second week of one").tag(true)
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                } header: {
                    Text("Your budget period")
                } footer: {
                    Text(footer)
                }

                Section {
                    ForEach(CategoryStore.starters, id: \.self) { name in
                        Button {
                            toggle(name)
                        } label: {
                            HStack {
                                Text(name)
                                Spacer()
                                if chosenCategories.contains(name) {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                            .contentShape(.rect)
                        }
                        // Without this the whole row takes the accent colour and
                        // reads as a link rather than as a list of choices.
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Categories")
                } footer: {
                    Text("Optional, and short on purpose — Budgeter leads with one overall "
                        + "budget for the whole period. Set these up too if you want the "
                        + "finer detail, or skip them and add some later.")
                }
            }
            .navigationTitle("Set up Budgeter")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start", action: finish)
                        .disabled(accountName.trimmedOrNil == nil || isSaving)
                }
            }
        }
    }

    private var footer: String {
        switch cadence {
        case .weekly:
            "Monday to Sunday, every week — starting this week."
        case .fortnightly:
            "Two calendar weeks at a time, starting from whichever Monday matches where "
                + "you already are in the cycle."
        case .monthly:
            "The full calendar month, every month — starting this month."
        }
    }

    private func toggle(_ name: String) {
        if chosenCategories.contains(name) {
            chosenCategories.remove(name)
        } else {
            chosenCategories.insert(name)
        }
    }

    private func finish() {
        isSaving = true
        let today = CivilDate.today()
        onFinish(
            OnboardingAnswers(
                accountName: accountName,
                currency: currency,
                schedule: PeriodSchedule(
                    anchor: CalendarCadence.anchor(for: cadence, today: today, isSecondWeek: isSecondWeek),
                    cadence: cadence
                ),
                categoryNames: CategoryStore.starters.filter { chosenCategories.contains($0) }
            )
        )
    }
}

extension Cadence {
    var title: String {
        switch self {
        case .weekly: "Weekly"
        case .fortnightly: "Fortnightly"
        case .monthly: "Monthly"
        }
    }
}
