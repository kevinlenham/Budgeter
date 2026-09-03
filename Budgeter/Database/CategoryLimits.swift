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
    ///
    /// Only ever a row that has genuinely already applied. A row whose start date
    /// is still in the future has governed no period, and `setLimit` retires it
    /// rather than reporting this — see `retireNeverApplied`.
    case notAfterCurrentLimit(effectiveFrom: String, currentFrom: String)
}

nonisolated struct CategoryLimits: Sendable {
    var now: @Sendable () -> Date = { Date() }
    var makeID: @Sendable () -> UUID = { UUIDv7.generate() }

    /// Sets a category's limit from `effectiveFrom` onward.
    ///
    /// `effectiveFrom` is a boundary date, not necessarily today: the Budget tab's
    /// editors pass the current period's start, and `CadenceSwitch` passes the day
    /// the new cadence begins (DEC-043: today). The period that starts on or after
    /// it reads the row that has become current, which is the whole point of
    /// storing ranges rather than a single value.
    func setLimit(
        categoryID: UUID,
        amount: Money,
        effectiveFrom: CivilDate,
        in db: Database
    ) throws {
        let timestamp = IngestFunnel.iso8601.format(now())
        try retireNeverApplied(categoryID: categoryID, before: effectiveFrom, timestamp: timestamp, in: db)

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

    /// Retires an open limit that starts *after* `effectiveFrom`, and reopens
    /// whichever row it closed, so the ordinary forward-only path below is reached
    /// with a genuinely current row in front of it.
    ///
    /// DEC-008's forward-only rule protects **history**: a past period must keep
    /// showing the limit that applied then. A row whose `effective_from` has not
    /// arrived yet has applied to nothing: no period has started under it, so none
    /// snapshotted it, and superseding it rewrites no history at all.
    /// Refusing it was the strictly wrong reading of the rule, and it was refusing
    /// a whole `CadenceSwitch.apply` transaction: a switch that reported
    /// `notAfterCurrentLimit` and rolled back everything, which on screen is a
    /// Switch button that changes nothing.
    ///
    /// Reachable because DEC-043's first implementation deferred a cadence switch
    /// to the next calendar boundary and wrote its new limits effective from that
    /// future date. The revision made switches instant and deleted the machinery
    /// that would have promoted those rows, but a database written by the earlier
    /// build still holds them, dated ahead of today, blocking every subsequent
    /// switch. Healed on use rather than by a migration, for the reason
    /// `Migration006` heals rather than asks for a reinstall — and because "a limit
    /// that never took effect does not outrank one that is being set now" is a rule
    /// worth stating once here, not a one-off repair.
    ///
    /// Tombstoned, never deleted (invariant 3), and the previous row is reopened
    /// only after the tombstone lands so `idx_category_limits_open` never sees two
    /// open rows for one category. Loops because more than one row can be stranded
    /// ahead of today; each pass retires the open row and reopens one starting
    /// strictly earlier, so it always terminates.
    private func retireNeverApplied(
        categoryID: UUID, before effectiveFrom: CivilDate, timestamp: String, in db: Database
    ) throws {
        // Strictly after today, not merely after `effectiveFrom`. A row starting
        // today is in force today — `limit(categoryID:on:)` returns it and the
        // Budget tab shows it — so setting a limit from an earlier date is real
        // backdating and still belongs to `close`'s refusal. Only a start date that
        // has not arrived describes a decision nothing has acted on.
        let today = CivilDate(localDayOf: now())
        while true {
            let open = try Row.fetchOne(
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
            guard let open,
                  (open["effective_from"] as String) > today.iso,
                  (open["effective_from"] as String) > effectiveFrom.iso
            else { return }
            let openFrom: String = open["effective_from"]

            try db.execute(
                sql: """
                UPDATE category_limits
                   SET deleted_at = ?, updated_at = ?, change_seq = ?
                 WHERE id = ?
                """,
                arguments: [
                    timestamp, timestamp, try AppDatabase.nextChangeSeq(db), open["id"] as String,
                ]
            )
            // The row this one closed, if there was one: ranges are half-open, so it
            // was closed at exactly the retired row's start date. At most one row can
            // match, because the ranges for a category never overlap.
            try db.execute(
                sql: """
                UPDATE category_limits
                   SET effective_to = NULL, updated_at = ?, change_seq = ?
                 WHERE category_id = ? AND deleted_at IS NULL AND effective_to = ?
                """,
                arguments: [
                    timestamp, try AppDatabase.nextChangeSeq(db), categoryID.uuidString, openFrom,
                ]
            )
        }
    }

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
