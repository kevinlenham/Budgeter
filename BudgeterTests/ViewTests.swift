//
//  ViewTests.swift
//  BudgeterTests
//
//  Rules 1, 2, 7 and 9. The `spending` and `postings` views are the only things any
//  aggregate is permitted to read, so their definitions carry invariants 2 and 3 and
//  the draft rule for the whole app. If these tests are wrong, everything downstream
//  is quietly wrong with them.
//

import Foundation
import GRDB
import Testing
@testable import Budgeter

@Suite("The spending view")
struct SpendingViewTests {
    @Test("a transfer moves no spending total by a cent — invariant 2")
    func transfersAreNeverSpending() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let from = try Fixture.insertAccount(db, name: "Everyday")
            let to = try Fixture.insertAccount(db, name: "Savings")
            let category = try Fixture.insertCategory(db)

            try Fixture.insertTransaction(
                db, kind: "expense", amountMinor: 5000,
                accountID: from, categoryID: category
            )
            let before = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(amount_minor), 0) FROM spending")

            try Fixture.insertTransaction(
                db, kind: "transfer", amountMinor: 100_000,
                fromAccountID: from, toAccountID: to
            )
            let after = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(amount_minor), 0) FROM spending")

            #expect(before == 5000)
            #expect(after == before, "a $1000 transfer changed spending")
        }
    }

    @Test("income is never spending — rule 9")
    func incomeIsNeverSpending() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            try Fixture.insertTransaction(db, kind: "income", amountMinor: 250_000, accountID: account)

            let rows = try SpendingRow.fetchAll(db, sql: "SELECT * FROM spending")
            #expect(rows.isEmpty)
        }
    }

    @Test("a draft never counts toward the authoritative number — rule 7")
    func draftsAreNotSpending() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            let category = try Fixture.insertCategory(db)

            try Fixture.insertTransaction(
                db, kind: "expense", status: "draft", amountMinor: 2800,
                accountID: account, categoryID: category
            )

            let total = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(amount_minor), 0) FROM spending")
            #expect(total == 0, "an unconfirmed draft was counted as spending")
        }
    }

    @Test("a soft-deleted row is not spending — invariant 3")
    func softDeletedIsNotSpending() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            let category = try Fixture.insertCategory(db)

            try Fixture.insertTransaction(
                db, kind: "expense", amountMinor: 4200,
                accountID: account, categoryID: category,
                deletedAt: "2026-09-01T12:00:00.000Z"
            )

            let total = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(amount_minor), 0) FROM spending")
            #expect(total == 0)
        }
    }

    @Test("a refund reduces its category by exactly its amount — DEC-037")
    func refundsSubtract() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            let category = try Fixture.insertCategory(db, name: "Clothing")

            try Fixture.insertTransaction(
                db, kind: "expense", amountMinor: 8000,
                accountID: account, categoryID: category
            )
            try Fixture.insertTransaction(
                db, kind: "refund", amountMinor: 8000,
                accountID: account, categoryID: category
            )

            let total = try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(amount_minor), 0) FROM spending WHERE category_id = ?",
                arguments: [category.uuidString]
            )
            #expect(total == 0, "buying and returning a jacket left spending non-zero")
        }
    }

    @Test("the stored row stays unsigned even though the view is signed — rule 10")
    func tableStaysUnsigned() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            let category = try Fixture.insertCategory(db)
            try Fixture.insertTransaction(
                db, kind: "refund", amountMinor: 8000,
                accountID: account, categoryID: category
            )

            let stored = try Int64.fetchOne(db, sql: "SELECT amount_minor FROM transactions")
            let viewed = try Int64.fetchOne(db, sql: "SELECT amount_minor FROM spending")

            #expect(stored == 8000, "the sign leaked into the table")
            #expect(viewed == -8000, "the view failed to sign the refund")
        }
    }
}

@Suite("The postings view")
struct PostingsViewTests {
    @Test("a transfer expands into two rows that cancel — DEC-028")
    func transferExpandsIntoTwoSignedRows() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let from = try Fixture.insertAccount(db, name: "Everyday")
            let to = try Fixture.insertAccount(db, name: "Savings")

            try Fixture.insertTransaction(
                db, kind: "transfer", amountMinor: 25000,
                fromAccountID: from, toAccountID: to
            )

            let postings = try PostingRow.fetchAll(db, sql: "SELECT * FROM postings ORDER BY amount_minor")
            #expect(postings.count == 2)
            #expect(postings.map(\.amountMinor) == [-25000, 25000])
            #expect(postings.first?.accountId == from.uuidString)
            #expect(postings.last?.accountId == to.uuidString)

            let net = try Int64.fetchOne(db, sql: "SELECT SUM(amount_minor) FROM postings")
            #expect(net == 0, "a transfer changed total net worth")
        }
    }

    @Test("balances come out right across every kind")
    func balancesAcrossAllKinds() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let everyday = try Fixture.insertAccount(db, name: "Everyday")
            let savings = try Fixture.insertAccount(db, name: "Savings")
            let category = try Fixture.insertCategory(db)

            try Fixture.insertTransaction(db, kind: "income", amountMinor: 300_000, accountID: everyday)
            try Fixture.insertTransaction(db, kind: "expense", amountMinor: 5000,
                                          accountID: everyday, categoryID: category)
            try Fixture.insertTransaction(db, kind: "refund", amountMinor: 2000,
                                          accountID: everyday, categoryID: category)
            try Fixture.insertTransaction(db, kind: "transfer", amountMinor: 100_000,
                                          fromAccountID: everyday, toAccountID: savings)

            let everydayBalance = try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(amount_minor), 0) FROM postings WHERE account_id = ?",
                arguments: [everyday.uuidString]
            )
            let savingsBalance = try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(amount_minor), 0) FROM postings WHERE account_id = ?",
                arguments: [savings.uuidString]
            )

            // 3000.00 in, 50.00 out, 20.00 back, 1000.00 moved to savings.
            let expectedEveryday: Int64 = 300_000 - 5000 + 2000 - 100_000
            #expect(everydayBalance == expectedEveryday)
            #expect(savingsBalance == 100_000)
        }
    }

    @Test("drafts and deleted rows never reach a balance")
    func draftsAndDeletedAreExcluded() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            let category = try Fixture.insertCategory(db)

            try Fixture.insertTransaction(db, kind: "expense", status: "draft", amountMinor: 999,
                                          accountID: account, categoryID: category)
            try Fixture.insertTransaction(db, kind: "expense", amountMinor: 777,
                                          accountID: account, categoryID: category,
                                          deletedAt: "2026-09-01T12:00:00.000Z")

            let balance = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(amount_minor), 0) FROM postings")
            #expect(balance == 0)
        }
    }
}
