//
//  SchemaConstraintTests.swift
//  BudgeterTests
//
//  Sprint 1's "done when": a test per rule that FAILS if the constraint is removed.
//  These are deliberately not happy-path tests — every one of them asserts that a
//  violation is *rejected*, so deleting the CHECK it guards turns it red.
//
//  Everything here runs against in-memory SQLite. No device, no simulator state.
//

import Foundation
import GRDB
import Testing
@testable import Budgeter

// MARK: - Kind and status

@Suite("Schema: kind and status")
struct KindAndStatusConstraintTests {
    @Test("an unknown kind is rejected")
    func unknownKindRejected() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            #expect(throws: DatabaseError.self) {
                try Fixture.insertTransaction(db, kind: "groceries", accountID: account)
            }
        }
    }

    @Test("all four kinds are accepted", arguments: ["expense", "refund", "transfer", "income"])
    func knownKindsAccepted(kind: String) throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let from = try Fixture.insertAccount(db, name: "From")
            let to = try Fixture.insertAccount(db, name: "To")

            if kind == "transfer" {
                try Fixture.insertTransaction(db, kind: kind, fromAccountID: from, toAccountID: to)
            } else {
                try Fixture.insertTransaction(db, kind: kind, accountID: from)
            }

            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions")
            #expect(count == 1)
        }
    }

    @Test("an unknown status is rejected")
    func unknownStatusRejected() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            #expect(throws: DatabaseError.self) {
                try Fixture.insertTransaction(db, kind: "expense", status: "pending", accountID: account)
            }
        }
    }

    @Test("an unknown source is rejected")
    func unknownSourceRejected() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            #expect(throws: DatabaseError.self) {
                try Fixture.insertTransaction(db, kind: "expense", accountID: account, source: "telepathy")
            }
        }
    }
}

// MARK: - Rule 9 and rule 10

@Suite("Schema: categories and signs")
struct CategoryAndSignConstraintTests {
    @Test("income may not carry a category — rule 9")
    func incomeCannotCarryCategory() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            let category = try Fixture.insertCategory(db)

            #expect(throws: DatabaseError.self) {
                try Fixture.insertTransaction(db, kind: "income", accountID: account, categoryID: category)
            }
        }
    }

    @Test("a transfer may not carry a category — invariant 2")
    func transferCannotCarryCategory() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let from = try Fixture.insertAccount(db, name: "From")
            let to = try Fixture.insertAccount(db, name: "To")
            let category = try Fixture.insertCategory(db)

            #expect(throws: DatabaseError.self) {
                try Fixture.insertTransaction(
                    db, kind: "transfer",
                    fromAccountID: from, toAccountID: to, categoryID: category
                )
            }
        }
    }

    @Test("a refund may carry a category, because reducing the right one is the point — DEC-037")
    func refundMayCarryCategory() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            let category = try Fixture.insertCategory(db)

            try Fixture.insertTransaction(db, kind: "refund", accountID: account, categoryID: category)
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions")
            #expect(count == 1)
        }
    }

    @Test("a negative amount is rejected — rule 10, sign lives only in the views")
    func negativeAmountRejected() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            #expect(throws: DatabaseError.self) {
                try Fixture.insertTransaction(db, kind: "expense", amountMinor: -500, accountID: account)
            }
        }
    }
}

// MARK: - Transfer shape (DEC-028)

@Suite("Schema: transfer shape")
struct TransferShapeConstraintTests {
    @Test("a transfer with only one end is rejected — a half-recorded transfer cannot exist")
    func halfTransferRejected() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let from = try Fixture.insertAccount(db, name: "From")
            #expect(throws: DatabaseError.self) {
                try Fixture.insertTransaction(db, kind: "transfer", fromAccountID: from)
            }
        }
    }

    @Test("a transfer to and from the same account is rejected")
    func selfTransferRejected() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            #expect(throws: DatabaseError.self) {
                try Fixture.insertTransaction(
                    db, kind: "transfer",
                    fromAccountID: account, toAccountID: account
                )
            }
        }
    }

    @Test("a transfer may not also carry a single account_id")
    func transferWithAccountIDRejected() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let from = try Fixture.insertAccount(db, name: "From")
            let to = try Fixture.insertAccount(db, name: "To")
            #expect(throws: DatabaseError.self) {
                try Fixture.insertTransaction(
                    db, kind: "transfer",
                    accountID: from, fromAccountID: from, toAccountID: to
                )
            }
        }
    }

    @Test("an expense must name an account")
    func expenseWithoutAccountRejected() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            #expect(throws: DatabaseError.self) {
                try Fixture.insertTransaction(db, kind: "expense")
            }
        }
    }

    @Test("an expense may not name transfer endpoints")
    func expenseWithTransferEndpointsRejected() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let from = try Fixture.insertAccount(db, name: "From")
            let to = try Fixture.insertAccount(db, name: "To")
            #expect(throws: DatabaseError.self) {
                try Fixture.insertTransaction(
                    db, kind: "expense",
                    accountID: from, fromAccountID: from, toAccountID: to
                )
            }
        }
    }
}

