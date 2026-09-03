//
//  BudgetStatusTests.swift
//  BudgeterTests
//
//  The limits write path (DEC-008), the period_category_status view, safe-to-spend
//  (DEC-009), and the one case the roadmap singles out: an 11pm 31 March transaction
//  staying in March across the AEDT→AEST transition.
//

import Foundation
import GRDB
import Testing
@testable import Budgeter

@Suite("Effective-dated limits — DEC-008")
struct CategoryLimitTests {
    private func date(_ iso: String) throws -> CivilDate {
        try #require(CivilDate(iso: iso))
    }

    @Test("setting a limit again closes the old range rather than overwriting the amount")
    func settingALimitClosesTheOldRange() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let category = try Fixture.insertCategory(db)
            let limits = CategoryLimits()

            try limits.setLimit(
                categoryID: category,
                amount: Money(minorUnits: 50000, currency: .aud),
                effectiveFrom: try date("2026-01-01"),
                in: db
            )
            try limits.setLimit(
                categoryID: category,
                amount: Money(minorUnits: 60000, currency: .aud),
                effectiveFrom: try date("2026-02-01"),
                in: db
            )

            let rows = try CategoryLimitRecord.fetchAll(
                db, sql: "SELECT * FROM category_limits ORDER BY effective_from"
            )
            #expect(rows.count == 2, "the old limit must survive, not be overwritten")
            #expect(rows[0].effectiveTo == "2026-02-01", "closed on the day the next one opens")
            #expect(rows[1].effectiveTo == nil, "the new one is still in force")
        }
    }

    @Test("the limit in force is the one whose range covers the date")
    func limitInForce() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let category = try Fixture.insertCategory(db)
            let limits = CategoryLimits()
            try limits.setLimit(
                categoryID: category,
                amount: Money(minorUnits: 50000, currency: .aud),
                effectiveFrom: try date("2026-01-01"),
                in: db
            )
            try limits.setLimit(
                categoryID: category,
                amount: Money(minorUnits: 60000, currency: .aud),
                effectiveFrom: try date("2026-02-01"),
                in: db
            )

            #expect(try limits.limit(categoryID: category, on: try date("2025-12-31"), in: db) == nil)
            #expect(try limits.limit(categoryID: category, on: try date("2026-01-01"), in: db)?.minorUnits == 50000)
            #expect(try limits.limit(categoryID: category, on: try date("2026-01-31"), in: db)?.minorUnits == 50000)
            // The boundary day itself belongs to the new range: [from, to) is half-open.
            #expect(try limits.limit(categoryID: category, on: try date("2026-02-01"), in: db)?.minorUnits == 60000)
            #expect(try limits.limit(categoryID: category, on: try date("2030-01-01"), in: db)?.minorUnits == 60000)
        }
    }

    @Test("a backdated limit is refused rather than silently reordering history")
    func backdatingIsRefused() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let category = try Fixture.insertCategory(db)
            let limits = CategoryLimits()
            try limits.setLimit(
                categoryID: category,
                amount: Money(minorUnits: 50000, currency: .aud),
                effectiveFrom: try date("2026-02-01"),
                in: db
            )

            #expect(throws: CategoryLimitError.self) {
                try limits.setLimit(
                    categoryID: category,
                    amount: Money(minorUnits: 60000, currency: .aud),
                    effectiveFrom: try date("2026-01-01"),
                    in: db
                )
            }
        }
    }

    @Test("a category cannot have two limits still in force — the one overlap ranges cannot recover from")
    func onlyOneOpenRangePerCategory() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let category = try Fixture.insertCategory(db)
            try CategoryLimits().setLimit(
                categoryID: category,
                amount: Money(minorUnits: 50000, currency: .aud),
                effectiveFrom: try date("2026-01-01"),
                in: db
            )

            #expect(throws: DatabaseError.self) {
                try db.execute(
                    sql: """
                    INSERT INTO category_limits (id, category_id, amount_minor, currency,
                                                 effective_from, effective_to,
                                                 created_at, updated_at, change_seq)
                    VALUES (?, ?, 9900, 'AUD', '2026-03-01', NULL,
                            '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', 0)
                    """,
                    arguments: [UUIDv7.generate().uuidString, category.uuidString]
                )
            }
        }
    }

    @Test("a range cannot end before it starts")
    func rangesRunForwards() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let category = try Fixture.insertCategory(db)
            #expect(throws: DatabaseError.self) {
                try db.execute(
                    sql: """
                    INSERT INTO category_limits (id, category_id, amount_minor, currency,
                                                 effective_from, effective_to,
                                                 created_at, updated_at, change_seq)
                    VALUES (?, ?, 9900, 'AUD', '2026-03-01', '2026-02-01',
                            '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', 0)
                    """,
                    arguments: [UUIDv7.generate().uuidString, category.uuidString]
                )
            }
        }
    }
}

