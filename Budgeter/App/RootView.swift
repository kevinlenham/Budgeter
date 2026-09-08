//
//  RootView.swift
//  Budgeter
//
//  Decides which of the three states the app is in: still opening the database,
//  waiting for onboarding, or running.
//
//  Running means four tabs — Overview, Finances, Statistics, Settings. Transaction
//  history no longer has a tab of its own: it lives inside Finances, which shows a
//  day, a week or a whole budget period and the entries behind whichever is
//  selected. A list of everything you ever spent is not a thing anyone opens an app
//  to read; "what did today cost" is.
//

import SwiftUI

struct RootView: View {
    @State var model: AppModel

    /// Dark unless the user says otherwise — see `ThemePreference` for why the
    /// default is not `.system`.
    @AppStorage(ThemeStore.key) private var theme = ThemePreference.dark

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                ZStack {
                    Palette.background.ignoresSafeArea()
                    ProgressView().controlSize(.large).tint(Palette.accent)
                }

            case .onboarding:
                OnboardingView { answers in
                    Task { await model.completeOnboarding(answers) }
                }

            case .ready:
                TabView {
                    Tab("Overview", systemImage: "house.fill") {
                        OverviewView(database: model.database)
                    }
                    Tab("Finances", systemImage: "wallet.bifold.fill") {
                        FinancesView(database: model.database)
                    }
                    Tab("Statistics", systemImage: "chart.bar.fill") {
                        StatisticsView(database: model.database)
                    }
                    Tab("Settings", systemImage: "gearshape.fill") {
                        SettingsView()
                    }
                }
                .tint(Palette.accent)

            case let .failed(message):
                // Shown rather than swallowed: a database that will not open is not
                // a state to paper over with an empty list, and the message is the
                // only thing that makes it diagnosable from the phone.
                ZStack {
                    Palette.background.ignoresSafeArea()
                    ContentUnavailableView {
                        Label("Budgeter could not start", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    }
                }
            }
        }
        // The model is in the environment as well as being held here, because the
        // settings screens and the payday reminder's deep link all need it and
        // threading it through three levels of navigation by hand is how one of
        // them ends up with a different copy.
        .environment(model)
        // Applied at the root so every sheet and every pushed screen inherits it.
        // `Palette`'s tokens resolve against this, not against the device setting.
        .preferredColorScheme(theme.colorScheme)
        .task { await model.start() }
    }
}
