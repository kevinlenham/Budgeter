//
//  Directory.swift
//  Budgeter
//
//  Accounts and categories: the two lists everything else refers to. Small enough to
//  share a file, and they are always set up together during onboarding.
//

import Foundation
import GRDB

nonisolated struct AccountStore: Sendable {
    var now: @Sendable () -> Date = { Date() }
    var makeID: @Sendable () -> UUID = { UUIDv7.generate() }

    @discardableResult
    func create(name: String, currency: Currency, in db: Database) throws -> UUID {
        let id = makeID()
        let timestamp = IngestFunnel.iso8601.format(now())
        try db.execute(
            sql: """
            INSERT INTO accounts (id, name, currency, created_at, updated_at, deleted_at, change_seq)
            VALUES (?, ?, ?, ?, ?, NULL, ?)
            """,
            arguments: [
                id.uuidString, name.trimmedOrNil ?? name, currency.rawValue,
                timestamp, timestamp, try AppDatabase.nextChangeSeq(db),
            ]
        )
        return id
    }

    func all(in db: Database) throws -> [AccountRecord] {
        try AccountRecord.fetchAll(
            db, sql: "SELECT * FROM accounts WHERE deleted_at IS NULL ORDER BY name"
        )
    }
}

nonisolated struct CategoryStore: Sendable {
    var now: @Sendable () -> Date = { Date() }
    var makeID: @Sendable () -> UUID = { UUIDv7.generate() }

    /// The list offered at onboarding. Deliberately short: a starter list long
    /// enough to feel complete is a list nobody edits, and categories the user did
    /// not choose are categories they will not recognise on the budget screen.
    static let starters = [
        "Groceries", "Eating out", "Transport", "Bills", "Shopping", "Health", "Fun",
    ]

    @discardableResult
    func create(name: String, in db: Database) throws -> UUID {
        let id = makeID()
        let timestamp = IngestFunnel.iso8601.format(now())
        try db.execute(
            sql: """
            INSERT INTO categories (id, name, created_at, updated_at, deleted_at, change_seq)
            VALUES (?, ?, ?, ?, NULL, ?)
            """,
            arguments: [
                id.uuidString, name.trimmedOrNil ?? name,
                timestamp, timestamp, try AppDatabase.nextChangeSeq(db),
            ]
        )
        return id
    }

    func all(in db: Database) throws -> [CategoryRecord] {
        try CategoryRecord.fetchAll(
            db, sql: "SELECT * FROM categories WHERE deleted_at IS NULL ORDER BY name"
        )
    }
}
