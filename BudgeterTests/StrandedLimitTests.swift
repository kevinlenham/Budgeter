//
//  StrandedLimitTests.swift
//  BudgeterTests
//
//  The bug: a cadence switch reported
//  `notAfterCurrentLimit(effectiveFrom: <today>, currentFrom: <a date in the
//  future>)` and rolled back, so the Switch button changed nothing at all.
//
//  Where the future-dated rows came from: DEC-043's first implementation deferred a
//  switch to the next calendar boundary and wrote its new limits effective from that
//  date. The DEC-043 revision made switches instant and deleted the machinery that
//  promoted them — but a database written by the earlier build still holds those
//  rows, dated ahead of today. `CategoryLimits.close` then refused every subsequent
//  switch as backdating, because it could not tell a row that had already governed a
//  period from one that had never governed anything.
//
//  These tests set up that stranded state directly rather than reconstructing the
//  old build: the rule under test is "a limit that has not started yet does not
//  outrank one being set now", which stands on its own regardless of how a row ended
//  up in the future.
//

import Foundation
import GRDB
import Testing
@testable import Budgeter

@Suite("Limits stranded in the future")
struct StrandedLimitTests {
    /// Every test here onboards at `Fixture.onboard`'s default "today", and the rule
    /// under test is about dates that have not arrived yet — so the clock has to be
    /// the fixture's, not the machine's, or these pass until 2026-09-07 and then
    /// quietly stop testing anything.
    private static let today = CivilDate(year: 2026, month: 9, clampedDay: 2)
    private let clock: @Sendable () -> Date = { StrandedLimitTests.today.middayDate() }

    private func date(_ iso: String) throws -> CivilDate {
        try #require(CivilDate(iso: iso))
    }

    private func money(_ minor: Int64) -> Money {
        Money(minorUnits: minor, currency: .aud)
    }

    // MARK: - Category limits

    @Test("setting a limit before one that has not started yet supersedes it")
    func categoryLimitBeforeAFutureRow() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try Fixture.onboard(db)
            let groceries = try Fixture.category("Groceries", in: db)
            let limits = CategoryLimits(now: clock)

            // What the deferred-switch build left behind: a limit effective from a
            // boundary still in the future.
            try limits.setLimit(
                categoryID: groceries, amount: money(30000),
                effectiveFrom: try date("2026-09-07"), in: db
            )

            // Today's switch writes from today, which is earlier. This used to throw.
            try limits.setLimit(
                categoryID: groceries, amount: money(25000),
                effectiveFrom: try date("2026-09-02"), in: db
            )

