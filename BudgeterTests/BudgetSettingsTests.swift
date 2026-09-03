//
//  BudgetSettingsTests.swift
//  BudgeterTests
//
//  DEC-036 keeps the pay schedule separate from the budget anchor. These tests exist
//  mostly to prove the two really are independent — the failure they guard against is
//  one field quietly serving both purposes, which is invisible until the day they
//  diverge.
//

import Foundation
import GRDB
import Testing
@testable import Budgeter

@Suite("Budget settings")
struct BudgetSettingsTests {
    private func date(_ iso: String) throws -> CivilDate {
        try #require(CivilDate(iso: iso))
    }

    @Test("a fresh database has no schedule at all, rather than a guessed one")
    func startsUnconfigured() throws {
        let database = try Fixture.database()
        try database.writer.read { db in
            let settings = try BudgetSettingsStore().load(db)
            #expect(settings.schedule == nil)
            #expect(settings.paySchedule == nil)
            #expect(!settings.payReminderEnabled)
        }
    }

    @Test("a saved schedule round-trips")
    func roundTrip() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let store = BudgetSettingsStore()
            var settings = try store.load(db)
            settings.schedule = PeriodSchedule(anchor: try date("2026-03-13"), cadence: .fortnightly)
            settings.paySchedule = PeriodSchedule(anchor: try date("2026-03-13"), cadence: .fortnightly)
            settings.payReminderTime = try #require(TimeOfDay(iso: "09:00"))
            settings.payReminderEnabled = true
            try store.save(settings, in: db)

            #expect(try store.load(db) == settings)
        }
    }

    @Test("the budget cadence can change without moving payday — DEC-036")
    func schedulesAreIndependent() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let store = BudgetSettingsStore()
            var settings = try store.load(db)
            settings.schedule = PeriodSchedule(anchor: try date("2026-03-13"), cadence: .fortnightly)
            settings.paySchedule = PeriodSchedule(anchor: try date("2026-03-13"), cadence: .fortnightly)
            try store.save(settings, in: db)

            // The user switches to monthly budgeting. They have not changed jobs.
            settings.schedule = PeriodSchedule(anchor: try date("2026-04-01"), cadence: .monthly)
            try store.save(settings, in: db)

            let reloaded = try store.load(db)
            #expect(reloaded.schedule?.cadence == .monthly)
            #expect(reloaded.paySchedule?.cadence == .fortnightly, "payday must not have moved")
            #expect(reloaded.paySchedule?.anchor.iso == "2026-03-13")
        }
    }

    @Test("the settings row is a singleton, like change_counter")
    func onlyOneRow() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: """
                INSERT INTO budget_settings (id, updated_at, change_seq)
                VALUES (2, '2026-01-01T00:00:00.000Z', 0)
                """)
            }
        }
    }

    @Test("an anchor without a cadence is meaningless, and the database says so")
    func anchorAndCadenceTravelTogether() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: "UPDATE budget_settings SET anchor_on = '2026-03-13' WHERE id = 1")
            }
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: "UPDATE budget_settings SET cadence = 'weekly' WHERE id = 1")
            }
        }
    }

    @Test("a reminder cannot be switched on with nothing to remind about — DEC-036")
    func reminderNeedsASchedule() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: "UPDATE budget_settings SET pay_reminder_enabled = 1 WHERE id = 1")
            }
        }
    }

    @Test("a reminder time must be a real time of day")
    func reminderTimeIsValidated() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try db.execute(sql: "UPDATE budget_settings SET pay_reminder_time = '23:59' WHERE id = 1")
            for bad in ["25:00", "9:00", "09:60", "0900", "tea time"] {
                #expect(throws: DatabaseError.self, "accepted \(bad)") {
                    try db.execute(
                        sql: "UPDATE budget_settings SET pay_reminder_time = ? WHERE id = 1",
                        arguments: [bad]
                    )
                }
            }
        }
    }

    @Test("only the three cadences are accepted")
    func cadenceIsConstrained() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: """
                UPDATE budget_settings SET anchor_on = '2026-03-13', cadence = 'daily' WHERE id = 1
                """)
            }
            #expect(Cadence.allCases.map(\.rawValue) == ["weekly", "fortnightly", "monthly"])
        }
    }
}
