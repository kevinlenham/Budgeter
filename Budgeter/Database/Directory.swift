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

    /// Renaming only. An account's currency is not editable, and the omission is
    /// deliberate: changing it would reinterpret every `amount_minor` already
    /// booked against the account as a different currency, which is invariant 1
    /// broken by the settings screen. Wrong currency means a new account.
    func rename(id: UUID, to name: String, in db: Database) throws {
        guard let name = name.trimmedOrNil else { throw DirectoryError.emptyName }
        try db.execute(
            sql: "UPDATE accounts SET name = ?, updated_at = ?, change_seq = ? WHERE id = ?",
            arguments: [
                name, IngestFunnel.iso8601.format(now()),
                try AppDatabase.nextChangeSeq(db), id.uuidString,
            ]
        )
    }
}

nonisolated enum DirectoryError: Error, Equatable {
    /// A name that is blank, or only whitespace. The columns' CHECK constraints
    /// reject it too; this reports it before the write so the form can say so.
    case emptyName
    /// Another live category already has this name, ignoring case.
    ///
    /// Not a schema constraint, because the database has no opinion about it and a
    /// UNIQUE index would also have to decide what "the same name" means across
    /// case and accents. It is a UI-level rule with a UI-level reason: two rows
    /// reading "Groceries" on the budget screen is indistinguishable from a bug,
    /// and the user cannot tell which limit belongs to which.
    case duplicateName(String)
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
        guard let name = name.trimmedOrNil else { throw DirectoryError.emptyName }
        try requireNameIsFree(name, excluding: nil, in: db)
        let id = makeID()
        let timestamp = IngestFunnel.iso8601.format(now())
        try db.execute(
            sql: """
            INSERT INTO categories (id, name, created_at, updated_at, deleted_at, change_seq)
            VALUES (?, ?, ?, ?, NULL, ?)
            """,
            arguments: [
                id.uuidString, name,
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

    func rename(id: UUID, to name: String, in db: Database) throws {
        guard let name = name.trimmedOrNil else { throw DirectoryError.emptyName }
        try requireNameIsFree(name, excluding: id, in: db)
        try db.execute(
            sql: "UPDATE categories SET name = ?, updated_at = ?, change_seq = ? WHERE id = ?",
            arguments: [
                name, IngestFunnel.iso8601.format(now()),
                try AppDatabase.nextChangeSeq(db), id.uuidString,
            ]
        )
    }

    /// Retires a category.
    ///
    /// Invariant 3: a tombstone, never a DELETE. Transactions already booked to it
    /// keep pointing at it, and that is the intended outcome — deleting a category
    /// is the user saying "stop offering me this", not "that money was never
    /// spent". The `ledger` view joins categories on `deleted_at IS NULL`, so those
    /// rows simply stop showing a category name; `spending` never joined categories
    /// at all, so no total moves by a cent.
    ///
    /// Two things are retired alongside it, because leaving them would keep the
    /// category half-alive:
    ///
    /// - its open limit, which every future period would otherwise go on
    ///   snapshotting into `period_limits` for a category the budget screen no
    ///   longer shows;
    /// - its merchant rules (DEC-030), which would otherwise keep guessing a
    ///   category that cannot be chosen.
    ///
    /// Periods already generated keep their snapshot. That is DEC-008's rule
    /// working as intended: March's budget is what March's budget was.
    func delete(id: UUID, in db: Database) throws {
        let timestamp = IngestFunnel.iso8601.format(now())
        try db.execute(
            sql: """
            UPDATE categories
               SET deleted_at = ?, updated_at = ?, change_seq = ?
             WHERE id = ? AND deleted_at IS NULL
            """,
            arguments: [timestamp, timestamp, try AppDatabase.nextChangeSeq(db), id.uuidString]
        )
        try db.execute(
            sql: """
            UPDATE category_limits
               SET deleted_at = ?, updated_at = ?, change_seq = ?
             WHERE category_id = ? AND effective_to IS NULL AND deleted_at IS NULL
            """,
            arguments: [timestamp, timestamp, try AppDatabase.nextChangeSeq(db), id.uuidString]
        )
        try MerchantRules(now: now).deleteAll(categoryID: id, in: db)
    }

    // MARK: - Private

    private func requireNameIsFree(_ name: String, excluding id: UUID?, in db: Database) throws {
        let taken = try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS (
                SELECT 1 FROM categories
                 WHERE deleted_at IS NULL
                   AND lower(name) = lower(?)
                   AND id IS NOT ?
            )
            """,
            arguments: [name, id?.uuidString]
        )
        if taken == true {
            throw DirectoryError.duplicateName(name)
        }
    }
}
