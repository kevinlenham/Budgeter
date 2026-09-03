//
//  TransactionStore.swift
//  Budgeter
//
//  What the entry form talks to.
//
//  Creating goes through `IngestFunnel`, because rule 3 says all ingestion does and
//  a manual entry is ingestion with a source of `manual`. Its dedupe key is a fresh
//  UUID, per DEC-005: two identical manual entries are two real purchases, and the
//  app must never decide otherwise on the user's behalf.
//
//  Editing does *not* go through the funnel, and the distinction is worth stating.
//  The funnel deduplicates observations of the same external event, so it treats
//  kind, account and source as identity and will not change them. A user correcting
//  a row is not a second observation — they are saying the first one was wrong, and
//  that includes being wrong about which account it was on. So edits are their own
//  path, and the schema's CHECK constraints remain what keeps them honest.
//

import Foundation
import GRDB

/// What the form collects. Transfers are Sprint 5, so this covers the kinds the
/// Sprint 3 form can produce.
nonisolated struct TransactionDraft: Equatable, Sendable {
    var kind: TransactionKind
    var amount: Money
    var accountID: UUID
    var categoryID: UUID?
    var merchant: String?
    var bookedOn: CivilDate
    var status: TransactionStatus = .confirmed

    /// Income never carries a category (rule 9), so the form's category selection is
    /// dropped rather than sent to the database to be rejected.
    var effectiveCategoryID: UUID? {
        kind == .income ? nil : categoryID
    }
}

nonisolated struct TransactionStore: Sendable {
    var now: @Sendable () -> Date = { Date() }
    var makeID: @Sendable () -> UUID = { UUIDv7.generate() }

    @discardableResult
    func create(_ draft: TransactionDraft, in db: Database) throws -> UUID {
        let funnel = IngestFunnel(now: now, makeID: makeID)
        let outcome = try funnel.ingest(
            IngestedTransaction(
                kind: draft.kind,
                status: draft.status,
                amount: draft.amount,
                accountID: draft.accountID,
                categoryID: draft.effectiveCategoryID,
                merchant: draft.merchant?.trimmedOrNil,
                bookedOn: draft.bookedOn.iso,
                occurredAt: now(),
                source: .manual,
                dedupeKey: UUID().uuidString
            ),
            into: db
        )
        switch outcome {
        case let .inserted(id), let .updated(id), let .skippedDeleted(id):
            return id
        }
    }

    func update(id: UUID, with draft: TransactionDraft, in db: Database) throws {
        try db.execute(
            sql: """
            UPDATE transactions
               SET kind         = ?,
                   status       = ?,
                   amount_minor = ?,
                   currency     = ?,
                   account_id   = ?,
                   category_id  = ?,
                   merchant     = ?,
                   booked_on    = ?,
                   updated_at   = ?,
                   change_seq   = ?
             WHERE id = ?
            """,
            arguments: [
                draft.kind.rawValue,
                draft.status.rawValue,
                draft.amount.minorUnits,
                draft.amount.currency.rawValue,
                draft.accountID.uuidString,
                draft.effectiveCategoryID?.uuidString,
                draft.merchant?.trimmedOrNil,
                draft.bookedOn.iso,
                IngestFunnel.iso8601.format(now()),
                try AppDatabase.nextChangeSeq(db),
                id.uuidString,
            ]
        )
    }

    /// Invariant 3: deletion is a tombstone, never a DELETE. The row keeps occupying
    /// its dedupe slot, which is what stops a re-import resurrecting it (DEC-005).
    func delete(id: UUID, in db: Database) throws {
        let timestamp = IngestFunnel.iso8601.format(now())
        try db.execute(
            sql: """
            UPDATE transactions
               SET deleted_at = ?, updated_at = ?, change_seq = ?
             WHERE id = ? AND deleted_at IS NULL
            """,
            arguments: [timestamp, timestamp, try AppDatabase.nextChangeSeq(db), id.uuidString]
        )
    }

    /// Loads a row back into the shape the form edits.
    func draft(id: UUID, in db: Database) throws -> TransactionDraft? {
        let record = try TransactionRecord.fetchOne(
            db, sql: "SELECT * FROM transactions WHERE id = ?", arguments: [id.uuidString]
        )
        guard let record,
              let kind = TransactionKind(rawValue: record.kind),
              let status = TransactionStatus(rawValue: record.status),
              let currency = Currency(rawValue: record.currency),
              let bookedOn = CivilDate(iso: record.bookedOn),
              let accountID = (record.accountId ?? record.fromAccountId).flatMap(UUID.init(uuidString:))
        else { return nil }

        return TransactionDraft(
            kind: kind,
            amount: Money(minorUnits: record.amountMinor, currency: currency),
            accountID: accountID,
            categoryID: record.categoryId.flatMap(UUID.init(uuidString:)),
            merchant: record.merchant,
            bookedOn: bookedOn,
            status: status
        )
    }
}

nonisolated extension String {
    /// Blank merchant names are stored as NULL rather than "", so "has a merchant"
    /// is one question in SQL instead of two.
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
