//
//  RootView.swift
//  Budgeter
//
//  Decides which of the three states the app is in: still opening the database,
//  waiting for onboarding, or running.
//

import SwiftUI

struct RootView: View {
    @State var model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                ProgressView().controlSize(.large)

            case .onboarding:
                OnboardingView { answers in
                    Task { await model.completeOnboarding(answers) }
                }

            case .ready:
                TabView {
                    Tab("Ledger", systemImage: "list.bullet") {
                        LedgerView(database: model.database)
                    }
                    Tab("Budget", systemImage: "chart.pie") {
                        BudgetView(database: model.database)
                    }
                    Tab("Settings", systemImage: "gear") {
                        SettingsView()
                    }
                }

            case let .failed(message):
                // Shown rather than swallowed: a database that will not open is not
                // a state to paper over with an empty list, and the message is the
                // only thing that makes it diagnosable from the phone.
                ContentUnavailableView {
                    Label("Budgeter could not start", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                }
            }
        }
        // The model is in the environment as well as being held here, because the
        // settings screens and the payday reminder's deep link all need it and
        // threading it through three levels of navigation by hand is how one of
        // them ends up with a different copy.
        .environment(model)
        .task { await model.start() }
    }
}
