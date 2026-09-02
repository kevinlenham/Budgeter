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

            // 31 March 2026, 11pm in Melbourne. Australia leaves daylight saving on
            // 5 April, so the local clock is UTC+11 here: the UTC instant is already
            // 1 April. Stored as an instant, this purchase lands in April. Stored as
            // booked_on — a local date — it cannot.
            try db.execute(
                sql: """
                INSERT INTO transactions (
                    id, kind, status, amount_minor, currency, account_id, category_id,
                    merchant, booked_on, occurred_at, source, dedupe_key,
                    created_at, updated_at, change_seq
                ) VALUES (?, 'expense', 'confirmed', 4500, 'AUD', ?, ?,
                          'Late night chemist', '2026-03-31', '2026-04-01T12:00:00.000Z',
                          'manual', ?, '2026-03-31T12:00:00.000Z', '2026-03-31T12:00:00.000Z', ?)
                """,
                arguments: [
                    UUIDv7.generate().uuidString, account.uuidString, category.uuidString,
                    UUID().uuidString, try AppDatabase.nextChangeSeq(db),
                ]
            )

            let rows = try PeriodCategoryStatusRow.fetchAll(
                db, sql: "SELECT * FROM period_category_status ORDER BY starts_on"
            )
            let march = try #require(rows.first { $0.startsOn == "2026-03-01" })
            let april = try #require(rows.first { $0.startsOn == "2026-04-01" })
            #expect(march.spentMinor == 4500, "an 11pm 31 March purchase belongs to March")
            #expect(april.spentMinor == 0)
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

@Suite("Safe to spend — DEC-009")
struct SafeToSpendTests {
    private func period(_ start: String, _ end: String) throws -> BudgetPeriod {
        BudgetPeriod(
            index: 0,
            startsOn: try #require(CivilDate(iso: start)),
            endsOn: try #require(CivilDate(iso: end))
        )
    }

    private func date(_ iso: String) throws -> CivilDate {
        try #require(CivilDate(iso: iso))
    }

    @Test("days remaining counts today, so the last day of a period has one day left")
    func daysRemainingIsInclusive() throws {
        let march = try period("2026-03-01", "2026-03-31")
        #expect(SafeToSpend.daysRemaining(in: march, asOf: try date("2026-03-01")) == 31)
        #expect(SafeToSpend.daysRemaining(in: march, asOf: try date("2026-03-15")) == 17)
        #expect(SafeToSpend.daysRemaining(in: march, asOf: try date("2026-03-31")) == 1, "not zero")
        #expect(SafeToSpend.daysRemaining(in: march, asOf: try date("2026-04-01")) == 0)
        #expect(SafeToSpend.daysRemaining(in: march, asOf: try date("2026-02-01")) == 31, "not yet started")
    }

    @Test("the daily allowance is the remainder spread over the days that are left")
    func dailyAllowance() throws {
        let remaining = Money(minorUnits: 16000, currency: .aud)
        #expect(try SafeToSpend.daily(remaining: remaining, daysRemaining: 16).minorUnits == 1000)
        #expect(try SafeToSpend.daily(remaining: remaining, daysRemaining: 1).minorUnits == 16000)
    }

    @Test("the allowance rounds down, so the figure is always actually affordable")
    func roundsDown() throws {
        let remaining = Money(minorUnits: 1000, currency: .aud)
        #expect(try SafeToSpend.daily(remaining: remaining, daysRemaining: 3).minorUnits == 333)
        #expect(try SafeToSpend.daily(remaining: remaining, daysRemaining: 7).minorUnits == 142)
    }

    @Test("an overspent category may spend nothing today, rather than a negative amount")
    func overspentGivesZero() throws {
        let overspent = Money(minorUnits: -12500, currency: .aud)
        #expect(try SafeToSpend.daily(remaining: overspent, daysRemaining: 10).isZero)
        #expect(try SafeToSpend.daily(remaining: Money.zero(.aud), daysRemaining: 10).isZero)
    }

    @Test("the currency survives the division")
    func currencyIsPreserved() throws {
        let remaining = Money(minorUnits: 10000, currency: .jpy)
        #expect(try SafeToSpend.daily(remaining: remaining, daysRemaining: 4).currency == .jpy)
    }

    @Test("a finished period throws rather than dividing by zero")
    func endedPeriodThrows() throws {
        #expect(throws: SafeToSpendError.periodAlreadyEnded) {
            try SafeToSpend.daily(remaining: Money(minorUnits: 100, currency: .aud), daysRemaining: 0)
        }
    }
}
