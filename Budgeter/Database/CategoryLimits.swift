//
//  CategoryLimits.swift
//  Budgeter
//
//  DEC-008 made limits effective-dated rows rather than a single current value,
//  because "a past period must display the limit that applied *then*, not today's.
//  Without this, editing a limit silently rewrites history."
//
//  That only holds if there is one write path that maintains the ranges. Setting a
//  limit is therefore never an UPDATE of the amount — it closes the row in force and
//  opens a new one, so the old figure survives for the periods that snapshotted it.
//

import Foundation
import GRDB

nonisolated enum CategoryLimitError: Error, Equatable {
    /// A limit was backdated before the one it would replace. Ranges are closed
    /// forward only (DEC-007's governing principle), so this is refused rather
    /// than resolved by guessing which row should win.
    case notAfterCurrentLimit(effectiveFrom: String, currentFrom: String)
}

nonisolated struct CategoryLimits: Sendable {
    var now: @Sendable () -> Date = { Date() }
    var makeID: @Sendable () -> UUID = { UUIDv7.generate() }

    /// Sets a category's limit from `effectiveFrom` onward.
    ///
    /// `effectiveFrom` is a boundary date, not today: DEC-008 has a cadence switch
    /// take effect at the next period boundary, so the caller passes that date and
    /// the change simply sits in the table until the boundary arrives. Nothing
    /// special happens on the day — the period generated then reads the row that
    /// has become current, which is the whole point of storing ranges.
    func setLimit(
        categoryID: UUID,
        amount: Money,
        effectiveFrom: CivilDate,
        in db: Database
    ) throws {
        let timestamp = IngestFunnel.iso8601.format(now())

        let current = try Row.fetchOne(
            db,
            sql: """
            SELECT id, effective_from
              FROM category_limits
             WHERE category_id = ?
               AND effective_to IS NULL
               AND deleted_at IS NULL
            """,
            arguments: [categoryID.uuidString]
        )
        if let current {
            // Setting a limit twice from the same date is one decision revised, not
            // two decisions in sequence: closing a zero-length range would leave a
            // row no period could ever snapshot, so the open row is amended instead.
            if current["effective_from"] as String == effectiveFrom.iso {
                try amend(current, to: amount, timestamp: timestamp, in: db)
                return
            }
            try close(current, at: effectiveFrom, timestamp: timestamp, in: db)
        }

        try db.execute(
            sql: """
            INSERT INTO category_limits (
                id, category_id, amount_minor, currency,
                effective_from, effective_to,
                created_at, updated_at, deleted_at, change_seq
            ) VALUES (?, ?, ?, ?, ?, NULL, ?, ?, NULL, ?)
            """,
            arguments: [
                makeID().uuidString,
                categoryID.uuidString,
                amount.minorUnits,
                amount.currency.rawValue,
                effectiveFrom.iso,
                timestamp,
                timestamp,
                try AppDatabase.nextChangeSeq(db),
            ]
        )
    }

    /// The limit in force on `date`, which is what a period snapshots at its start.
    func limit(categoryID: UUID, on date: CivilDate, in db: Database) throws -> Money? {
        let row = try Row.fetchOne(
            db,
            sql: """
            SELECT amount_minor, currency
              FROM category_limits
             WHERE category_id = ?
               AND deleted_at IS NULL
               AND effective_from <= ?
               AND (effective_to IS NULL OR effective_to > ?)
            """,
            arguments: [categoryID.uuidString, date.iso, date.iso]
        )
        guard let row, let currency = Currency(rawValue: row["currency"] as String) else { return nil }
        return Money(minorUnits: row["amount_minor"] as Int64, currency: currency)
    }

    // MARK: - Private

    /// Revises the open limit in place, for a change effective from the date it
    /// already starts on.
    private func amend(_ current: Row, to amount: Money, timestamp: String, in db: Database) throws {
        try db.execute(
            sql: """
            UPDATE category_limits
               SET amount_minor = ?, currency = ?, updated_at = ?, change_seq = ?
             WHERE id = ?
            """,
            arguments: [
                amount.minorUnits,
                amount.currency.rawValue,
                timestamp,
                try AppDatabase.nextChangeSeq(db),
                current["id"] as String,
            ]
        )
    }

    /// Closes the limit currently in force so the new one can open on the same day.
    ///
    /// The range is half-open, so the closing date and the new row's opening date
    /// are the same value: no gap, no overlap, and no day owned by two rows.
    private func close(_ current: Row, at effectiveFrom: CivilDate, timestamp: String, in db: Database) throws {
        let currentFrom: String = current["effective_from"]
        guard effectiveFrom.iso > currentFrom else {
            throw CategoryLimitError.notAfterCurrentLimit(
                effectiveFrom: effectiveFrom.iso,
                currentFrom: currentFrom
            )
        }
        try db.execute(
            sql: """
            UPDATE category_limits
               SET effective_to = ?, updated_at = ?, change_seq = ?
             WHERE id = ?
            """,
            arguments: [
                effectiveFrom.iso,
                timestamp,
                try AppDatabase.nextChangeSeq(db),
                current["id"] as String,
            ]
        )
    }
}