@Suite("The period_category_status view")
struct PeriodStatusViewTests {
    private func date(_ iso: String) throws -> CivilDate {
        try #require(CivilDate(iso: iso))
    }

    /// A monthly budget anchored on 1 March 2026, with a $500 grocery limit.
    private func setUp(_ db: Database) throws -> (account: UUID, category: UUID) {
        let account = try Fixture.insertAccount(db)
        let category = try Fixture.insertCategory(db, name: "Groceries")
        var settings = try BudgetSettingsStore().load(db)
        settings.schedule = PeriodSchedule(anchor: try date("2026-03-01"), cadence: .monthly)
        try BudgetSettingsStore().save(settings, in: db)
        try CategoryLimits().setLimit(
            categoryID: category,
            amount: Money(minorUnits: 50000, currency: .aud),
            effectiveFrom: try date("2026-03-01"),
            in: db
        )
        try PeriodGenerator().generate(through: try date("2026-03-15"), in: db)
        return (account, category)
    }

    private func status(_ db: Database) throws -> PeriodCategoryStatusRow? {
        try PeriodCategoryStatusRow.fetchOne(db, sql: "SELECT * FROM period_category_status")
    }

    @Test("spending inside the period counts against the limit")
    func spendingCountsAgainstTheLimit() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let (account, category) = try setUp(db)
            try Fixture.insertTransaction(
                db, kind: "expense", amountMinor: 34000,
                accountID: account, categoryID: category, bookedOn: "2026-03-10"
            )

