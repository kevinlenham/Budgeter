//
//  CadenceSwitchTests.swift
//  BudgeterTests
//
//  DEC-008's switch, which is really a test of DEC-007's governing principle:
//  *periods are immutable, append-only records, and cadence or anchor changes are
//  effective-dated forward and never regenerate history.*
//
//  The failure this guards against is the quiet one. A switch that took effect
//  immediately would truncate the period the user is in, and "spent this period"
//  would jump for reasons nothing on screen explains.
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

    @Test("the plan takes effect at the next boundary, not today")
    func planStartsAtTheNextBoundary() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try configured(db)
            let plan = try CadenceSwitch().plan(to: .monthly, asOf: try date("2026-09-02"), in: db)

            #expect(plan.from == .fortnightly)
            #expect(plan.to == .monthly)
            // The day after the period in progress ends. DEC-008: "waiting for the
            // boundary means partial periods never exist."
            #expect(plan.effectiveFrom == (try date("2026-09-11")))
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

    @Test("applying it leaves the period in progress exactly as it was")
    func currentPeriodIsUntouched() throws {
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
                plan, limits: [groceries: Money(minorUnits: 43500, currency: .aud)], in: db
            )

            let period = try #require(try Queries.period(containing: today, in: db))
            let after = try #require(
                try Queries.budgetLines(periodID: period.id, in: db)
                    .first { $0.categoryId == groceries.uuidString }
            )

            // Same period, same dates, same limit, same spending. Nothing the user
            // is looking at today moves.
            #expect(period.startsOn == "2026-08-28")
            #expect(period.endsOn == "2026-09-10")
            #expect(after == before)
        }
    }

    @Test("the next period generated is on the new cadence and starts where the plan said")
    func nextPeriodUsesTheNewCadence() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try configured(db)
            let plan = try CadenceSwitch().plan(to: .monthly, asOf: try date("2026-09-02"), in: db)
            try CadenceSwitch().apply(plan, limits: [:], in: db)

            // Nothing new until the boundary arrives.
            #expect(try PeriodGenerator().generate(through: try date("2026-09-10"), in: db).isEmpty)

            let generated = try PeriodGenerator().generate(through: try date("2026-09-11"), in: db)
            #expect(generated.count == 1)
            #expect(generated.first?.startsOn == (try date("2026-09-11")))
            // Monthly, so it ends the day before the 11th of next month.
            #expect(generated.first?.endsOn == (try date("2026-10-10")))
        }
    }

    @Test("resuming generation after a switch never produces an overlapping period")
    func generationAfterSwitchNeverOverlaps() throws {
        // Regression test. `firstMissingIndex` used to reinterpret the *old*
        // period's start date under the *new* schedule's anchor arithmetic —
        // sound only when the schedule never changes. Fortnightly (anchored
        // 2026-09-11) switched to weekly is a combination where that produced
        // index -1 instead of 0, generating 2026-09-04...2026-09-10, which
        // overlaps the already-stored 2026-08-28...2026-09-10 and trips
        // `trg_periods_no_overlap` — the exact failure a live switch hit.
        let database = try Fixture.database()
        try database.writer.write { db in
            try configured(db)
            let plan = try CadenceSwitch().plan(to: .weekly, asOf: try date("2026-09-02"), in: db)
            try CadenceSwitch().apply(plan, limits: [:], in: db)

            // Generating well past the new boundary must not throw.
            let generated = try PeriodGenerator().generate(through: try date("2026-09-15"), in: db)
            #expect(!generated.isEmpty)
            #expect(generated.allSatisfy { $0.startsOn >= plan.effectiveFrom })

            // Belt and braces: read every stored period back and check none overlap.
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
                plan, limits: [groceries: Money(minorUnits: 43500, currency: .aud)], in: db
            )

            let limits = CategoryLimits()
            // DEC-008's schema consequence: "a past period must display the limit
            // that applied *then*, not today's."
            #expect(
                try limits.limit(categoryID: groceries, on: try date("2026-09-02"), in: db)
                    == Money(minorUnits: 20000, currency: .aud)
            )
            #expect(
                try limits.limit(categoryID: groceries, on: try date("2026-09-11"), in: db)
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
            try CadenceSwitch().apply(plan, limits: [:], in: db)

            // DEC-036: "a user switching from fortnightly to monthly budgeting has
            // not changed jobs."
            #expect(try BudgetSettingsStore().load(db).paySchedule == before)
            #expect(try BudgetSettingsStore().load(db).schedule?.cadence == .monthly)
        }
    }
}
