//
//  CadenceSwitchJourneyTests.swift
//  BudgeterTests
//
//  `CadenceSwitchTests` covers the switch itself. This covers the *journey* — the
//  sequence the app actually performs, which is what shipped broken:
//
//      onboard (calendar-anchored) → set budgets → plan → apply → generate
//
//  The bug those steps hid was that `CadenceSwitch.apply` and `PeriodGenerator` are
//  called from two different places (a view's Task, then `AppModel.start()`), so a
//  switch could commit happily and only then leave generation unable to run. The
//  DEC-043 retire branch — a switch on the *first day* of the period in progress —
//  soft-deleted the period, and `idx_periods_starts_on` was unconditional, so the
//  replacement period could not take the start date the tombstone still held.
//
//  `AppModel.start()` reports that as `.failed`, which replaces the entire app with
//  "Budgeter could not start" — permanently, since the tombstone and the failing
//  insert both survive a relaunch. Hence a journey test rather than a unit one: no
//  single step was wrong on its own.
//

import Foundation
import GRDB
import Testing
@testable import Budgeter

@Suite("Switching cadence, end to end")
struct CadenceSwitchJourneyTests {
    /// Onboarding as `OnboardingView` and `AppModel.completeOnboarding` perform it:
    /// the anchor is computed by `CalendarCadence`, so it is today or earlier —
    /// unlike `Fixture.onboard`, which still uses DEC-007's future payday and so
    /// never produces a period that starts today.
    private func onboard(_ db: Database, cadence: Cadence, today: CivilDate) throws {
        _ = try AccountStore().create(name: "Everyday", currency: .aud, in: db)
        for name in CategoryStore.starters {
            try CategoryStore().create(name: name, in: db)
        }
        var settings = try BudgetSettingsStore().load(db)
        settings.schedule = PeriodSchedule(
            anchor: CalendarCadence.anchor(for: cadence, today: today, isSecondWeek: false),
            cadence: cadence
        )
        try BudgetSettingsStore().save(settings, in: db)
        try PeriodGenerator().generate(through: today, in: db)
    }

    /// The Budget tab's two editors, which write from the current period's start.
    private func setBudgets(asOf today: CivilDate, in db: Database) throws {
        let record = try #require(try Queries.period(containing: today, in: db))
        let startsOn = try #require(CivilDate(iso: record.startsOn))
        try OverallLimits().setLimit(
            amount: Money(minorUnits: 200_000, currency: .aud), effectiveFrom: startsOn, in: db
        )
        try CategoryLimits().setLimit(
            categoryID: try Fixture.category("Groceries", in: db),
            amount: Money(minorUnits: 20000, currency: .aud),
            effectiveFrom: startsOn,
            in: db
        )
        try PeriodGenerator().resnapshot(period: record, in: db)
    }

    /// Settings → Budget period → pick → Switch, then `AppModel.start()`'s generate,
    /// then the launches that follow over the next six weeks.
    ///
    /// The figures stand in for what the user types on the confirmation sheet, which
    /// since DEC-044 is the only place they can come from — the sheet opens every
    /// budgeted line at zero and the app suggests nothing.
    private func switchCadence(to cadence: Cadence, asOf today: CivilDate, in db: Database) throws {
        let plan = try CadenceSwitch().plan(to: cadence, asOf: today, in: db)
        let limits = plan.lines.reduce(into: [UUID: Money]()) { result, line in
            guard line.currentLimit != nil else { return }
            result[line.categoryID] = Money(minorUnits: 30000, currency: .aud)
        }
        try CadenceSwitch().apply(
            plan, overallLimit: Money(minorUnits: 300_000, currency: .aud), limits: limits, in: db
        )

        try PeriodGenerator().generate(through: today, in: db)
        for ahead in 1 ... 42 {
            try PeriodGenerator().generate(through: today.addingDays(ahead), in: db)
        }
    }

