//
//  PayReminderView.swift
//  Budgeter
//
//  DEC-036's settings: pay anchor, pay cadence, reminder time, and the switch that
//  turns it on.
//
//  The pay schedule is its own thing, not the budget cadence wearing a hat, and
//  this screen is where that becomes visible. DEC-036: "pay rhythm and budget
//  rhythm are the same thing by default and not by definition ... a user switching
//  from fortnightly to monthly budgeting has not changed jobs." Onboarding
//  pre-filled both from the same answers, so the usual case is that this screen is
//  already correct and the user only flips the switch.
//
//  Permission is requested at the moment the switch is turned on — never at first
//  launch — following DEC-024's consent precedent. A refusal does not turn the
//  setting back off: the in-app card keeps working regardless, and DEC-036 requires
//  the feature to degrade rather than break. It is said plainly on screen instead.
//

import SwiftUI

struct PayReminderView: View {
    @Environment(AppModel.self) private var model

    @State private var anchor = Date()
    @State private var cadence: Cadence = .fortnightly
    @State private var time = Date()
    @State private var isEnabled = false
    @State private var wasDenied = false
    @State private var errorMessage: String?
    /// Set once the stored values are on screen. Until then the change handlers
    /// stay quiet, so loading the settings does not look like the user editing them.
    @State private var hasLoaded = false

    var body: some View {
        Form {
            Section {
                DatePicker("Next payday", selection: $anchor, displayedComponents: .date)
                Picker("How often", selection: $cadence) {
                    ForEach(Cadence.allCases, id: \.self) { cadence in
                        Text(cadence.title).tag(cadence)
                    }
                }
            } header: {
                Text("When you are paid")
            } footer: {
                Text("Kept separately from your budget period, so changing one never "
                    + "silently moves the other.")
            }

            Section {
                Toggle("Remind me on payday", isOn: $isEnabled)
                if isEnabled {
                    DatePicker("At", selection: $time, displayedComponents: .hourAndMinute)
                }
            } footer: {
                if wasDenied {
                    Text("Notifications are turned off for Budgeter in iOS Settings, so no "
                        + "reminder will appear. Budgeter will still show a note in the ledger "
                        + "when a payday has gone by without any pay logged.")
                        .foregroundStyle(.orange)
                } else {
                    Text("One notification per payday, with no amount in it. Tapping it opens "
                        + "a blank income entry — Budgeter never guesses what you were paid.")
                }
            }

            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Payday")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: anchor) { _, _ in saveSchedule() }
        .onChange(of: cadence) { _, _ in saveSchedule() }
        .onChange(of: time) { _, _ in saveSchedule() }
        .onChange(of: isEnabled) { _, newValue in toggle(to: newValue) }
    }

    // MARK: - Actions

    private func load() async {
        await model.reloadSettings()
        let settings = model.settings
        if let schedule = settings.paySchedule {
            anchor = schedule.anchor.middayDate()
            cadence = schedule.cadence
        }
        let today = CivilDate.today()
        if let stored = settings.payReminderTime, let date = stored.date(on: today) {
            time = date
        } else if let fallback = TimeOfDay.defaultReminder.date(on: today) {
            time = fallback
        }
        isEnabled = settings.payReminderEnabled
        hasLoaded = true
        if isEnabled {
            wasDenied = await !model.reminders.scheduler.isAuthorised()
        }
    }

    /// Writes the three stored values. Does not touch the notification queue —
    /// the two callers below decide when that happens, because enabling has to ask
    /// for permission in between.
    private func persist() async throws {
        let schedule = PeriodSchedule(anchor: CivilDate(localDayOf: anchor), cadence: cadence)
        let reminderTime = TimeOfDay(localTimeOf: time)
        try await model.database.writer.write { db in
            var settings = try BudgetSettingsStore().load(db)
            settings.paySchedule = schedule
            settings.payReminderTime = reminderTime
            try BudgetSettingsStore().save(settings, in: db)
        }
        await model.reloadSettings()
    }

    /// Saves an edit and rebuilds the queue.
    ///
    /// A refresh after every edit rather than only on launch: the pending
    /// notifications are computed from these values, so leaving them stale would
    /// mean the reminder keeps firing on the old schedule until the app is next
    /// relaunched — the exact "why didn't this fire" confusion DEC-036 avoids
    /// elsewhere by refusing `BGTaskScheduler`.
    private func saveSchedule() {
        guard hasLoaded else { return }
        Task {
            do {
                try await persist()
                try await model.reminders.refresh(in: model.database)
                errorMessage = nil
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }

    private func toggle(to enabled: Bool) {
        guard hasLoaded else { return }
        Task {
            do {
                if enabled {
                    // The schedule and time are written first, and awaited: the
                    // CHECK on `budget_settings` refuses an enabled reminder that
                    // has no time to fire at, so these cannot race.
                    try await persist()
                    wasDenied = try await !model.reminders.enable(in: model.database)
                } else {
                    try await model.reminders.disable(in: model.database)
                    wasDenied = false
                }
                await model.reloadSettings()
                errorMessage = nil
            } catch {
                errorMessage = String(describing: error)
                isEnabled = false
            }
        }
    }
}
