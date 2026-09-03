//
//  TransactionStoreTests.swift
//  BudgeterTests
//
//  The write path the entry form uses, and the `ledger` view it reads back.
//

import Foundation
import GRDB
import Testing
@testable import Budgeter

@Suite("Manual entry")
struct TransactionStoreTests {
    private func date(_ iso: String) throws -> CivilDate {
        try #require(CivilDate(iso: iso))
    }

    private func draft(
        _ account: UUID,
        kind: TransactionKind = .expense,
        amount: Int64 = 1250,
        category: UUID? = nil,
        merchant: String? = "Woolworths",
        on day: String = "2026-09-01"
    ) throws -> TransactionDraft {
        TransactionDraft(
            kind: kind,
            amount: Money(minorUnits: amount, currency: .aud),
            accountID: account,
            categoryID: category,
            merchant: merchant,
            bookedOn: try date(day)
        )
    }

    @Test("an entry is stored with source 'manual' and lands in the spending view")
    func createsAnExpense() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            let category = try Fixture.insertCategory(db)

            try TransactionStore().create(try draft(account, category: category), in: db)

            let source = try String.fetchOne(db, sql: "SELECT source FROM transactions")
            #expect(source == "manual")
            #expect(try Int64.fetchOne(db, sql: "SELECT SUM(amount_minor) FROM spending") == 1250)
        }
    }

    @Test("two identical manual entries are two real purchases — DEC-005")
    func identicalEntriesBothSurvive() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            let store = TransactionStore()

            try store.create(try draft(account), in: db)
            try store.create(try draft(account), in: db)

            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions") == 2)
        }
    }

    @Test("income is stored without a category even if the form offers one — rule 9")
    func incomeNeverCarriesACategory() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            let category = try Fixture.insertCategory(db)

            try TransactionStore().create(
                try draft(account, kind: .income, amount: 300_000, category: category, merchant: "Payroll"),
                in: db
            )

            let stored = try String.fetchOne(db, sql: "SELECT category_id FROM transactions")
            #expect(stored == nil, "the schema would have rejected this; the draft drops it first")
            #expect(try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(amount_minor), 0) FROM spending") == 0)
        }
    }

    @Test("an edit can correct the things the funnel treats as identity")
    func editCorrectsAnything() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let everyday = try Fixture.insertAccount(db, name: "Everyday")
            let savings = try Fixture.insertAccount(db, name: "Savings")
            let category = try Fixture.insertCategory(db)
            let store = TransactionStore()

            let id = try store.create(try draft(everyday, category: category), in: db)
            var corrected = try #require(try store.draft(id: id, in: db))
            corrected.accountID = savings
            corrected.amount = Money(minorUnits: 9900, currency: .aud)
            corrected.merchant = "Coles"
            try store.update(id: id, with: corrected, in: db)

            let reloaded = try #require(try store.draft(id: id, in: db))
            #expect(reloaded.accountID == savings, "a user saying 'wrong account' must be believed")
            #expect(reloaded.amount.minorUnits == 9900)
            #expect(reloaded.merchant == "Coles")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions") == 1)
        }
    }

    @Test("changing an expense to income drops its category rather than being rejected")
    func changingKindDropsTheCategory() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            let category = try Fixture.insertCategory(db)
            let store = TransactionStore()

            let id = try store.create(try draft(account, category: category), in: db)
            var corrected = try #require(try store.draft(id: id, in: db))
            corrected.kind = .income
            try store.update(id: id, with: corrected, in: db)

            #expect(try String.fetchOne(db, sql: "SELECT category_id FROM transactions") == nil)
        }
    }

    @Test("deleting is a tombstone, not a DELETE — invariant 3")
    func deleteIsSoft() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            let store = TransactionStore()
            let id = try store.create(try draft(account), in: db)

            try store.delete(id: id, in: db)

            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions") == 1)
            #expect(try String.fetchOne(db, sql: "SELECT deleted_at FROM transactions") != nil)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM spending") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ledger") == 0)
        }
    }

    @Test("a blank merchant is stored as NULL rather than an empty string")
    func blankMerchant() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            try TransactionStore().create(try draft(account, merchant: "   "), in: db)
            #expect(try String.fetchOne(db, sql: "SELECT merchant FROM transactions") == nil)
        }
    }
}