    @Test("a switch on the first day of the period in progress still leaves a period for today")
    func switchingOnAPeriodBoundaryDay() throws {
        // 2026-09-07 is a Monday, so the weekly period in progress starts *today*
        // and DEC-043 retires it rather than truncating it. This is the exact case
        // that bricked the app: the tombstone held 2026-09-07, and the monthly
        // period replacing it starts on 2026-09-07 too.
        let database = try Fixture.database()
        try database.writer.write { db in
            let today = try #require(CivilDate(iso: "2026-09-07"))
            try onboard(db, cadence: .weekly, today: today)

            let retiring = try #require(try Queries.period(containing: today, in: db))
            #expect(retiring.startsOn == today.iso, "precondition: the period starts today")

            try switchCadence(to: .monthly, asOf: today, in: db)

            let current = try #require(try Queries.period(containing: today, in: db))
            #expect(current.startsOn == today.iso)
            #expect(current.cadence == "monthly")
            #expect(current.id != retiring.id)

            // The retired row is a tombstone, not a deletion: it keeps its dates and
            // simply stops counting.
            let retired = try #require(try PeriodRecord.fetchOne(
                db, sql: "SELECT * FROM periods WHERE id = ?", arguments: [retiring.id]
            ))
            #expect(retired.deletedAt != nil)
            #expect(retired.startsOn == today.iso, "a tombstone keeps its start date")
        }
    }

    @Test("every cadence pair, on every day of a month, with and without budgets set")
    func everyJourneySurvives() throws {
        // Exhaustive rather than sampled, because the failure was a one-day-in-seven
        // (weekly), one-in-fourteen (fortnightly) and one-in-thirty (monthly) case —
        // precisely the shape a hand-picked date misses.
        var failures: [String] = []

        for day in 1 ... 30 {
            let today = try #require(CivilDate(iso: String(format: "2026-09-%02d", day)))
            for from in Cadence.allCases {
                for to in Cadence.allCases where to != from {
                    for withBudgets in [false, true] {
                        do {
                            let database = try Fixture.database()
                            try database.writer.write { db in
                                try onboard(db, cadence: from, today: today)
                                if withBudgets {
                                    try setBudgets(asOf: today, in: db)
                                }
                                try switchCadence(to: to, asOf: today, in: db)
                                _ = try #require(try Queries.period(containing: today, in: db))
                            }
                        } catch {
                            failures.append("\(from)→\(to) on \(today.iso), budgets=\(withBudgets): \(error)")
                        }
                    }
                }
            }
        }

        #expect(failures.isEmpty, "\(failures.count) journeys failed, first: \(failures.first ?? "")")
    }

    @Test("periods still never overlap, and every day from the first to today is covered")
    func everyDayBelongsToExactlyOnePeriod() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let today = try #require(CivilDate(iso: "2026-09-01"))
            try onboard(db, cadence: .monthly, today: today)
            try switchCadence(to: .fortnightly, asOf: today, in: db)

            let rows = try Row.fetchAll(db, sql: """
            SELECT starts_on, ends_on FROM periods
             WHERE deleted_at IS NULL ORDER BY starts_on
            """)
            #expect(!rows.isEmpty)
            for (previous, next) in zip(rows, rows.dropFirst()) {
                let previousEnd = previous["ends_on"] as String
                let nextStart = next["starts_on"] as String
                #expect(nextStart > previousEnd, "\(previousEnd) and \(nextStart) overlap")
            }

            // No gaps either: a day owned by nothing is a day the Budget tab has
            // nothing to show for.
            let first = try #require(CivilDate(iso: rows[0]["starts_on"] as String))
            let last = try #require(CivilDate(iso: rows[rows.count - 1]["ends_on"] as String))
            for offset in 0 ... first.days(until: last) {
                let date = first.addingDays(offset)
                #expect(
                    try Queries.period(containing: date, in: db) != nil,
                    "no period contains \(date.iso)"
                )
            }
        }
    }
}
