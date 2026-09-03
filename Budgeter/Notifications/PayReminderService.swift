//
//  PayReminderService.swift
//  Budgeter
//
//  The decisions between the settings row and `UNUserNotificationCenter`: whether
//  to schedule anything, which dates, and what to do when permission is not there.
//
//  Separate from `SystemPayReminderScheduler` so that all of it can be tested
//  against a fake — DEC-036 says "scheduling behaviour is device-only ... leaving
//  only the thin `UNUserNotificationCenter` binding unverified", and this is the
//  line drawn at exactly that point.
//

import Foundation
import GRDB

nonisolated struct PayReminderService: Sendable {
    var scheduler: any PayReminderScheduling
    var now: @Sendable () -> Date = { Date() }
    var calendar: @Sendable () -> Calendar = { .current }

    // MARK: - Enabling

    /// Turns the reminder on, asking for permission at that moment and not before
    /// (DEC-036, following DEC-024's consent precedent).
    ///
    /// Returns whether permission was granted. A refusal is **not** an error and
    /// does not roll the setting back: DEC-036 requires the feature to degrade
    /// rather than break, and the in-app card (`PayStatus`) is what carries it when
    /// notifications cannot. The caller says so on screen.
    @discardableResult
    func enable(in database: AppDatabase) async throws -> Bool {
        let granted = try await scheduler.requestAuthorisation()
        try await database.writer.write { db in
            var settings = try BudgetSettingsStore(now: now).load(db)
            // The CHECK on budget_settings refuses an enabled reminder with no time
            // to fire at, so the default is filled in here rather than left to the
            // settings screen to remember.
            if settings.payReminderTime == nil {
                settings.payReminderTime = .defaultReminder
            }
            settings.payReminderEnabled = true
            try BudgetSettingsStore(now: now).save(settings, in: db)
        }
        if granted {
            try await refresh(in: database)
        }
        return granted
    }

    func disable(in database: AppDatabase) async throws {
        try await database.writer.write { db in
            var settings = try BudgetSettingsStore(now: now).load(db)
            settings.payReminderEnabled = false
            try BudgetSettingsStore(now: now).save(settings, in: db)
        }
        await scheduler.clearQueue()
    }

    // MARK: - Topping up

    /// Refills the rolling queue. Called on launch.
    ///
    /// DEC-036 chose launch over `BGTaskScheduler` for the DEC-009 reason: the
    /// system runs background tasks when it chooses, and "why didn't this fire" is
    /// not a debugging session worth having twice. It is cheap — a settings read
    /// and at most `maximumPending` scheduling calls — so it runs unconditionally
    /// rather than behind a "have we done this today" flag that could itself be
    /// wrong.
    ///
    /// Clears the queue and returns when the reminder is off, or when permission
    /// has been revoked since it was granted. Revocation is silent in iOS, so this
    /// is the only place the app would ever notice.
    func refresh(in database: AppDatabase) async throws {
        let settings = try await database.writer.read { db in
            try BudgetSettingsStore().load(db)
        }

        guard settings.payReminderEnabled,
              let schedule = settings.paySchedule,
              let time = settings.payReminderTime,
              await scheduler.isAuthorised()
        else {
            await scheduler.clearQueue()
            return
        }

        try await scheduler.replaceQueue(with: instants(for: schedule, at: time))
    }

    /// DEC-036's "Remind me tomorrow": one extra one-shot, and the anchor is not
    /// touched. The regular queue is rebuilt alongside it, so a snooze can never
    /// leave the app with tomorrow's reminder and nothing after it.
    func snoozeUntilTomorrow(in database: AppDatabase) async throws {
        let settings = try await database.writer.read { db in
            try BudgetSettingsStore().load(db)
        }
        guard settings.payReminderEnabled,
              let schedule = settings.paySchedule,
              let time = settings.payReminderTime,
              await scheduler.isAuthorised()
        else { return }

        let calendar = calendar()
        let tomorrow = CivilDate.today(calendar: calendar, now: now()).addingDays(1)
        let extra = time.date(on: tomorrow, calendar: calendar)

        let dates = ([extra].compactMap { $0 } + instants(for: schedule, at: time))
            .sorted()
        try await scheduler.replaceQueue(with: Array(dates.prefix(PayReminderQueue.maximumPending)))
    }

    // MARK: - Private

    /// The queue's dates, as the instants `UNCalendarNotificationTrigger` wants.
    ///
    /// `CivilDate` + `TimeOfDay` → `Date` happens here and only here on this path,
    /// and it happens last: the whole decision about *which days* is made in the
    /// calendar-date world, so no part of it can be shifted by a time zone.
    private func instants(for schedule: PeriodSchedule, at time: TimeOfDay) -> [Date] {
        let calendar = calendar()
        let clock = now()
        let days = PayReminderQueue.dates(
            schedule: schedule,
            today: CivilDate.today(calendar: calendar, now: clock),
            reminderTime: time,
            currentTime: TimeOfDay(localTimeOf: clock, calendar: calendar)
        )
        return days.compactMap { time.date(on: $0, calendar: calendar) }
    }
}
