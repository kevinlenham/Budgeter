//
//  SettingsView.swift
//  Budgeter
//
//  The third tab, and the answer to a gap Sprint 3 left open: once onboarding had
//  run there was no way to change any of its answers. A budget period anchored on
//  the wrong payday, or a category named wrong on the first day, was permanent.
//
//  Everything here is a door to a screen that owns its own writes. This file holds
//  no logic beyond deciding what to show as each row's summary, which is why the
//  summaries all come from `AppModel.settings` — one read, refreshed when a child
//  screen says something changed.
//

import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                Section("Budget") {
                    NavigationLink {
                        CadenceSwitchView(
                            database: model.database,
                            current: model.settings.schedule?.cadence ?? .fortnightly,
                            // A full restart rather than a settings re-read: a switch
                            // changes where future boundaries fall, and `start()` is
                            // what generates periods against the new schedule.
                            onSwitched: { Task { await model.start() } }
                        )
                    } label: {
                        LabeledContent("Budget period", value: cadenceSummary)
                    }

                    NavigationLink {
                        PayReminderView()
                    } label: {
                        LabeledContent("Payday", value: paydaySummary)
                    }
                }

                Section("Categorising") {
                    NavigationLink("Categories") {
                        CategoriesView(database: model.database)
                    }
                    NavigationLink("Remembered merchants") {
                        MerchantRulesView(database: model.database)
                    }
                }

                Section {
                    NavigationLink("Export and restore") {
                        ExportView(database: model.database)
                    }
                } header: {
                    Text("Your data")
                } footer: {
                    Text("Budgeter keeps everything on this device and sends nothing anywhere. "
                        + "That makes an export the only copy that survives losing the phone, "
                        + "so it is worth taking one occasionally.")
                }
            }
            .navigationTitle("Settings")
        }
        .task { await model.reloadSettings() }
    }

    private var cadenceSummary: String {
        model.settings.schedule?.cadence.title ?? "Not set"
    }

    private var paydaySummary: String {
        guard let schedule = model.settings.paySchedule else { return "Not set" }
        guard model.settings.payReminderEnabled else { return schedule.cadence.title }
        return "\(schedule.cadence.title), reminder on"
    }
}
