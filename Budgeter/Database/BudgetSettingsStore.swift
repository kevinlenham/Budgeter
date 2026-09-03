//
//  BudgetSettingsStore.swift
//  Budgeter
//
//  The two schedules the app cannot observe for itself: when the user's budget
//  period starts (DEC-007) and when they get paid (DEC-036). Deliberately two
//  schedules, not one — see the table comment in Migration002.
//

import Foundation
import GRDB

nonisolated enum BudgetSettingsError: Error, Equatable {
    /// Period generation was asked to run before onboarding supplied an anchor.
    /// Refused rather than defaulted: an invented anchor produces a budget the
    /// user never chose, and DEC-007 exists because that is hard to notice.
    case notConfigured
    case malformedStoredValue(String)
}

nonisolated struct BudgetSettings: Equatable, Sendable {
    /// Anchor and cadence for budget periods. Nil until onboarding.
    var schedule: PeriodSchedule?
    /// DEC-036's separate pay schedule. Nil until the user confirms it.
    var paySchedule: PeriodSchedule?
    /// When the payday reminder fires, in local wall-clock time (DEC-036).
    var payReminderTime: TimeOfDay?
    /// Off by default. DEC-036 requests notification permission at the moment this
    /// is enabled, never at first launch.
    var payReminderEnabled: Bool = false
}

nonisolated struct BudgetSettingsStore: Sendable {
    var now: @Sendable () -> Date = { Date() }

    func load(_ db: Database) throws -> BudgetSettings {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM budget_settings WHERE id = 1") else {
            throw BudgetSettingsError.notConfigured
        }
        return BudgetSettings(
            schedule: try Self.schedule(anchor: row["anchor_on"], cadence: row["cadence"]),
            paySchedule: try Self.schedule(anchor: row["pay_anchor_on"], cadence: row["pay_cadence"]),
            payReminderTime: try Self.time(row["pay_reminder_time"]),
            payReminderEnabled: row["pay_reminder_enabled"] != 0
        )
    }

    func save(_ settings: BudgetSettings, in db: Database) throws {
        try db.execute(
            sql: """
            UPDATE budget_settings
               SET anchor_on            = ?,
                   cadence              = ?,
                   pay_anchor_on        = ?,
                   pay_cadence          = ?,
                   pay_reminder_time    = ?,
                   pay_reminder_enabled = ?,
                   updated_at           = ?,
                   change_seq           = ?
             WHERE id = 1
            """,
            arguments: [
                settings.schedule?.anchor.iso,
                settings.schedule?.cadence.rawValue,
                settings.paySchedule?.anchor.iso,
                settings.paySchedule?.cadence.rawValue,
                settings.payReminderTime?.iso,
                settings.payReminderEnabled ? 1 : 0,
                IngestFunnel.iso8601.format(now()),
                try AppDatabase.nextChangeSeq(db),
            ]
        )
    }

    /// The stored `HH:MM`, parsed as strictly as the column's CHECK accepts it —
    /// so a value that somehow got past the constraint is reported rather than
    /// silently becoming midnight.
    private static func time(_ stored: String?) throws -> TimeOfDay? {
        guard let stored else { return nil }
        guard let time = TimeOfDay(iso: stored) else {
            throw BudgetSettingsError.malformedStoredValue(stored)
        }
        return time
    }

    /// Both halves or neither — the same pairing the table's CHECK enforces, so a
    /// row that somehow lost one half is reported rather than silently half-read.
    private static func schedule(anchor: String?, cadence: String?) throws -> PeriodSchedule? {
        switch (anchor, cadence) {
        case (nil, nil):
            return nil
        case let (anchor?, cadence?):
            guard let date = CivilDate(iso: anchor) else {
                throw BudgetSettingsError.malformedStoredValue(anchor)
            }
            guard let cadence = Cadence(rawValue: cadence) else {
                throw BudgetSettingsError.malformedStoredValue(cadence)
            }
            return PeriodSchedule(anchor: date, cadence: cadence)
        default:
            throw BudgetSettingsError.malformedStoredValue("anchor and cadence must be set together")
        }
    }
}
