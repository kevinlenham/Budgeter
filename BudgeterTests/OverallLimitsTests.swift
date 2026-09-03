//
//  OverallLimitsTests.swift
//  BudgeterTests
//
//  DEC-043's whole-period budget: the same effective-dated-range rules as
//  `CategoryLimits`, exercised here without a category in sight.
//

import Foundation
import GRDB
import Testing
@testable import Budgeter

@Suite("Overall limits")
struct OverallLimitsTests {
    private func date(_ iso: String) throws -> CivilDate {
        try #require(CivilDate(iso: iso))
    }

    @Test("nothing set means no limit, not zero")
    func noLimitIsNil() throws {
        let database = try Fixture.database()
        try database.writer.read { db in
            #expect(try OverallLimits().limit(on: try date("2026-09-01"), in: db) == nil)
        }
    }

    @Test("a limit applies from the date it was set effective, and not before")
    func limitAppliesForward() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try OverallLimits().setLimit(
                amount: Money(minorUnits: 100_000, currency: .aud),
                effectiveFrom: try date("2026-09-01"),
                in: db
            )
            #expect(try OverallLimits().limit(on: try date("2026-08-31"), in: db) == nil)
            #expect(
                try OverallLimits().limit(on: try date("2026-09-01"), in: db)
                    == Money(minorUnits: 100_000, currency: .aud)
            )
        }
    }

    @Test("setting it again from the same date amends it, rather than opening a second row")
    func sameDateAmends() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try OverallLimits().setLimit(
                amount: Money(minorUnits: 100_000, currency: .aud),
                effectiveFrom: try date("2026-09-01"),
                in: db
            )
            try OverallLimits().setLimit(
                amount: Money(minorUnits: 120_000, currency: .aud),
                effectiveFrom: try date("2026-09-01"),
                in: db
            )
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM overall_limits")
            #expect(count == 1)
            #expect(
                try OverallLimits().limit(on: try date("2026-09-01"), in: db)
                    == Money(minorUnits: 120_000, currency: .aud)
            )
        }
    }

    @Test("a later effective date closes the old row and opens a new one, and history survives")
    func laterDateClosesAndOpens() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try OverallLimits().setLimit(
                amount: Money(minorUnits: 100_000, currency: .aud),
                effectiveFrom: try date("2026-09-01"),
                in: db
            )
            try OverallLimits().setLimit(
                amount: Money(minorUnits: 150_000, currency: .aud),
                effectiveFrom: try date("2026-10-01"),
                in: db
            )
            #expect(
                try OverallLimits().limit(on: try date("2026-09-15"), in: db)
                    == Money(minorUnits: 100_000, currency: .aud)
            )
            #expect(
                try OverallLimits().limit(on: try date("2026-10-01"), in: db)
                    == Money(minorUnits: 150_000, currency: .aud)
            )
        }
    }

    @Test("a backdated limit is refused, the same as CategoryLimits refuses one")
    func backdatingIsRefused() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try OverallLimits().setLimit(
                amount: Money(minorUnits: 100_000, currency: .aud),
                effectiveFrom: try date("2026-09-01"),
                in: db
            )
            #expect(throws: CategoryLimitError.self) {
                try OverallLimits().setLimit(
                    amount: Money(minorUnits: 50000, currency: .aud),
                    effectiveFrom: try date("2026-08-15"),
                    in: db
                )
            }
        }
    }

    @Test("at most one open row — the constant-expression index does its job")
    func atMostOneOpenRow() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try OverallLimits().setLimit(
                amount: Money(minorUnits: 100_000, currency: .aud),
                effectiveFrom: try date("2026-09-01"),
                in: db
            )
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: """
                INSERT INTO overall_limits (
                    id, amount_minor, currency, effective_from, effective_to,
                    created_at, updated_at, deleted_at, change_seq
                ) VALUES (
                    'x', 1000, 'AUD', '2026-09-02', NULL,
                    '2026-09-02T00:00:00.000Z', '2026-09-02T00:00:00.000Z', NULL, 999
                )
                """)
            }
        }
    }

    @Test("a period snapshots the overall limit at its start, same as it does for categories")
    func periodSnapshotsTheOverallLimit() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try Fixture.onboard(db)
            try OverallLimits().setLimit(
                amount: Money(minorUnits: 200_000, currency: .aud),
                effectiveFrom: try date("2026-08-28"),
                in: db
            )
            let period = try #require(try Queries.period(containing: try date("2026-09-02"), in: db))
            try PeriodGenerator().resnapshot(period: period, in: db)

            let status = try Queries.overallStatus(periodID: period.id, in: db)
            #expect(status?.limitMinor == 200_000)
            #expect(status?.spentMinor == 0)
        }
    }

    @Test("a period generated before any overall limit exists simply has no snapshot")
    func noLimitMeansNoSnapshot() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try Fixture.onboard(db)
            let period = try #require(try Queries.period(containing: try date("2026-09-02"), in: db))
            #expect(try Queries.overallStatus(periodID: period.id, in: db) == nil)
        }
    }
}
