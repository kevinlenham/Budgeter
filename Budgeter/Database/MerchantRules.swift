//
//  MerchantRules.swift
//  Budgeter
//
//  DEC-030's merchant memory: "a `merchant_rules` table mapping normalised merchant
//  string → category, written every time the user confirms or corrects a category".
//
//  Two properties are worth stating because they are choices, not accidents:
//
//  **The memory is last-writer-wins, not a vote.** If the user has booked the
//  corner shop to Groceries nine times and then books it to Eating out, the rule
//  becomes Eating out. A vote would need ten more corrections to change its mind,
//  during which the app would keep confidently proposing a category the user has
//  visibly stopped choosing — and DEC-030's whole justification is that the memory
//  is "deterministic, explainable, and the user can view and edit the rules".
//
//  **Reading never writes.** The suggestion is looked up while the user is typing,
//  inside a screen that may be redrawn many times; anything that wrote there would
//  be a write per keystroke. `hit_count` — which exists for DEC-023's stats screen,
//  where the categorisation correction rate is one of the numbers being closed out —
//  is therefore updated on save, where the user has actually accepted or rejected
//  the guess.
//

import Foundation
import GRDB

nonisolated struct MerchantRuleRecord: Codable, FetchableRecord, Equatable, Sendable, Identifiable {
    static let databaseTableName = "merchant_rules"

    var id: String
    /// The normalised key (`MerchantKey`), which is what lookups match on.
    var merchantKey: String
    /// The raw string the rule was last learned from, shown to the user so the
    /// rules screen lists something they recognise. Never matched against.
    var merchantSample: String?
    var categoryId: String
    var hitCount: Int64
    var lastUsedAt: String?
    var createdAt: String
    var updatedAt: String
    var deletedAt: String?
    var changeSeq: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case merchantKey = "merchant_key"
        case merchantSample = "merchant_sample"
        case categoryId = "category_id"
        case hitCount = "hit_count"
        case lastUsedAt = "last_used_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case changeSeq = "change_seq"
    }
}

/// A rule with its category's name attached, for the rules screen.
nonisolated struct MerchantRuleListing: Codable, FetchableRecord, Equatable, Sendable, Identifiable {
    var id: String
    var merchantKey: String
    var merchantSample: String?
    var categoryId: String
    var categoryName: String
    var hitCount: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case merchantKey = "merchant_key"
        case merchantSample = "merchant_sample"
        case categoryId = "category_id"
        case categoryName = "category_name"
        case hitCount = "hit_count"
    }

    /// What to show as the merchant. The raw sample when there is one, because it
    /// is the string the user typed and will recognise; the key otherwise.
    var displayName: String {
        merchantSample ?? merchantKey
    }
}

