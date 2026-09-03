//
//  OverallLimits.swift
//  Budgeter
//
//  DEC-043's whole-period budget: the same effective-dated-range machinery as
//  `CategoryLimits`, minus the category dimension, because there is exactly one of
//  these at a time rather than one per category.
//
//  Kept as its own type rather than `CategoryLimits` with an optional category, so
//  the two never have to agree on what a nil category means at every callsite —
//  here it is unconditionally "the whole period," nowhere is that inferred.
//

import Foundation
import GRDB

nonisolated struct OverallLimits: Sendable {
    var now: @Sendable () -> Date = { Date() }
    var makeID: @Sendable () -> UUID = { UUIDv7.generate() }

    /// Sets the overall limit from `effectiveFrom` onward. Same rules as
    /// `CategoryLimits.setLimit`: revising the date already open amends it in
    /// place, anything else closes the current row and opens a new one, and a date
    /// before a row that has already taken effect is refused outright.
    func setLimit(amount: Money, effectiveFrom: CivilDate, in db: Database) throws {
        let timestamp = IngestFunnel.iso8601.format(now())
        try retireNeverApplied(before: effectiveFrom, timestamp: timestamp, in: db)

        let current = try Row.fetchOne(
            db,
            sql: """
            SELECT id, effective_from
              FROM overall_limits
             WHERE effective_to IS NULL AND deleted_at IS NULL
            """
        )
        if let current {
            if current["effective_from"] as String == effectiveFrom.iso {
                try amend(current, to: amount, timestamp: timestamp, in: db)
                return
            }
            try close(current, at: effectiveFrom, timestamp: timestamp, in: db)
        }

        try db.execute(
            sql: """
            INSERT INTO overall_limits (
                id, amount_minor, currency, effective_from, effective_to,
                created_at, updated_at, deleted_at, change_seq
            ) VALUES (?, ?, ?, ?, NULL, ?, ?, NULL, ?)
            """,
            arguments: [
                makeID().uuidString, amount.minorUnits, amount.currency.rawValue,
                effectiveFrom.iso, timestamp, timestamp, try AppDatabase.nextChangeSeq(db),
            ]
        )
    }

    /// The overall limit in force on `date` — what a period snapshots at its start.
    func limit(on date: CivilDate, in db: Database) throws -> Money? {
        let row = try Row.fetchOne(
            db,
            sql: """
            SELECT amount_minor, currency
              FROM overall_limits
             WHERE deleted_at IS NULL
               AND effective_from <= ?
               AND (effective_to IS NULL OR effective_to > ?)
            """,
            arguments: [date.iso, date.iso]
        )
        guard let row, let currency = Currency(rawValue: row["currency"] as String) else { return nil }
        return Money(minorUnits: row["amount_minor"] as Int64, currency: currency)
    }

    // MARK: - Private

    /// `CategoryLimits.retireNeverApplied` without the category dimension — see the
    /// full reasoning there. Same rule: a limit whose start date has not arrived has
    /// governed no period, so setting one from an earlier date supersedes it rather
    /// than being refused.
    private func retireNeverApplied(before effectiveFrom: CivilDate, timestamp: String, in db: Database) throws {
        let today = CivilDate(localDayOf: now())
        while true {
            let open = try Row.fetchOne(
                db,
                sql: """
                SELECT id, effective_from
                  FROM overall_limits
                 WHERE effective_to IS NULL AND deleted_at IS NULL
                """
            )
            guard let open,
                  (open["effective_from"] as String) > today.iso,
                  (open["effective_from"] as String) > effectiveFrom.iso
            else { return }
            let openFrom: String = open["effective_from"]

            try db.execute(
                sql: """
                UPDATE overall_limits
                   SET deleted_at = ?, updated_at = ?, change_seq = ?
                 WHERE id = ?
                """,
                arguments: [
                    timestamp, timestamp, try AppDatabase.nextChangeSeq(db), open["id"] as String,
                ]
            )
            try db.execute(
                sql: """
                UPDATE overall_limits
                   SET effective_to = NULL, updated_at = ?, change_seq = ?
                 WHERE deleted_at IS NULL AND effective_to = ?
                """,
                arguments: [timestamp, try AppDatabase.nextChangeSeq(db), openFrom]
            )
        }
    }

    private func amend(_ current: Row, to amount: Money, timestamp: String, in db: Database) throws {
        try db.execute(
            sql: """
            UPDATE overall_limits
               SET amount_minor = ?, currency = ?, updated_at = ?, change_seq = ?
             WHERE id = ?
            """,
            arguments: [
                amount.minorUnits, amount.currency.rawValue, timestamp,
                try AppDatabase.nextChangeSeq(db), current["id"] as String,
            ]
        )
    }

    private func close(_ current: Row, at effectiveFrom: CivilDate, timestamp: String, in db: Database) throws {
        let currentFrom: String = current["effective_from"]
        guard effectiveFrom.iso > currentFrom else {
            throw CategoryLimitError.notAfterCurrentLimit(
                effectiveFrom: effectiveFrom.iso, currentFrom: currentFrom
            )
        }
        try db.execute(
            sql: """
            UPDATE overall_limits
               SET effective_to = ?, updated_at = ?, change_seq = ?
             WHERE id = ?
            """,
            arguments: [effectiveFrom.iso, timestamp, try AppDatabase.nextChangeSeq(db), current["id"] as String]
        )
    }
}
