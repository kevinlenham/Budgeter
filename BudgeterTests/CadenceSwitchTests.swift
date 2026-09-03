//
//  CadenceSwitchTests.swift
//  BudgeterTests
//
//  DEC-043's instant switch. The property that matters here is not "when does it
//  take effect" — the answer is always "today" — but that truncating the current
//  period never corrupts anything: no negative-length period, no overlap with what
//  comes next, no lost history, and the new budget applies from exactly the right
//  date.
//

import Foundation
import GRDB
import Testing
@testable import Budgeter

@Suite("Switching cadence")
struct CadenceSwitchTests {
    private func date(_ iso: String) throws -> CivilDate {
        try #require(CivilDate(iso: iso))
    }

    /// Onboarded fortnightly on 2026-09-11, so the period in progress on the 2nd
    /// runs 2026-08-28 to 2026-09-10.
    @discardableResult
    private func configured(_ db: Database) throws -> (account: UUID, groceries: UUID) {
        let account = try Fixture.onboard(db)
        let groceries = try Fixture.category("Groceries", in: db)
        try CategoryLimits().setLimit(
            categoryID: groceries,
            amount: Money(minorUnits: 20000, currency: .aud),
            effectiveFrom: try date("2026-08-28"),
            in: db
        )
        let period = try #require(try Queries.period(containing: try date("2026-09-02"), in: db))
        try PeriodGenerator().resnapshot(period: period, in: db)
        return (account, groceries)
    }

    // MARK: - Planning

