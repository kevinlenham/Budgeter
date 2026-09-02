//
//  Fixtures.swift
//  BudgeterTests
//
//  Shared setup for the database tests. These insert rows with raw SQL rather than
//  through the funnel, deliberately: a constraint test must reach the constraint,
//  not stop at the funnel's own validation on the way.
//

import Foundation
import GRDB
import Testing
@testable import Budgeter

enum Fixture {
    static func database() throws -> AppDatabase {
        try AppDatabase.inMemory()
    }

    @discardableResult
    static func insertAccount(
        _ db: Database,
        id: UUID = UUIDv7.generate(),
        name: String = "Everyday",
        currency: String = "AUD"
    ) throws -> UUID {
        try db.execute(
            sql: """
            INSERT INTO accounts (id, name, currency, created_at, updated_at, change_seq)
            VALUES (?, ?, ?, '2026-09-01T00:00:00.000Z', '2026-09-01T00:00:00.000Z', ?)
            """,
            arguments: [id.uuidString, name, currency, try AppDatabase.nextChangeSeq(db)]
        )
        return id
    }

    @discardableResult
    static func insertCategory(
        _ db: Database,
        id: UUID = UUIDv7.generate(),
        name: String = "Groceries"
    ) throws -> UUID {
        try db.execute(
            sql: """
            INSERT INTO categories (id, name, created_at, updated_at, change_seq)
            VALUES (?, ?, '2026-09-01T00:00:00.000Z', '2026-09-01T00:00:00.000Z', ?)
            """,
            arguments: [id.uuidString, name, try AppDatabase.nextChangeSeq(db)]
        )
        return id
    }

    /// Raw insert, bypassing the funnel, so a constraint is tested rather than the
    /// funnel's own validation.
    static func insertTransaction(
        _ db: Database,
        id: UUID = UUIDv7.generate(),
        kind: String,
        status: String = "confirmed",
        amountMinor: Int64 = 1000,
        currency: String = "AUD",
        accountID: UUID? = nil,
        fromAccountID: UUID? = nil,
        toAccountID: UUID? = nil,
        categoryID: UUID? = nil,
        bookedOn: String = "2026-09-01",
        source: String = "manual",
        dedupeKey: String = UUID().uuidString,
        deletedAt: String? = nil
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO transactions (
                id, kind, status, amount_minor, currency,
                account_id, from_account_id, to_account_id, category_id,
                merchant, booked_on, occurred_at, source, dedupe_key,
                created_at, updated_at, deleted_at, change_seq
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'Woolworths', ?,
                      '2026-09-01T10:00:00.000Z', ?, ?,
                      '2026-09-01T00:00:00.000Z', '2026-09-01T00:00:00.000Z', ?, ?)
            """,
            arguments: [
                id.uuidString, kind, status, amountMinor, currency,
                accountID?.uuidString, fromAccountID?.uuidString,
                toAccountID?.uuidString, categoryID?.uuidString,
                bookedOn, source, dedupeKey, deletedAt,
                try AppDatabase.nextChangeSeq(db),
            ]
        )
    }
}
