//
//  PeriodGeneratorTests.swift
//  BudgeterTests
//
//  DEC-009's two required properties, against a real database: generation fills any
//  gap in one call, and running it again changes nothing. Plus DEC-008's snapshot,
//  which is the reason a past period keeps showing the limit that applied then.
//

import Foundation
import GRDB
import Testing
@testable import Budgeter

@Suite("Period generation")
struct PeriodGeneratorTests {
    private func date(_ iso: String) throws -> CivilDate {
        try #require(CivilDate(iso: iso))
    }

    private func configure(
        _ db: Database,
        anchor: String,
        cadence: Cadence = .fortnightly
    ) throws {
        var settings = try BudgetSettingsStore().load(db)
        settings.schedule = PeriodSchedule(anchor: try date(anchor), cadence: cadence)
        try BudgetSettingsStore().save(settings, in: db)
    }

    private func storedStarts(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT starts_on FROM periods ORDER BY starts_on")
    }

    @Test("generation refuses to invent an anchor before onboarding has supplied one")
    func refusesWithoutConfiguration() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            #expect(throws: BudgetSettingsError.notConfigured) {
                try PeriodGenerator().generate(through: try date("2026-03-05"), in: db)
            }
            let starts = try storedStarts(db)
            #expect(starts.isEmpty)
        }
    }

    @Test("the first run creates the period the user is in today, not the anchor's own")
    func firstRunCoversToday() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            // DEC-007 asks for the *next* payday, so the anchor is in the future.
            try configure(db, anchor: "2026-03-13")
            let created = try PeriodGenerator().generate(through: try date("2026-03-05"), in: db)

            #expect(created.count == 1)
            #expect(created.first?.startsOn.iso == "2026-02-27")
            #expect(created.first?.endsOn.iso == "2026-03-12")
            #expect(created.first?.contains(try date("2026-03-05")) == true)
        }
    }

    @Test("the first run generates no history before today, however old the anchor is")
    func firstRunDoesNotBackfill() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            // A deliberate choice, not an oversight: the app has no transactions
            // older than its first launch, so periods before it would be empty rows
            // whose only effect is to make "your last six budgets" a wall of zeroes.
            // Sprint 6's CSV import is the first thing that will want them, and it
            // can ask for them explicitly then.
            try configure(db, anchor: "2026-01-02", cadence: .weekly)
            let created = try PeriodGenerator().generate(through: try date("2026-03-01"), in: db)

            #expect(created.count == 1)
            #expect(created.first?.startsOn.iso == "2026-02-27")
        }
    }

    @Test("an app unopened for two months fills the whole gap in one call — DEC-009")
    func fillsATwoMonthGap() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try configure(db, anchor: "2026-01-02", cadence: .weekly)

            try PeriodGenerator().generate(through: try date("2026-01-02"), in: db)
            let caughtUp = try PeriodGenerator().generate(through: try date("2026-03-01"), in: db)

            #expect(caughtUp.count == 8)
            #expect(try storedStarts(db).count == 9)
            #expect(try storedStarts(db).last == "2026-02-27")
        }
    }

    @Test("running generation twice changes nothing — the property DEC-009 requires")
    func idempotent() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try configure(db, anchor: "2026-01-02", cadence: .weekly)
            let today = try date("2026-03-01")

            try PeriodGenerator().generate(through: today, in: db)
            let first = try storedStarts(db)
            let seqAfterFirst = try Int64.fetchOne(db, sql: "SELECT next_seq FROM change_counter")

            let second = try PeriodGenerator().generate(through: today, in: db)

            #expect(second.isEmpty, "the second run created periods")
            #expect(try storedStarts(db) == first)
            #expect(
                try Int64.fetchOne(db, sql: "SELECT next_seq FROM change_counter") == seqAfterFirst,
                "a no-op run must not burn change sequence numbers"
            )
        }
    }

    @Test("stored periods never overlap, and the database refuses one that would")
    func overlapIsRejected() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try configure(db, anchor: "2026-01-02", cadence: .weekly)
            try PeriodGenerator().generate(through: try date("2026-01-05"), in: db)

            // Overlaps the period covering 5 January, which generation just created.
            #expect(throws: DatabaseError.self) {
                try db.execute(
                    sql: """
                    INSERT INTO periods (id, starts_on, ends_on, cadence, anchor_on,
                                         created_at, updated_at, change_seq)
                    VALUES (?, '2026-01-05', '2026-01-11', 'weekly', '2026-01-02',
                            '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', 0)
                    """,
                    arguments: [UUIDv7.generate().uuidString]
                )
            }
        }
    }

    @Test("each period records the cadence and anchor that produced it — DEC-007")
    func periodsRecordTheirOwnSchedule() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try configure(db, anchor: "2026-01-02", cadence: .weekly)
            try PeriodGenerator().generate(through: try date("2026-01-20"), in: db)

            let stored = try PeriodRecord.fetchAll(db, sql: "SELECT * FROM periods ORDER BY starts_on")
            #expect(stored.allSatisfy { $0.cadence == "weekly" && $0.anchorOn == "2026-01-02" })
        }
    }

    @Test("a period snapshots the limits in force at its start — DEC-008")
    func snapshotsLimits() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let groceries = try Fixture.insertCategory(db, name: "Groceries")
            try configure(db, anchor: "2026-01-01", cadence: .monthly)
            try CategoryLimits().setLimit(
                categoryID: groceries,
                amount: Money(minorUnits: 50000, currency: .aud),
                effectiveFrom: try date("2026-01-01"),
                in: db
            )

            try PeriodGenerator().generate(through: try date("2026-01-15"), in: db)

            let snapshot = try PeriodLimitRecord.fetchAll(db, sql: "SELECT * FROM period_limits")
            #expect(snapshot.count == 1)
            #expect(snapshot.first?.amountMinor == 50000)
            #expect(snapshot.first?.categoryId == groceries.uuidString)
        }
    }

    @Test("a limit set after a period was generated does not reach back into it — DEC-008")
    func laterLimitsDoNotRewriteHistory() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let groceries = try Fixture.insertCategory(db, name: "Groceries")
            try configure(db, anchor: "2026-01-01", cadence: .monthly)
            try CategoryLimits().setLimit(
                categoryID: groceries,
                amount: Money(minorUnits: 50000, currency: .aud),
                effectiveFrom: try date("2026-01-01"),
                in: db
            )
            try PeriodGenerator().generate(through: try date("2026-01-15"), in: db)

            // The user raises their grocery budget from February.
            try CategoryLimits().setLimit(
                categoryID: groceries,
                amount: Money(minorUnits: 60000, currency: .aud),
                effectiveFrom: try date("2026-02-01"),
                in: db
            )
            try PeriodGenerator().generate(through: try date("2026-02-15"), in: db)

            let snapshots = try PeriodLimitRecord.fetchAll(db, sql: """
            SELECT pl.* FROM period_limits pl
            JOIN periods p ON p.id = pl.period_id
            ORDER BY p.starts_on
            """)
            #expect(snapshots.map(\.amountMinor) == [50000, 60000], "January must still read $500")
        }
    }

    @Test("a period generated before any limit exists simply has no snapshot")
    func noLimitsMeansNoSnapshot() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try Fixture.insertCategory(db, name: "Groceries")
            try configure(db, anchor: "2026-01-01", cadence: .monthly)
            try PeriodGenerator().generate(through: try date("2026-01-15"), in: db)

            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM period_limits") == 0)
        }
    }

    @Test("a retired period stops holding its start date, so a replacement can take it")
    func tombstonedPeriodsDoNotReserveTheirStartDate() throws {
        // `idx_periods_starts_on` was unconditional until migration 6, while
        // `trg_periods_no_overlap` had always ignored tombstones. The disagreement
        // only surfaced once DEC-043 gave `CadenceSwitch` a reason to retire a
        // period: a same-day replacement was then refused by the index.
        let database = try Fixture.database()
        try database.writer.write { db in
            try configure(db, anchor: "2026-01-05", cadence: .weekly)
            try PeriodGenerator().generate(through: try date("2026-01-05"), in: db)

            let retiring = try #require(try Queries.period(containing: try date("2026-01-05"), in: db))
            try db.execute(
                sql: "UPDATE periods SET deleted_at = '2026-01-05T00:00:00.000Z' WHERE id = ?",
                arguments: [retiring.id]
            )

            // Same start date, different cadence — exactly what a switch produces.
            try db.execute(
                sql: """
                INSERT INTO periods (id, starts_on, ends_on, cadence, anchor_on,
                                     created_at, updated_at, change_seq)
                VALUES (?, '2026-01-05', '2026-02-04', 'monthly', '2026-01-05',
                        '2026-01-05T00:00:00.000Z', '2026-01-05T00:00:00.000Z', 0)
                """,
                arguments: [UUIDv7.generate().uuidString]
            )

            let current = try #require(try Queries.period(containing: try date("2026-01-05"), in: db))
            #expect(current.cadence == "monthly")
        }
    }

    @Test("two live periods still cannot share a start date")
    func livePeriodsStillCannotShareAStartDate() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try configure(db, anchor: "2026-01-05", cadence: .weekly)
            try PeriodGenerator().generate(through: try date("2026-01-05"), in: db)

            // Narrowing the index to live rows must not have narrowed it away: a
            // second *live* period on 5 January is still refused.
            #expect(throws: DatabaseError.self) {
                try db.execute(
                    sql: """
                    INSERT INTO periods (id, starts_on, ends_on, cadence, anchor_on,
                                         created_at, updated_at, change_seq)
                    VALUES (?, '2026-01-05', '2026-01-11', 'weekly', '2026-01-05',
                            '2026-01-05T00:00:00.000Z', '2026-01-05T00:00:00.000Z', 0)
                    """,
                    arguments: [UUIDv7.generate().uuidString]
                )
            }
        }
    }
}