    @Test("the plan is always effective today, whatever cadence is chosen")
    func planIsAlwaysEffectiveToday() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try configured(db)
            let today = try date("2026-09-02")
            for target in [Cadence.weekly, .fortnightly, .monthly] {
                let plan = try CadenceSwitch().plan(to: target, asOf: today, in: db)
                #expect(plan.effectiveFrom == today)
                #expect(plan.to == target)
            }
        }
    }

    @Test("planning writes nothing")
    func planningIsReadOnly() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try configured(db)
            let before = try BudgetSettingsStore().load(db)
            _ = try CadenceSwitch().plan(to: .monthly, asOf: try date("2026-09-02"), in: db)
            #expect(try BudgetSettingsStore().load(db) == before)
        }
    }

    @Test("every category is listed, with a scaled suggestion where there is one")
    func everyCategoryIsOffered() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let (_, groceries) = try configured(db)
            let plan = try CadenceSwitch().plan(to: .monthly, asOf: try date("2026-09-02"), in: db)

            // DEC-008: "show every category with a scaled-and-rounded suggested
            // limit the user can edit" — every category, not only the budgeted ones,
            // because a switch is a natural moment to set the ones you skipped.
            #expect(plan.lines.count == CategoryStore.starters.count)

            let line = try #require(plan.lines.first { $0.categoryID == groceries })
            #expect(line.currentLimit == Money(minorUnits: 20000, currency: .aud))
            #expect(line.suggestedLimit == Money(minorUnits: 43500, currency: .aud))

            // A category with no limit gets no suggestion: there is nothing to
            // scale, and a zero would be a decision nobody made.
            let unbudgeted = try #require(plan.lines.first { $0.categoryID != groceries })
            #expect(unbudgeted.currentLimit == nil)
            #expect(unbudgeted.suggestedLimit == nil)
        }
    }

    @Test("the overall budget is offered and scaled the same way a category is")
    func overallBudgetIsOffered() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try configured(db)
            try OverallLimits().setLimit(
                amount: Money(minorUnits: 40000, currency: .aud),
                effectiveFrom: try date("2026-08-28"),
                in: db
            )

            let plan = try CadenceSwitch().plan(to: .monthly, asOf: try date("2026-09-02"), in: db)
            #expect(plan.overallCurrent == Money(minorUnits: 40000, currency: .aud))
            #expect(plan.overallSuggested == Money(minorUnits: 87000, currency: .aud))
        }
    }

    // MARK: - Applying

    @Test("applying truncates the current period to end yesterday and starts a new one today")
    func currentPeriodIsTruncated() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let (account, groceries) = try configured(db)
            try TransactionStore().create(
                TransactionDraft(
                    kind: .expense,
                    amount: Money(minorUnits: 6000, currency: .aud),
                    accountID: account,
                    categoryID: groceries,
                    merchant: "Woolworths",
                    bookedOn: try date("2026-09-02")
                ),
                in: db
            )

            let today = try date("2026-09-02")
            let plan = try CadenceSwitch().plan(to: .monthly, asOf: today, in: db)
            try CadenceSwitch().apply(
                plan, overallLimit: nil,
                limits: [groceries: Money(minorUnits: 43500, currency: .aud)], in: db
            )

            // The old period is retired, not deleted from history: it still shows
            // up as a distinct, tombstone-free row spanning what it actually
            // covered — 2026-08-28 to 2026-09-01, the day before the switch.
            let oldPeriod = try #require(try PeriodRecord.fetchOne(
                db, sql: "SELECT * FROM periods WHERE id = ?", arguments: [plan.currentPeriodID.uuidString]
            ))
            #expect(oldPeriod.startsOn == "2026-08-28")
            #expect(oldPeriod.endsOn == "2026-09-01")
            #expect(oldPeriod.deletedAt == nil)

            // A new period, on the new cadence, owns today onward.
            try PeriodGenerator().generate(through: today, in: db)
            let newPeriod = try #require(try Queries.period(containing: today, in: db))
            #expect(newPeriod.startsOn == "2026-09-02")
            #expect(newPeriod.cadence == "monthly")

            // The transaction already logged today is still there, and still
            // spent — it is dated, not linked to a period id, so it is simply
            // picked up by whichever period's date range now contains it.
            let spent = try Int64.fetchOne(db, sql: """
            SELECT COALESCE(SUM(amount_minor), 0) FROM spending WHERE category_id = ?
            """, arguments: [groceries.uuidString])
            #expect(spent == 6000)
        }
    }

    @Test("nothing before the switch moves — a query for yesterday still finds the old period")
    func historyBeforeTheSwitchIsUntouched() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try configured(db)
            let today = try date("2026-09-02")
            let plan = try CadenceSwitch().plan(to: .monthly, asOf: today, in: db)
            try CadenceSwitch().apply(plan, overallLimit: nil, limits: [:], in: db)

            let yesterday = try #require(try Queries.period(containing: try date("2026-09-01"), in: db))
            #expect(yesterday.startsOn == "2026-08-28")
            #expect(yesterday.endsOn == "2026-09-01")
            #expect(yesterday.cadence == "fortnightly")
        }
    }

    @Test("a period generated immediately after the switch never overlaps the truncated one")
    func noOverlapAfterTruncation() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try configured(db)
            let today = try date("2026-09-02")
            let plan = try CadenceSwitch().plan(to: .weekly, asOf: today, in: db)
            try CadenceSwitch().apply(plan, overallLimit: nil, limits: [:], in: db)

            // Generating well past the switch must not throw — a thrown error here
            // fails the test on its own — and must not overlap.
            try PeriodGenerator().generate(through: try date("2026-10-05"), in: db)

            let rows = try Row.fetchAll(db, sql: """
            SELECT starts_on, ends_on FROM periods WHERE deleted_at IS NULL ORDER BY starts_on
            """)
            for (previous, next) in zip(rows, rows.dropFirst()) {
                let previousEnd = previous["ends_on"] as String
                let nextStart = next["starts_on"] as String
                #expect(nextStart > previousEnd, "\(previousEnd) and \(nextStart) overlap")
            }
        }
    }

    @Test("switching twice on the same day retires the same-day period instead of writing an invalid range")
    func switchingTwiceSameDayRetiresRatherThanTruncates() throws {
        // Regression case: if the "current" period already starts today (because
        // it is the result of an earlier switch, today), there is no "yesterday"
        // within it. Forcing ends_on = yesterday would write ends_on < starts_on,
        // which the schema's own CHECK refuses.
        let database = try Fixture.database()
        try database.writer.write { db in
            try configured(db)
            let today = try date("2026-09-02")

            let first = try CadenceSwitch().plan(to: .monthly, asOf: today, in: db)
            try CadenceSwitch().apply(first, overallLimit: nil, limits: [:], in: db)
            try PeriodGenerator().generate(through: today, in: db)

            let intermediate = try #require(try Queries.period(containing: today, in: db))
            #expect(intermediate.startsOn == "2026-09-02")

            let second = try CadenceSwitch().plan(to: .weekly, asOf: today, in: db)
            #expect(second.currentPeriodStartsOn == today)
            try CadenceSwitch().apply(second, overallLimit: nil, limits: [:], in: db)

            // The same-day monthly period is retired, not left with an invalid
            // (or zero-length, or overlapping) range.
            let retired = try #require(try PeriodRecord.fetchOne(
                db, sql: "SELECT * FROM periods WHERE id = ?", arguments: [intermediate.id]
            ))
            #expect(retired.deletedAt != nil)

            try PeriodGenerator().generate(through: today, in: db)
            let finalPeriod = try #require(try Queries.period(containing: today, in: db))
            #expect(finalPeriod.cadence == "weekly")
            #expect(finalPeriod.startsOn == "2026-09-02")
        }
    }

    @Test("the new limits apply from today, and the old ones survive behind it")
    func limitsAreEffectiveDatedForward() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let (_, groceries) = try configured(db)
            let today = try date("2026-09-02")
            let plan = try CadenceSwitch().plan(to: .monthly, asOf: today, in: db)
            try CadenceSwitch().apply(
                plan, overallLimit: nil,
                limits: [groceries: Money(minorUnits: 43500, currency: .aud)], in: db
            )

            let limits = CategoryLimits()
            // DEC-008's schema consequence: "a past period must display the limit
            // that applied *then*, not today's."
            #expect(
                try limits.limit(categoryID: groceries, on: try date("2026-09-01"), in: db)
                    == Money(minorUnits: 20000, currency: .aud)
            )
            #expect(
                try limits.limit(categoryID: groceries, on: today, in: db)
                    == Money(minorUnits: 43500, currency: .aud)
            )
        }
    }

    @Test("the overall budget, once set, applies from today too")
    func overallLimitAppliesFromToday() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try configured(db)
            let today = try date("2026-09-02")
            let plan = try CadenceSwitch().plan(to: .monthly, asOf: today, in: db)
            try CadenceSwitch().apply(
                plan, overallLimit: Money(minorUnits: 100_000, currency: .aud), limits: [:], in: db
            )

            #expect(try OverallLimits().limit(on: try date("2026-09-01"), in: db) == nil)
            #expect(
                try OverallLimits().limit(on: today, in: db) == Money(minorUnits: 100_000, currency: .aud)
            )
        }
    }

    @Test("switching the budget cadence does not touch the pay schedule")
    func payScheduleIsLeftAlone() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try configured(db)
            let before = try BudgetSettingsStore().load(db).paySchedule

            let plan = try CadenceSwitch().plan(to: .monthly, asOf: try date("2026-09-02"), in: db)
            try CadenceSwitch().apply(plan, overallLimit: nil, limits: [:], in: db)

            // DEC-036: "a user switching from fortnightly to monthly budgeting has
            // not changed jobs."
            let settings = try BudgetSettingsStore().load(db)
            #expect(settings.paySchedule == before)
            #expect(settings.schedule?.cadence == .monthly)
            #expect(settings.schedule?.anchor == (try date("2026-09-02")))
        }
    }
}
