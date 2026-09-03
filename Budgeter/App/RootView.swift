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
        .task { await model.start() }
    }
}