nonisolated struct MerchantRules: Sendable {
    var now: @Sendable () -> Date = { Date() }
    var makeID: @Sendable () -> UUID = { UUIDv7.generate() }

    // MARK: - Reading

    /// The category to propose for a merchant, or nil if nothing has been learned.
    ///
    /// Read-only. A rule pointing at a category the user has since deleted returns
    /// nil rather than a dead id — `CategoryStore.delete` retires those rules, and
    /// this join is the belt to that braces.
    func suggestion(forMerchant merchant: String?, in db: Database) throws -> UUID? {
        guard let key = MerchantKey.normalise(merchant) else { return nil }
        let id = try String.fetchOne(
            db,
            sql: """
            SELECT r.category_id
              FROM merchant_rules r
              JOIN categories c ON c.id = r.category_id AND c.deleted_at IS NULL
             WHERE r.merchant_key = ? AND r.deleted_at IS NULL
            """,
            arguments: [key]
        )
        return id.flatMap(UUID.init(uuidString:))
    }

    func all(in db: Database) throws -> [MerchantRuleListing] {
        try MerchantRuleListing.fetchAll(db, sql: """
        SELECT r.id, r.merchant_key, r.merchant_sample, r.category_id,
               c.name AS category_name, r.hit_count
          FROM merchant_rules r
          JOIN categories c ON c.id = r.category_id AND c.deleted_at IS NULL
         WHERE r.deleted_at IS NULL
         ORDER BY COALESCE(r.merchant_sample, r.merchant_key) COLLATE NOCASE
        """)
    }

    // MARK: - Writing

    /// Learns, or re-learns, the category for a merchant.
    ///
    /// Called on every save of an expense or refund that names both — DEC-030's
    /// "written every time the user confirms or corrects a category". A merchant
    /// that normalises to nothing teaches nothing rather than teaching a rule keyed
    /// on the empty string.
    ///
    /// Returns whether anything was learned, so a caller that wants to say so can.
    @discardableResult
    func remember(merchant: String?, categoryID: UUID, in db: Database) throws -> Bool {
        guard let key = MerchantKey.normalise(merchant) else { return false }
        let timestamp = IngestFunnel.iso8601.format(now())

        let existing = try Row.fetchOne(
            db,
            sql: "SELECT id, category_id FROM merchant_rules WHERE merchant_key = ? AND deleted_at IS NULL",
            arguments: [key]
        )

        guard let existing else {
            try db.execute(
                sql: """
                INSERT INTO merchant_rules (
                    id, merchant_key, merchant_sample, category_id,
                    hit_count, last_used_at,
                    created_at, updated_at, deleted_at, change_seq
                ) VALUES (?, ?, ?, ?, 0, ?, ?, ?, NULL, ?)
                """,
                arguments: [
                    makeID().uuidString, key, merchant?.trimmedOrNil, categoryID.uuidString,
                    timestamp, timestamp, timestamp, try AppDatabase.nextChangeSeq(db),
                ]
            )
            return true
        }

        // The count answers "how often was the standing guess right", which is only
        // meaningful while the guess stays the same. A correction resets it rather
        // than inheriting a score the new category never earned.
        let confirmed = (existing["category_id"] as String) == categoryID.uuidString
        try db.execute(
            sql: """
            UPDATE merchant_rules
               SET category_id     = ?,
                   merchant_sample = COALESCE(?, merchant_sample),
                   hit_count       = ?,
                   last_used_at    = ?,
                   updated_at      = ?,
                   change_seq      = ?
             WHERE id = ?
            """,
            arguments: [
                categoryID.uuidString,
                merchant?.trimmedOrNil,
                confirmed ? (existing["hit_count"] as Int64) + 1 : 0,
                timestamp,
                timestamp,
                try AppDatabase.nextChangeSeq(db),
                existing["id"] as String,
            ]
        )
        return true
    }

    /// Repoints a rule at a different category, from the rules screen.
    func update(id: UUID, categoryID: UUID, in db: Database) throws {
        let timestamp = IngestFunnel.iso8601.format(now())
        try db.execute(
            sql: """
            UPDATE merchant_rules
               SET category_id = ?, hit_count = 0, updated_at = ?, change_seq = ?
             WHERE id = ?
            """,
            arguments: [
                categoryID.uuidString, timestamp,
                try AppDatabase.nextChangeSeq(db), id.uuidString,
            ]
        )
    }

    /// Forgets a rule. A tombstone like every other deletion (invariant 3), but the
    /// unique index on `merchant_key` is partial on `deleted_at IS NULL`, so the
    /// user can teach the app a different answer for the same shop afterwards.
    func delete(id: UUID, in db: Database) throws {
        let timestamp = IngestFunnel.iso8601.format(now())
        try db.execute(
            sql: """
            UPDATE merchant_rules
               SET deleted_at = ?, updated_at = ?, change_seq = ?
             WHERE id = ? AND deleted_at IS NULL
            """,
            arguments: [timestamp, timestamp, try AppDatabase.nextChangeSeq(db), id.uuidString]
        )
    }

    /// Forgets every rule pointing at a category, for when the category itself is
    /// retired. Called by `CategoryStore.delete`.
    func deleteAll(categoryID: UUID, in db: Database) throws {
        let timestamp = IngestFunnel.iso8601.format(now())
        try db.execute(
            sql: """
            UPDATE merchant_rules
               SET deleted_at = ?, updated_at = ?, change_seq = ?
             WHERE category_id = ? AND deleted_at IS NULL
            """,
            arguments: [timestamp, timestamp, try AppDatabase.nextChangeSeq(db), categoryID.uuidString]
        )
    }
}