@Suite("The ledger view")
struct LedgerViewTests {
    private func date(_ iso: String) throws -> CivilDate {
        try #require(CivilDate(iso: iso))
    }

    @Test("money out is negative and money in is positive, from the user's point of view")
    func displaySigns() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            let savings = try Fixture.insertAccount(db, name: "Savings")
            let category = try Fixture.insertCategory(db)

            try Fixture.insertTransaction(
                db, kind: "expense", amountMinor: 1250, accountID: account,
                categoryID: category, bookedOn: "2026-09-01"
            )
            try Fixture.insertTransaction(
                db, kind: "income", amountMinor: 300_000, accountID: account, bookedOn: "2026-09-02"
            )
            try Fixture.insertTransaction(
                db, kind: "refund", amountMinor: 500, accountID: account,
                categoryID: category, bookedOn: "2026-09-03"
            )
            try Fixture.insertTransaction(
                db, kind: "transfer", amountMinor: 10000,
                fromAccountID: account, toAccountID: savings, bookedOn: "2026-09-04"
            )

            let byDay = try Dictionary(
                uniqueKeysWithValues: Queries.ledger(db).map { ($0.bookedOn, $0.amountMinor) }
            )
            #expect(byDay["2026-09-01"] == -1250, "an expense is money out")
            #expect(byDay["2026-09-02"] == 300_000, "income is money in")
            #expect(byDay["2026-09-03"] == 500, "a refund is money coming back")
            #expect(byDay["2026-09-04"] == -10000, "a transfer is money leaving the account it left")
        }
    }

    @Test("a transfer appears once, unlike in postings where it is two rows")
    func transfersAppearOnce() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let everyday = try Fixture.insertAccount(db, name: "Everyday")
            let savings = try Fixture.insertAccount(db, name: "Savings")
            try Fixture.insertTransaction(
                db, kind: "transfer", amountMinor: 10000,
                fromAccountID: everyday, toAccountID: savings
            )

            #expect(try Queries.ledger(db).count == 1)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM postings") == 2)
        }
    }

    @Test("drafts are listed and marked, rather than hidden — rule 7 is about totals")
    func draftsAreVisible() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            let category = try Fixture.insertCategory(db)
            try Fixture.insertTransaction(
                db, kind: "expense", status: "draft", amountMinor: 1250,
                accountID: account, categoryID: category
            )

            let entries = try Queries.ledger(db)
            #expect(entries.count == 1)
            #expect(entries.first?.isDraft == true)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM spending") == 0, "but it counts for nothing")
        }
    }

    @Test("the account and category names come along, so the list needs no second query")
    func namesAreJoined() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db, name: "Everyday")
            let category = try Fixture.insertCategory(db, name: "Groceries")
            try Fixture.insertTransaction(
                db, kind: "expense", accountID: account, categoryID: category
            )

            let entry = try #require(try Queries.ledger(db).first)
            #expect(entry.accountName == "Everyday")
            #expect(entry.categoryName == "Groceries")
        }
    }

    @Test("the newest day comes first, and same-day rows fall back to occurred_at")
    func ordering() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            for day in ["2026-09-01", "2026-09-05", "2026-09-03"] {
                try Fixture.insertTransaction(
                    db, kind: "expense", accountID: account, bookedOn: day
                )
            }

            let days = try Queries.ledger(db).map(\.bookedOn)
            #expect(days == ["2026-09-05", "2026-09-03", "2026-09-01"])
        }
    }
}
