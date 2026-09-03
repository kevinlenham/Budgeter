//
//  AppModel.swift
//  Budgeter
//
//  Owns the database connection and the two things that have to happen before any
//  screen can draw: knowing whether onboarding has run, and catching the periods up
//  to today.
//
//  DEC-009 chose lazy generation, called on launch and before any period query, so
//  this is where "on launch" lives. It is cheap when there is nothing to do — one
//  indexed read — which is what makes calling it unconditionally the right shape.
//

import Foundation
import GRDB
import SwiftUI
import UserNotifications

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case loading
        case onboarding
        case ready
        case failed(String)
    }

    let database: AppDatabase
    private(set) var phase: Phase = .loading
    private(set) var settings = BudgetSettings()

    /// Set when a payday reminder has asked for an income entry (DEC-036). The
    /// ledger presents a blank income form while it is true and clears it on
    /// dismissal — a route rather than a call, so the form is presented by whatever
    /// is on screen rather than by a notification handler reaching into the view
    /// hierarchy.
    var isLoggingPay = false

    let reminders: PayReminderService
    private let router = PayReminderRouter()

    init(database: AppDatabase, scheduler: any PayReminderScheduling = SystemPayReminderScheduler()) {
        self.database = database
        reminders = PayReminderService(scheduler: scheduler)
    }

    /// The on-device database, in Application Support so it is covered by encrypted
    /// device backup (DEC-002) and the file protection DEC-026 will rely on.
    static func live() throws -> AppModel {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return try AppModel(database: .onDisk(at: directory.appending(path: "budgeter.sqlite")))
    }

    /// Loads settings, fills in any periods missing since the last launch, and tops
    /// up the payday reminder queue (DEC-036).
    func start() async {
        connectReminderActions()
        do {
            let today = CivilDate.today()
            let settings = try await database.writer.write { db -> BudgetSettings in
                let settings = try BudgetSettingsStore().load(db)
                if settings.schedule != nil {
                    try PeriodGenerator().generate(through: today, in: db)
                }
                return settings
            }
            self.settings = settings
            phase = settings.schedule == nil ? .onboarding : .ready
        } catch {
            phase = .failed(String(describing: error))
            return
        }

        // Deliberately after `phase` is set, and deliberately not fatal. A queue
        // that could not be topped up is a reminder that does not fire, which
        // DEC-036 already requires the in-app card to cover; a launch that fails
        // because of it would be a much worse trade.
        try? await reminders.refresh(in: database)
    }

    /// Writes the answers onboarding collected, then starts generating periods.
    func completeOnboarding(_ answers: OnboardingAnswers) async {
        do {
            try await database.writer.write { db in
                try AccountStore().create(name: answers.accountName, currency: answers.currency, in: db)
                for name in answers.categoryNames {
                    try CategoryStore().create(name: name, in: db)
                }

                var settings = try BudgetSettingsStore().load(db)
                settings.schedule = answers.schedule
                // DEC-043: payday is no longer asked here. `paySchedule` stays nil
                // until the user visits Settings → Payday and gives a real payday
                // date — a different question from "how should the budget period
                // run", which DEC-036 already kept as a separate schema field.
                try BudgetSettingsStore().save(settings, in: db)
            }
            await start()
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    /// Re-reads the settings row after a screen has changed it.
    ///
    /// Not `start()`: that regenerates periods and resets `phase`, which would drop
    /// the user back to a spinner every time they toggled a switch. The settings
    /// screens own their own writes and call this afterwards.
    func reloadSettings() async {
        guard let settings = try? await database.writer.read({ db in
            try BudgetSettingsStore().load(db)
        }) else { return }
        self.settings = settings
    }

    // MARK: - Reminders

    /// Points the notification delegate at this model. Done on every `start()`
    /// rather than in `init`, because the delegate must be set before iOS delivers
    /// a response and `init` may run before the scene exists.
    private func connectReminderActions() {
        router.onLogNow = { [weak self] in
            self?.isLoggingPay = true
        }
        router.onRemindTomorrow = { [weak self] in
            guard let self else { return }
            try? await reminders.snoozeUntilTomorrow(in: database)
        }
        UNUserNotificationCenter.current().delegate = router
    }
}

/// What onboarding collects, in one value, so the write is a single transaction.
nonisolated struct OnboardingAnswers: Equatable, Sendable {
    var accountName: String
    var currency: Currency
    /// DEC-043: computed by `CalendarCadence`, not asked for as a date — the only
    /// question onboarding still poses is fortnightly's cycle phase, and that is
    /// folded into this anchor before it ever reaches here.
    var schedule: PeriodSchedule
    var categoryNames: [String]
}
