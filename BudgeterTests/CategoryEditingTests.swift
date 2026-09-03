//
//  CategoryEditingTests.swift
//  BudgeterTests
//
//  Category CRUD, and specifically the part that is not CRUD: what deleting one
//  does to everything pointing at it.
//
//  Invariant 3 says deletion is a tombstone. The interesting consequence is that a
//  retired category must stop *acting* — no more limits snapshotted into future
//  periods, no more merchant rules firing — while every number it was ever part of
//  stays exactly where it was.
//

import Foundation
import GRDB
import Testing
@testable import Budgeter

@Suite("Editing categories")
struct CategoryEditingTests {
    private func date(_ iso: String) throws -> CivilDate {
        try #require(CivilDate(iso: iso))
    }

    @Test("renaming leaves the category's id, and everything booked to it, alone")
    func renamePreservesIdentity() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.onboard(db)
            let groceries = try Fixture.category("Groceries", in: db)
            try TransactionStore().create(
                TransactionDraft(
                    kind: .expense,
                    amount: Money(minorUnits: 4500, currency: .aud),
                    accountID: account,
                    categoryID: groceries,
                    merchant: "Woolworths",
                    bookedOn: try date("2026-09-02")
                ),
                in: db
            )

            try CategoryStore().rename(id: groceries, to: "Food", in: db)

            #expect(try Fixture.category("Food", in: db) == groceries)
            let spent = try Int64.fetchOne(db, sql: """
            SELECT COALESCE(SUM(amount_minor), 0) FROM spending WHERE category_id = ?
            """, arguments: [groceries.uuidString])
            #expect(spent == 4500, "a rename is not a change of category")
        }
    }

    @Test("two categories cannot share a name")
    func duplicateNamesRejected() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try Fixture.onboard(db)
            #expect(throws: DirectoryError.self) {
                try CategoryStore().create(name: "groceries", in: db)
            }
            // Not a schema rule, a legibility one: two rows reading "Groceries" on
            // the budget screen are indistinguishable from a bug.
            let transport = try Fixture.category("Transport", in: db)
            #expect(throws: DirectoryError.self) {
                try CategoryStore().rename(id: transport, to: "Groceries", in: db)
            }
        }
    }

    @Test("a blank name is refused before it reaches the CHECK constraint")
    func blankNamesRejected() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try Fixture.onboard(db)
            #expect(throws: DirectoryError.self) {
                try CategoryStore().create(name: "   ", in: db)
            }
        }
    }

    @Test("deleting a category changes no total by a cent")
    func deleteMovesNoMoney() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.onboard(db)
            let groceries = try Fixture.category("Groceries", in: db)
            try TransactionStore().create(
                TransactionDraft(
                    kind: .expense,
                    amount: Money(minorUnits: 4500, currency: .aud),
                    accountID: account,
                    categoryID: groceries,
                    merchant: "Woolworths",
                    bookedOn: try date("2026-09-02")
                ),
                in: db
            )

            let before = try Int64.fetchOne(db, sql: "SELECT SUM(amount_minor) FROM spending")
            try CategoryStore().delete(id: groceries, in: db)
            let after = try Int64.fetchOne(db, sql: "SELECT SUM(amount_minor) FROM spending")

            // `spending` never joined categories, so retiring one cannot move a
            // total. The transaction is still there, still counted, still spent.
            #expect(before == after)
            #expect(after == 4500)
        }
    }

    @Test("a deleted category stops being offered and stops being guessed")
    func deleteRetiresItsRulesAndLimits() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try Fixture.onboard(db)
            let groceries = try Fixture.category("Groceries", in: db)

            try CategoryLimits().setLimit(
                categoryID: groceries,
                amount: Money(minorUnits: 50000, currency: .aud),
                effectiveFrom: try date("2026-08-28"),
                in: db
            )
            try MerchantRules().remember(merchant: "Woolworths", categoryID: groceries, in: db)

            try CategoryStore().delete(id: groceries, in: db)

            let remaining = try CategoryStore().all(in: db)
            #expect(remaining.allSatisfy { $0.name != "Groceries" })
            // Left behind, these would keep the category half-alive: limits
            // snapshotted into every future period for something the budget screen
            // no longer shows, and a guess the user cannot accept.
            #expect(try CategoryLimits().limit(categoryID: groceries, on: try date("2026-09-02"), in: db) == nil)
            #expect(try MerchantRules().suggestion(forMerchant: "Woolworths", in: db) == nil)
        }
    }

    @Test("a period already generated keeps the limit it snapshotted")
    func pastPeriodsKeepTheirSnapshot() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try Fixture.onboard(db)
            let groceries = try Fixture.category("Groceries", in: db)
            let period = try #require(try Queries.period(containing: try date("2026-09-02"), in: db))

            try CategoryLimits().setLimit(
                categoryID: groceries,
                amount: Money(minorUnits: 50000, currency: .aud),
                effectiveFrom: try #require(CivilDate(iso: period.startsOn)),
                in: db
            )
            try PeriodGenerator().resnapshot(period: period, in: db)
            try CategoryStore().delete(id: groceries, in: db)

            // DEC-008 working as designed: March's budget is what March's budget
            // was, whatever the user does to their categories afterwards.
            let snapshot = try Int64.fetchOne(db, sql: """
            SELECT amount_minor FROM period_limits WHERE period_id = ? AND category_id = ?
            """, arguments: [period.id, groceries.uuidString])
            #expect(snapshot == 50000)
        }
    }
}
