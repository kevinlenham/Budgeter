//
//  CadenceSwitchTests.swift
//  BudgeterTests
//
//  DEC-008's switch, now under DEC-043's calendar-anchored periods.
//
//  The failure this guards against is the quiet one, twice over. A switch that
//  took effect immediately would truncate the period the user is in, and "spent
//  this period" would jump for reasons nothing on screen explains — DEC-008's
//  original concern. DEC-043 adds a second one: waiting for a genuine calendar
//  boundary (the next Monday, the next 1st) instead of "the day after the current
//  period ends" can leave a multi-day gap, and naively filling that gap under the
//  old cadence is exactly the overlap bug a live switch already hit once
//  (`PeriodGeneratorTests` / the commit that fixed it). These tests pin down the
//  fix that replaced it: the current period is extended to the boundary, and the
//  old schedule is never asked to generate anything once a switch is pending.
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
    /// runs 2026-08-28 (Friday) to 2026-09-10 (Thursday).
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

    @Test("the plan waits for the next real calendar boundary, not the day after the current period")
    func planWaitsForTheRealBoundary() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try configured(db)
            let plan = try CadenceSwitch().plan(to: .monthly, asOf: try date("2026-09-02"), in: db)

            #expect(plan.from == .fortnightly)
            #expect(plan.to == .monthly)
            // Not 2026-09-11 (the day after the current period ends) — 2026-09-11
            // is a Friday, and DEC-043 waits for the next real 1st-of-month, which
            // is 2026-10-01.
            #expect(plan.effectiveFrom == (try date("2026-10-01")))
        }
    }

    @Test("switching to weekly waits for the next Monday")
    func planForWeeklyWaitsForMonday() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try configured(db)
            let plan = try CadenceSwitch().plan(to: .weekly, asOf: try date("2026-09-02"), in: db)
            // 2026-09-11 is a Friday; the next Monday is 2026-09-14.
            #expect(plan.effectiveFrom == (try date("2026-09-14")))
        }
    }

    @Test("switching to fortnightly also waits for the next Monday — a switch always starts week one")
    func planForFortnightlyWaitsForMonday() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try configured(db)
            let plan = try CadenceSwitch().plan(to: .fortnightly, asOf: try date("2026-09-02"), in: db)
            #expect(plan.effectiveFrom == (try date("2026-09-14")))
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

    @Test("applying extends the current period to the boundary and leaves everything else about it alone")
    func currentPeriodIsExtendedNotTruncated() throws {
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
            let periodBefore = try #require(try Queries.period(containing: today, in: db))
            let before = try #require(
                try Queries.budgetLines(periodID: periodBefore.id, in: db)
                    .first { $0.categoryId == groceries.uuidString }
            )

            let plan = try CadenceSwitch().plan(to: .monthly, asOf: today, in: db)
            try CadenceSwitch().apply(
                plan, overallLimit: nil,
                limits: [groceries: Money(minorUnits: 43500, currency: .aud)], in: db
            )

            let period = try #require(try Queries.period(containing: today, in: db))
            let after = try #require(
                try Queries.budgetLines(periodID: period.id, in: db)
                    .first { $0.categoryId == groceries.uuidString }
            )

            // The start is untouched (DEC-008), and the end reaches exactly the
            // day before the new schedule's real boundary — not the old cadence's
            // own natural end, and not a short bridging period either.
            #expect(period.startsOn == "2026-08-28")
            #expect(period.endsOn == "2026-09-30")
            // Nothing already spent or budgeted moves because of the extension.
            #expect(after == before)
        }
    }

    @Test("nothing generates while the switch is still pending, however far into the gap you look")
    func nothingGeneratesDuringTheGap() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try configured(db)
            let plan = try CadenceSwitch().plan(to: .monthly, asOf: try date("2026-09-02"), in: db)
            try CadenceSwitch().apply(plan, overallLimit: nil, limits: [:], in: db)

            // Every day of the gap, right up to the boundary itself.
            for iso in ["2026-09-11", "2026-09-20", "2026-09-29", "2026-09-30"] {
                #expect(try PeriodGenerator().generate(through: try date(iso), in: db).isEmpty)
            }

            // Exactly one stored period the whole time: the extended one.
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM periods WHERE deleted_at IS NULL")
            #expect(count == 1)
        }
    }

    @Test("reaching the boundary promotes the pending schedule and generates cleanly")
    func reachingTheBoundaryPromotes() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try configured(db)
            let plan = try CadenceSwitch().plan(to: .monthly, asOf: try date("2026-09-02"), in: db)
            try CadenceSwitch().apply(plan, overallLimit: nil, limits: [:], in: db)

            let generated = try PeriodGenerator().generate(through: try date("2026-10-01"), in: db)
            #expect(generated.count == 1)
            #expect(generated.first?.startsOn == (try date("2026-10-01")))
            #expect(generated.first?.endsOn == (try date("2026-10-31")))

            let settings = try BudgetSettingsStore().load(db)
            #expect(settings.schedule?.cadence == .monthly)
            #expect(settings.schedule?.anchor == (try date("2026-10-01")))
            #expect(settings.pendingSchedule == nil)
        }
    }

    @Test("a backlog spanning the boundary fills in on the new schedule alone, with no overlap")
    func backlogAcrossTheBoundaryDoesNotOverlap() throws {
        // Regression test for the failure a live cadence switch hit: generating
        // well past a pending boundary in one call must never produce a period
        // that overlaps the (possibly extended) one already stored.
        let database = try Fixture.database()
        try database.writer.write { db in
            try configured(db)
            let plan = try CadenceSwitch().plan(to: .weekly, asOf: try date("2026-09-02"), in: db)
            try CadenceSwitch().apply(plan, overallLimit: nil, limits: [:], in: db)

            let generated = try PeriodGenerator().generate(through: try date("2026-10-05"), in: db)
            #expect(!generated.isEmpty)
            #expect(generated.allSatisfy { $0.startsOn >= plan.effectiveFrom })

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

    @Test("the new limits apply from the boundary and the old ones survive behind it")
    func limitsAreEffectiveDatedForward() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let (_, groceries) = try configured(db)
            let plan = try CadenceSwitch().plan(to: .monthly, asOf: try date("2026-09-02"), in: db)
            try CadenceSwitch().apply(
                plan, overallLimit: nil,
                limits: [groceries: Money(minorUnits: 43500, currency: .aud)], in: db
            )

            let limits = CategoryLimits()
            // DEC-008's schema consequence: "a past period must display the limit
            // that applied *then*, not today's."
            #expect(
                try limits.limit(categoryID: groceries, on: try date("2026-09-02"), in: db)
                    == Money(minorUnits: 20000, currency: .aud)
            )
            #expect(
                try limits.limit(categoryID: groceries, on: try date("2026-10-01"), in: db)
                    == Money(minorUnits: 43500, currency: .aud)
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
            // not changed jobs." The active schedule doesn't even change yet
            // either — only `pendingSchedule` does, until the boundary arrives.
            #expect(try BudgetSettingsStore().load(db).paySchedule == before)
            #expect(try BudgetSettingsStore().load(db).schedule?.cadence == .fortnightly)
            #expect(try BudgetSettingsStore().load(db).pendingSchedule?.cadence == .monthly)
        }
    }

    @Test("switching twice before the first takes effect replaces the pending switch, not stacks it")
    func secondSwitchReplacesThePending() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try configured(db)
            let today = try date("2026-09-02")

            let first = try CadenceSwitch().plan(to: .monthly, asOf: today, in: db)
            try CadenceSwitch().apply(first, overallLimit: nil, limits: [:], in: db)
            #expect(first.effectiveFrom == (try date("2026-10-01")))

            // The second plan is computed from wherever the current period now
            // ends — already extended by the first apply to 2026-09-30 — so its
            // own boundary floor is 2026-10-01, not the original 2026-09-11.
            // 2026-10-01 is a Thursday; the next Monday is 2026-10-05.
            let second = try CadenceSwitch().plan(to: .weekly, asOf: today, in: db)
            #expect(second.effectiveFrom == (try date("2026-10-05")))
            try CadenceSwitch().apply(second, overallLimit: nil, limits: [:], in: db)

            let settings = try BudgetSettingsStore().load(db)
            #expect(settings.pendingSchedule?.cadence == .weekly)
            #expect(settings.pendingSchedule?.anchor == (try date("2026-10-05")))

            // The current period's end tracks the *latest* plan, not the first.
            let period = try #require(try Queries.period(containing: today, in: db))
            #expect(period.endsOn == "2026-10-04")

            // Reaching the (now later) boundary promotes to weekly, not monthly.
            try PeriodGenerator().generate(through: try date("2026-10-05"), in: db)
            #expect(try BudgetSettingsStore().load(db).schedule?.cadence == .weekly)
        }
    }
}
