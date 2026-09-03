//
//  OnboardingFlowTests.swift
//  BudgeterTests
//
//  The path from a fresh install to a usable budget screen, without a device. The
//  screens themselves are thin; everything they call is here.
//

import Foundation
import GRDB
import Testing
@testable import Budgeter

@Suite("From fresh install to a budget")
struct OnboardingFlowTests {
    private func date(_ iso: String) throws -> CivilDate {
        try #require(CivilDate(iso: iso))
    }

    /// Everything `AppModel.completeOnboarding` does, in one transaction.
    private func onboard(
        _ db: Database,
        payday: String = "2026-09-11",
        cadence: Cadence = .fortnightly
    ) throws -> UUID {
        let account = try AccountStore().create(name: "Everyday", currency: .aud, in: db)
        for name in CategoryStore.starters {
            try CategoryStore().create(name: name, in: db)
        }
        var settings = try BudgetSettingsStore().load(db)
        let schedule = PeriodSchedule(anchor: try date(payday), cadence: cadence)
        settings.schedule = schedule
        settings.paySchedule = schedule
        try BudgetSettingsStore().save(settings, in: db)
        return account
    }

    @Test("onboarding leaves the app configured, with a current period to spend in")
    func onboardingProducesACurrentPeriod() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try onboard(db)
            let today = try date("2026-09-02")
            try PeriodGenerator().generate(through: today, in: db)

            let settings = try BudgetSettingsStore().load(db)
            #expect(settings.schedule != nil)
            #expect(try Queries.period(containing: today, in: db) != nil)
        }
    }

    @Test("the pay schedule is pre-filled from the same answers, but stays its own field — DEC-036")
    func payScheduleIsPrefilledNotShared() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try onboard(db)

            var settings = try BudgetSettingsStore().load(db)
            #expect(settings.paySchedule == settings.schedule)
            #expect(!settings.payReminderEnabled, "DEC-036: off until the user enables it")

            // Changing the budget cadence later leaves payday where it was.
            settings.schedule = PeriodSchedule(anchor: try date("2026-10-01"), cadence: .monthly)
            try BudgetSettingsStore().save(settings, in: db)

            let reloaded = try BudgetSettingsStore().load(db)
            #expect(reloaded.paySchedule?.cadence == .fortnightly)
        }
    }

    @Test("a limit set on the budget screen shows up in the period the user is in")
    func settingALimitAffectsTheCurrentPeriod() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try onboard(db)
            let today = try date("2026-09-02")
            try PeriodGenerator().generate(through: today, in: db)

            let period = try #require(try Queries.period(containing: today, in: db))
            let groceries = try #require(
                try CategoryStore().all(in: db).first { $0.name == "Groceries" }
            )
            let categoryID = try #require(UUID(uuidString: groceries.id))
            let startsOn = try #require(CivilDate(iso: period.startsOn))

            // Exactly what LimitEditorView does on save.
            try CategoryLimits().setLimit(
                categoryID: categoryID,
                amount: Money(minorUnits: 50000, currency: .aud),
                effectiveFrom: startsOn,
                in: db
            )
            try PeriodGenerator().resnapshot(period: period, in: db)

            try TransactionStore().create(
                TransactionDraft(
                    kind: .expense,
                    amount: Money(minorUnits: 34000, currency: .aud),
                    accountID: account,
                    categoryID: categoryID,
                    merchant: "Woolworths",
                    bookedOn: today
                ),
                in: db
            )

            let line = try #require(
                try Queries.budgetLines(periodID: period.id, in: db).first { $0.categoryId == groceries.id }
            )
            #expect(line.limitMinor == 50000)
            #expect(line.spentMinor == 34000, "$340 of $500")
            #expect(line.remainingMinor == 16000)
            #expect(!line.isOverspent)
        }
    }

    @Test("changing a limit twice in one period revises it rather than stacking rows")
    func revisingALimitInTheSamePeriod() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try onboard(db)
            let today = try date("2026-09-02")
            try PeriodGenerator().generate(through: today, in: db)

            let period = try #require(try Queries.period(containing: today, in: db))
            let startsOn = try #require(CivilDate(iso: period.startsOn))
            let groceries = try #require(try CategoryStore().all(in: db).first { $0.name == "Groceries" })
            let categoryID = try #require(UUID(uuidString: groceries.id))

            for amount in [Int64(50000), 40000, 45000] {
                try CategoryLimits().setLimit(
                    categoryID: categoryID,
                    amount: Money(minorUnits: amount, currency: .aud),
                    effectiveFrom: startsOn,
                    in: db
                )
                try PeriodGenerator().resnapshot(period: period, in: db)
            }

            let rows = try CategoryLimitRecord.fetchAll(
                db, sql: "SELECT * FROM category_limits WHERE category_id = ?",
                arguments: [groceries.id]
            )
            #expect(rows.count == 1, "one decision revised, not three stacked")
            #expect(rows.first?.amountMinor == 45000)

            let line = try #require(try Queries.budgetLines(periodID: period.id, in: db).first)
            #expect(line.limitMinor == 45000)
        }
    }

    @Test("a past period keeps the limit it had when a later one is changed — DEC-008")
    func pastPeriodsKeepTheirLimits() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try onboard(db, payday: "2026-09-01", cadence: .monthly)
            let groceries = try #require(try CategoryStore().all(in: db).first { $0.name == "Groceries" })
            let categoryID = try #require(UUID(uuidString: groceries.id))

            try PeriodGenerator().generate(through: try date("2026-09-10"), in: db)
            let september = try #require(try Queries.period(containing: try date("2026-09-10"), in: db))
            try CategoryLimits().setLimit(
                categoryID: categoryID,
                amount: Money(minorUnits: 50000, currency: .aud),
                effectiveFrom: try #require(CivilDate(iso: september.startsOn)),
                in: db
            )
            try PeriodGenerator().resnapshot(period: september, in: db)

            // A month later, the user raises it.
            try PeriodGenerator().generate(through: try date("2026-10-10"), in: db)
            let october = try #require(try Queries.period(containing: try date("2026-10-10"), in: db))
            try CategoryLimits().setLimit(
                categoryID: categoryID,
                amount: Money(minorUnits: 70000, currency: .aud),
                effectiveFrom: try #require(CivilDate(iso: october.startsOn)),
                in: db
            )
            try PeriodGenerator().resnapshot(period: october, in: db)

            let septemberLine = try #require(try Queries.budgetLines(periodID: september.id, in: db).first)
            let octoberLine = try #require(try Queries.budgetLines(periodID: october.id, in: db).first)
            #expect(septemberLine.limitMinor == 50000, "September must still read $500")
            #expect(octoberLine.limitMinor == 70000)
        }
    }

    @Test("a category with no limit is left off the budget screen rather than shown as $0")
    func unbudgetedCategoriesAreSeparate() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try onboard(db)
            let today = try date("2026-09-02")
            try PeriodGenerator().generate(through: today, in: db)

            let snapshot = try BudgetSnapshot(today: today, in: db)
            #expect(snapshot.lines.isEmpty)
            #expect(snapshot.unbudgeted.count == CategoryStore.starters.count)
        }
    }

    @Test("before onboarding there is no period, and the screen has nothing to draw")
    func beforeOnboarding() throws {
        let database = try Fixture.database()
        try database.writer.read { db in
            let snapshot = try BudgetSnapshot(today: try date("2026-09-02"), in: db)
            #expect(snapshot.period == nil)
            #expect(snapshot.lines.isEmpty)
            #expect(snapshot.unbudgeted.isEmpty)
        }
    }
}