            let status = try #require(try status(db))
            #expect(status.limitMinor == 50000)
            #expect(status.spentMinor == 34000)
            #expect(status.remainingMinor == 16000, "$340 of $500")
        }
    }

    @Test("spending in the next period does not count against this one")
    func spendingOutsideThePeriodIsExcluded() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let (account, category) = try setUp(db)
            try Fixture.insertTransaction(
                db, kind: "expense", amountMinor: 34000,
                accountID: account, categoryID: category, bookedOn: "2026-04-01"
            )

            #expect(try status(db)?.spentMinor == 0)
        }
    }

    /// A raw insert that lets `booked_on` and `occurred_at` disagree about the day,
    /// which the fixtures deliberately do not allow.
    private struct Purchase {
        var amount: Int64
        var bookedOn: String
        var occurredAt: String
    }

    private func insert(
        _ db: Database, account: UUID, category: UUID, purchase: Purchase
    ) throws {
        let (amount, bookedOn, occurredAt) = (purchase.amount, purchase.bookedOn, purchase.occurredAt)
        try db.execute(
            sql: """
            INSERT INTO transactions (
                id, kind, status, amount_minor, currency, account_id, category_id,
                merchant, booked_on, occurred_at, source, dedupe_key,
                created_at, updated_at, change_seq
            ) VALUES (?, 'expense', 'confirmed', ?, 'AUD', ?, ?,
                      'Corner shop', ?, ?, 'manual', ?, ?, ?, ?)
            """,
            arguments: [
                UUIDv7.generate().uuidString, amount, account.uuidString, category.uuidString,
                bookedOn, occurredAt, UUID().uuidString, occurredAt, occurredAt,
                try AppDatabase.nextChangeSeq(db),
            ]
        )
    }

    @Test("an 11pm 31 March transaction stays in March — DEC-009's whole point")
    func lateNightOnABoundaryStaysInItsOwnPeriod() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            let category = try Fixture.insertCategory(db, name: "Groceries")
            var settings = try BudgetSettingsStore().load(db)
            settings.schedule = PeriodSchedule(anchor: try date("2026-03-01"), cadence: .monthly)
            try BudgetSettingsStore().save(settings, in: db)
            try CategoryLimits().setLimit(
                categoryID: category,
                amount: Money(minorUnits: 50000, currency: .aud),
                effectiveFrom: try date("2026-03-01"),
                in: db
            )
            // Generated as the app would: once during March, then again in April.
            try PeriodGenerator().generate(through: try date("2026-03-15"), in: db)
            try PeriodGenerator().generate(through: try date("2026-04-15"), in: db)

            // Two purchases either side of the boundary, both with an occurred_at
            // whose UTC day differs from the local day the user experienced.
            //
            // Australia is still on daylight saving here (it ends 5 April), so the
            // Melbourne clock is UTC+11. 11pm on 31 March is midday UTC on the 31st;
            // 9am on 1 April is 10pm UTC on the *31st*. Decide period membership by
            // the instant and that second purchase falls into March. booked_on is a
            // local date, so it cannot.
            try insert(db, account: account, category: category, purchase: Purchase(
                amount: 4500, bookedOn: "2026-03-31", occurredAt: "2026-03-31T12:00:00.000Z"
            ))
            // 9am on 1 April in Melbourne — 10pm on 31 March in UTC.
            try insert(db, account: account, category: category, purchase: Purchase(
                amount: 1100, bookedOn: "2026-04-01", occurredAt: "2026-03-31T22:00:00.000Z"
            ))

            let rows = try PeriodCategoryStatusRow.fetchAll(
                db, sql: "SELECT * FROM period_category_status ORDER BY starts_on"
            )
            let march = try #require(rows.first { $0.startsOn == "2026-03-01" })
            let april = try #require(rows.first { $0.startsOn == "2026-04-01" })
            #expect(march.spentMinor == 4500, "an 11pm 31 March purchase belongs to March")
            #expect(april.spentMinor == 1100, "a 9am 1 April purchase belongs to April, not to March")
        }
    }

    @Test("the view inherits every exclusion from `spending` rather than restating it")
    func inheritsTheSpendingViewsExclusions() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let (account, category) = try setUp(db)
            let savings = try Fixture.insertAccount(db, name: "Savings")

            try Fixture.insertTransaction(
                db, kind: "expense", status: "draft", amountMinor: 10000,
                accountID: account, categoryID: category, bookedOn: "2026-03-05"
            )
            try Fixture.insertTransaction(
                db, kind: "expense", amountMinor: 20000,
                accountID: account, categoryID: category, bookedOn: "2026-03-06",
                deletedAt: "2026-03-07T00:00:00.000Z"
            )
            try Fixture.insertTransaction(
                db, kind: "transfer", amountMinor: 90000,
                fromAccountID: account, toAccountID: savings, bookedOn: "2026-03-08"
            )
            try Fixture.insertTransaction(
                db, kind: "income", amountMinor: 300_000,
                accountID: account, bookedOn: "2026-03-09"
            )

            #expect(try status(db)?.spentMinor == 0, "drafts, deletions, transfers and income all excluded")
        }
    }

    @Test("a refund reduces what the period has spent — DEC-037")
    func refundsReduceSpending() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let (account, category) = try setUp(db)
            try Fixture.insertTransaction(
                db, kind: "expense", amountMinor: 34000,
                accountID: account, categoryID: category, bookedOn: "2026-03-10"
            )
            try Fixture.insertTransaction(
                db, kind: "refund", amountMinor: 4000,
                accountID: account, categoryID: category, bookedOn: "2026-03-11"
            )

            #expect(try status(db)?.spentMinor == 30000)
            #expect(try status(db)?.remainingMinor == 20000)
        }
    }

    @Test("an overspent category reports a negative remainder rather than clamping to zero")
    func overspendingIsVisible() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let (account, category) = try setUp(db)
            try Fixture.insertTransaction(
                db, kind: "expense", amountMinor: 62500,
                accountID: account, categoryID: category, bookedOn: "2026-03-10"
            )

            #expect(try status(db)?.remainingMinor == -12500, "the size of the hole is the useful number")
        }
    }
}
