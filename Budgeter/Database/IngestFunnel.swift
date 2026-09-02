//
//  IngestFunnel.swift
//  Budgeter
//
//  Rule 3: all ingestion goes through here. There is no other write path for
//  ingested data.
//
//  This is what makes invariant 4 structural rather than conventional. The funnel
//  implements idempotency; the unique index behind it (DEC-005) only *detects*
//  violations. A unique index alone would make re-import fail rather than no-op —
//  the no-op has to be written, and this is where it is written.
//

import Foundation
import GRDB

nonisolated enum TransactionKind: String, Codable, Sendable, CaseIterable {
    case expense
    case refund
    case transfer
    case income
}

nonisolated enum TransactionStatus: String, Codable, Sendable, CaseIterable {
    case draft
    case confirmed
}

/// Where a row came from. Determines how its `dedupe_key` is built (DEC-005).
nonisolated enum TransactionSource: String, Codable, Sendable, CaseIterable {
    case manual
    case wallet
    case csv
    case bank
}

/// A transaction on its way in, before it has an identity in our database.
nonisolated struct IngestedTransaction: Sendable {
    var kind: TransactionKind
    var status: TransactionStatus
    var amount: Money

    var accountID: UUID?
    var fromAccountID: UUID?
    var toAccountID: UUID?
    var categoryID: UUID?

    var merchant: String?
    /// Local calendar date, `YYYY-MM-DD`. Decides period membership (DEC-009).
    var bookedOn: String
    /// UTC instant, for intra-day ordering and dedupe windows (DEC-009).
    var occurredAt: Date

    var source: TransactionSource
    /// Stable per source: a provider id, a row hash, a Wallet bucket hash, or — for
    /// manual entry — a fresh UUID, so two identical manual entries never collide.
    /// Two identical manual entries are two real purchases (DEC-005).
    var dedupeKey: String

    init(
        kind: TransactionKind,
        status: TransactionStatus,
        amount: Money,
        accountID: UUID? = nil,
        fromAccountID: UUID? = nil,
        toAccountID: UUID? = nil,
        categoryID: UUID? = nil,
        merchant: String? = nil,
        bookedOn: String,
        occurredAt: Date,
        source: TransactionSource,
        dedupeKey: String
    ) {
        self.kind = kind
        self.status = status
        self.amount = amount
        self.accountID = accountID
        self.fromAccountID = fromAccountID
        self.toAccountID = toAccountID
        self.categoryID = categoryID
        self.merchant = merchant
        self.bookedOn = bookedOn
        self.occurredAt = occurredAt
        self.source = source
        self.dedupeKey = dedupeKey
    }
}

/// What the funnel did, so an import can report "12 imported, 3 previously deleted
/// and skipped" rather than leaving the user to wonder (DEC-005).
nonisolated enum IngestOutcome: Equatable, Sendable {
    case inserted(id: UUID)
    /// Already present and live: the existing row was updated in place.
    case updated(id: UUID)
    /// Already present but soft-deleted. Deliberately *not* resurrected — the
    /// user's deletion sticks across re-import.
    case skippedDeleted(id: UUID)
}

nonisolated struct IngestFunnel: Sendable {
    /// The clock, injected so tests are not at the mercy of the wall clock.
    var now: @Sendable () -> Date = { Date() }
    var makeID: @Sendable () -> UUID = { UUIDv7.generate() }

    /// The single write path. Idempotent by construction: re-running an import
    /// inserts nothing new.
    @discardableResult
    func ingest(_ incoming: IngestedTransaction, into db: Database) throws -> IngestOutcome {
        let identityAccount = incoming.accountID ?? incoming.fromAccountID

        let existing = try Row.fetchOne(
            db,
            sql: """
            SELECT id, deleted_at
              FROM transactions
             WHERE COALESCE(account_id, from_account_id) IS ?
               AND source = ?
               AND dedupe_key = ?
            """,
            arguments: [identityAccount?.uuidString, incoming.source.rawValue, incoming.dedupeKey]
        )

        if let existing {
            let id = UUID(uuidString: existing["id"]) ?? UUID()
            let isDeleted: String? = existing["deleted_at"]
            guard isDeleted == nil else {
                return .skippedDeleted(id: id)
            }
            try update(id: id, with: incoming, in: db)
            return .updated(id: id)
        }

        let id = makeID()
        try insert(id: id, incoming, in: db)
        return .inserted(id: id)
    }

    // MARK: - Private

    private func insert(id: UUID, _ incoming: IngestedTransaction, in db: Database) throws {
        let timestamp = Self.iso8601.format(now())
        try db.execute(
            sql: """
            INSERT INTO transactions (
                id, kind, status, amount_minor, currency,
                account_id, from_account_id, to_account_id, category_id,
                merchant, booked_on, occurred_at,
                source, dedupe_key,
                created_at, updated_at, deleted_at, change_seq
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?)
            """,
            arguments: [
                id.uuidString,
                incoming.kind.rawValue,
                incoming.status.rawValue,
                incoming.amount.minorUnits,
                incoming.amount.currency.rawValue,
                incoming.accountID?.uuidString,
                incoming.fromAccountID?.uuidString,
                incoming.toAccountID?.uuidString,
                incoming.categoryID?.uuidString,
                incoming.merchant,
                incoming.bookedOn,
                Self.iso8601.format(incoming.occurredAt),
                incoming.source.rawValue,
                incoming.dedupeKey,
                timestamp,
                timestamp,
                try AppDatabase.nextChangeSeq(db),
            ]
        )
    }

    /// Updates the mutable fields of an existing row.
    ///
    /// Kind, account and source are identity, not data — a row that changed those
    /// would be a different transaction — so they are not touched here. Per-field
    /// merge precedence across *sources* is DEC-019's job in Sprint 8, not this
    /// function's: here a later observation from the same source simply wins.
    private func update(id: UUID, with incoming: IngestedTransaction, in db: Database) throws {
        try db.execute(
            sql: """
            UPDATE transactions
               SET amount_minor = ?,
                   currency     = ?,
                   category_id  = ?,
                   merchant     = COALESCE(?, merchant),
                   booked_on    = ?,
                   occurred_at  = ?,
                   status       = ?,
                   updated_at   = ?,
                   change_seq   = ?
             WHERE id = ?
            """,
            arguments: [
                incoming.amount.minorUnits,
                incoming.amount.currency.rawValue,
                incoming.categoryID?.uuidString,
                incoming.merchant,
                incoming.bookedOn,
                Self.iso8601.format(incoming.occurredAt),
                incoming.status.rawValue,
                Self.iso8601.format(now()),
                try AppDatabase.nextChangeSeq(db),
                id.uuidString,
            ]
        )
    }

    /// A value type rather than `ISO8601DateFormatter`, which is a mutable class and
    /// so cannot be shared safely — Swift 6 rejects it outright.
    static let iso8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
}