            #expect(try limits.limit(categoryID: groceries, on: try date("2026-09-02"), in: db)
                == money(25000))
            // And the stranded figure does not reappear when its date arrives.
            #expect(try limits.limit(categoryID: groceries, on: try date("2026-09-07"), in: db)
                == money(25000))
        }
    }

    @Test("the row the stranded one closed is reopened, not left with a hole in its range")
    func reopensTheRowTheStrandedOneClosed() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try Fixture.onboard(db)
            let groceries = try Fixture.category("Groceries", in: db)
            let limits = CategoryLimits(now: clock)

            try limits.setLimit(
                categoryID: groceries, amount: money(20000),
                effectiveFrom: try date("2026-08-28"), in: db
            )
            // Closes the August row at 2026-09-07 and opens its own range there.
            try limits.setLimit(
                categoryID: groceries, amount: money(30000),
                effectiveFrom: try date("2026-09-07"), in: db
            )
            // Retiring the September row must hand its range back, or 2026-09-03
            // onwards belongs to nothing.
            try limits.setLimit(
                categoryID: groceries, amount: money(25000),
                effectiveFrom: try date("2026-09-02"), in: db
            )

            #expect(try limits.limit(categoryID: groceries, on: try date("2026-08-28"), in: db)
                == money(20000))
            #expect(try limits.limit(categoryID: groceries, on: try date("2026-09-01"), in: db)
                == money(20000))
            #expect(try limits.limit(categoryID: groceries, on: try date("2026-09-02"), in: db)
                == money(25000))
            #expect(try limits.limit(categoryID: groceries, on: try date("2026-09-30"), in: db)
                == money(25000))

            // Exactly one open row survives, which is also what
            // `idx_category_limits_open` enforces — asserted here so a future
            // rewrite that drops the index still fails this test.
            let open = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM category_limits
             WHERE category_id = ? AND effective_to IS NULL AND deleted_at IS NULL
            """, arguments: [groceries.uuidString])
            #expect(open == 1)
        }
    }

    @Test("several stranded rows are all retired, not just the newest")
    func retiresEveryStrandedRow() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try Fixture.onboard(db)
            let groceries = try Fixture.category("Groceries", in: db)
            let limits = CategoryLimits(now: clock)

            try limits.setLimit(
                categoryID: groceries, amount: money(20000),
                effectiveFrom: try date("2026-08-28"), in: db
            )
            try limits.setLimit(
                categoryID: groceries, amount: money(30000),
                effectiveFrom: try date("2026-09-07"), in: db
            )
            try limits.setLimit(
                categoryID: groceries, amount: money(40000),
                effectiveFrom: try date("2026-09-14"), in: db
            )

            try limits.setLimit(
                categoryID: groceries, amount: money(25000),
                effectiveFrom: try date("2026-09-02"), in: db
            )

            for day in ["2026-09-02", "2026-09-07", "2026-09-14", "2026-10-01"] {
                #expect(
                    try limits.limit(categoryID: groceries, on: try date(day), in: db) == money(25000),
                    "\(day) still sees a stranded figure"
                )
            }
        }
    }

    @Test("a limit that has genuinely already applied is still not backdated over")
    func realBackdatingIsStillRefused() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try Fixture.onboard(db)
            let groceries = try Fixture.category("Groceries", in: db)
            let limits = CategoryLimits(now: clock)

            try limits.setLimit(
                categoryID: groceries, amount: money(20000),
                effectiveFrom: try date("2026-09-02"), in: db
            )

            #expect(throws: CategoryLimitError.notAfterCurrentLimit(
                effectiveFrom: "2026-08-01", currentFrom: "2026-09-02"
            )) {
                try limits.setLimit(
                    categoryID: groceries, amount: money(25000),
                    effectiveFrom: try date("2026-08-01"), in: db
                )
            }
        }
    }

    // MARK: - Overall limit

    @Test("the overall limit supersedes a stranded row the same way")
    func overallLimitBeforeAFutureRow() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try Fixture.onboard(db)
            let limits = OverallLimits(now: clock)

            try limits.setLimit(amount: money(200_000), effectiveFrom: try date("2026-08-28"), in: db)
            try limits.setLimit(amount: money(400_000), effectiveFrom: try date("2026-09-07"), in: db)
            try limits.setLimit(amount: money(300_000), effectiveFrom: try date("2026-09-02"), in: db)

            #expect(try limits.limit(on: try date("2026-09-01"), in: db) == money(200_000))
            #expect(try limits.limit(on: try date("2026-09-02"), in: db) == money(300_000))
            #expect(try limits.limit(on: try date("2026-09-07"), in: db) == money(300_000))

            let open = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM overall_limits
             WHERE effective_to IS NULL AND deleted_at IS NULL
            """)
            #expect(open == 1)
        }
    }

    // MARK: - The switch itself

    @Test("a cadence switch commits over stranded limits instead of rolling back")
    func switchingOverStrandedLimits() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try Fixture.onboard(db)
            let groceries = try Fixture.category("Groceries", in: db)
            let today = try date("2026-09-02")

            try CategoryLimits(now: clock).setLimit(
                categoryID: groceries, amount: money(20000),
                effectiveFrom: try date("2026-08-28"), in: db
            )
            try OverallLimits(now: clock).setLimit(
                amount: money(200_000), effectiveFrom: try date("2026-08-28"), in: db
            )
            // The deferred-switch build's leftovers, dated at a boundary that never
            // arrived.
            try CategoryLimits(now: clock).setLimit(
                categoryID: groceries, amount: money(10000),
                effectiveFrom: try date("2026-09-07"), in: db
            )
            try OverallLimits(now: clock).setLimit(
                amount: money(100_000), effectiveFrom: try date("2026-09-07"), in: db
            )

            let plan = try CadenceSwitch().plan(to: .monthly, asOf: today, in: db)
            try CadenceSwitch(now: clock).apply(
                plan,
                overallLimit: money(500_000),
                limits: [groceries: money(50000)],
                in: db
            )
            try PeriodGenerator().generate(through: today, in: db)

            // The switch actually happened — the symptom was that it silently did not.
            let settings = try BudgetSettingsStore().load(db)
            #expect(settings.schedule?.cadence == .monthly)
            #expect(settings.schedule?.anchor == today)

            let period = try #require(try Queries.period(containing: today, in: db))
            #expect(period.cadence == "monthly")
            #expect(period.startsOn == today.iso)

            #expect(try OverallLimits().limit(on: today, in: db) == money(500_000))
            #expect(try CategoryLimits().limit(categoryID: groceries, on: today, in: db)
                == money(50000))
        }
    }
}
