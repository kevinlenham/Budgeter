//
//  OnboardingView.swift
//  Budgeter
//
//  The four questions the app cannot answer for itself: which account, which
//  currency, when the next payday is (DEC-007), and how often it comes.
//
//  DEC-007's reasoning for asking rather than assuming: "the entire reason
//  fortnightly cadence exists in Australia is fortnightly pay, so the anchor is a
//  real-world fact the user knows and can supply in one date picker. First launch is
//  arbitrary and every fortnightly user would have to correct it anyway."
//

import SwiftUI

struct OnboardingView: View {
    let onFinish: (OnboardingAnswers) -> Void

    @State private var accountName = "Everyday"
    @State private var currency: Currency = .aud
    @State private var payday = Date()
    @State private var cadence: Cadence = .fortnightly
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
                    DatePicker("Next payday", selection: $payday, displayedComponents: .date)
                    Picker("How often", selection: $cadence) {
                        ForEach(Cadence.allCases, id: \.self) { cadence in
                            Text(cadence.title).tag(cadence)
                        }
                    }
                } header: {
                    Text("Your budget period")
                } footer: {
                    Text("Budget periods start on payday. Changing this later takes effect "
                        + "from the next period — it never rewrites periods you have already used.")
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
                    Text("A short list to start with. Add, rename or remove them whenever you like.")
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

    private func toggle(_ name: String) {
        if chosenCategories.contains(name) {
            chosenCategories.remove(name)
        } else {
            chosenCategories.insert(name)
        }
    }

    private func finish() {
        isSaving = true
        onFinish(
            OnboardingAnswers(
                accountName: accountName,
                currency: currency,
                // The picker hands back an instant; the local calendar day is taken
                // from it here and the instant is discarded. See CivilDate+Clock.
                nextPayday: CivilDate(localDayOf: payday),
                cadence: cadence,
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