// MARK: - Dates, currency, foreign keys

@Suite("Schema: formats and references")
struct FormatConstraintTests {
    @Test("booked_on must be a local YYYY-MM-DD date — DEC-009")
    func bookedOnFormatEnforced() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)

            for bad in ["1 September 2026", "2026-9-1", "2026-09-01T10:00:00Z", "01/09/2026", ""] {
                #expect(throws: DatabaseError.self, "accepted \(bad)") {
                    try Fixture.insertTransaction(
                        db, kind: "expense", accountID: account, bookedOn: bad
                    )
                }
            }
        }
    }

    @Test("currency must be a three-letter uppercase code")
    func currencyFormatEnforced() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            for bad in ["aud", "AUDD", "AU", ""] {
                #expect(throws: DatabaseError.self, "accepted \(bad)") {
                    try Fixture.insertTransaction(
                        db, kind: "expense", currency: bad, accountID: account
                    )
                }
            }
        }
    }

    @Test("foreign keys are enforced — the PRAGMA that silently disables half the schema")
    func foreignKeysEnforced() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let enabled = try Bool.fetchOne(db, sql: "PRAGMA foreign_keys")
            #expect(enabled == true)

            // A transaction pointing at an account that does not exist.
            #expect(throws: DatabaseError.self) {
                try Fixture.insertTransaction(db, kind: "expense", accountID: UUIDv7.generate())
            }
        }
    }

    @Test("an account name cannot be blank")
    func blankAccountNameRejected() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            #expect(throws: DatabaseError.self) {
                try Fixture.insertAccount(db, name: "   ")
            }
        }
    }
}

// MARK: - Idempotency index (DEC-005)

@Suite("Schema: the dedupe index")
struct DedupeIndexTests {
    @Test("the same (account, source, dedupe_key) cannot be inserted twice")
    func duplicateRejected() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            try Fixture.insertTransaction(db, kind: "expense", accountID: account, dedupeKey: "row-1")

            #expect(throws: DatabaseError.self) {
                try Fixture.insertTransaction(db, kind: "expense", accountID: account, dedupeKey: "row-1")
            }
        }
    }

    @Test("the index covers soft-deleted rows, so a deletion is not resurrected")
    func softDeletedRowStillOccupiesItsSlot() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            try Fixture.insertTransaction(
                db, kind: "expense", accountID: account,
                dedupeKey: "row-1", deletedAt: "2026-09-01T12:00:00.000Z"
            )

            // A partial index (WHERE deleted_at IS NULL) would let this through,
            // resurrecting a row the user deliberately deleted.
            #expect(throws: DatabaseError.self) {
                try Fixture.insertTransaction(db, kind: "expense", accountID: account, dedupeKey: "row-1")
            }
        }
    }

    @Test("transfers dedupe too, which they would not without the COALESCE")
    func transfersDedupe() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let from = try Fixture.insertAccount(db, name: "From")
            let to = try Fixture.insertAccount(db, name: "To")

            try Fixture.insertTransaction(
                db, kind: "transfer", fromAccountID: from, toAccountID: to,
                source: "csv", dedupeKey: "transfer-1"
            )

            // SQLite treats NULLs as distinct, so indexing account_id alone would
            // make every ingested transfer unique and none would ever dedupe.
            #expect(throws: DatabaseError.self) {
                try Fixture.insertTransaction(
                    db, kind: "transfer", fromAccountID: from, toAccountID: to,
                    source: "csv", dedupeKey: "transfer-1"
                )
            }
        }
    }

    @Test("the same key from a different source is a different row")
    func differentSourcesDoNotCollide() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            try Fixture.insertTransaction(db, kind: "expense", accountID: account,
                                          source: "csv", dedupeKey: "shared")
            try Fixture.insertTransaction(db, kind: "expense", accountID: account,
                                          source: "wallet", dedupeKey: "shared")

            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions")
            #expect(count == 2)
        }
    }

    @Test("the same key on a different account is a different row")
    func differentAccountsDoNotCollide() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let first = try Fixture.insertAccount(db, name: "First")
            let second = try Fixture.insertAccount(db, name: "Second")

            try Fixture.insertTransaction(db, kind: "expense", accountID: first, dedupeKey: "shared")
            try Fixture.insertTransaction(db, kind: "expense", accountID: second, dedupeKey: "shared")

            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions")
            #expect(count == 2)
        }
    }
}

// MARK: - change_seq (DEC-006)

@Suite("Schema: change_seq")
struct ChangeSeqTests {
    @Test("every allocation is strictly greater than the last")
    func changeSeqIsMonotonic() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            var previous: Int64 = 0
            for _ in 0 ..< 50 {
                let next = try AppDatabase.nextChangeSeq(db)
                #expect(next > previous)
                previous = next
            }
        }
    }

    @Test("the counter table cannot grow a second row")
    func counterIsSingleton() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: "INSERT INTO change_counter (id, next_seq) VALUES (2, 0)")
            }
        }
    }
}
