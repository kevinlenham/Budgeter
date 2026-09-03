//
//  PeriodGenerator.swift
//  Budgeter
//
//  DEC-009 chose lazy generation: `generatePeriods(upTo:)` fills the gap between the
//  last stored period and today, is called on launch and before any period query,
//  and is idempotent — so calling it needlessly costs one indexed read. The rejected
//  alternative was eager background generation via `BGTaskScheduler`, which iOS runs
//  when it chooses and is a well-known source of "why didn't this fire".
//
//  All of the arithmetic lives in `PeriodSchedule`, which knows nothing about
//  SQLite. This type only decides *which* indices are missing and writes them.
//

import Foundation
import GRDB

nonisolated struct PeriodGenerator: Sendable {
    var now: @Sendable () -> Date = { Date() }
    var makeID: @Sendable () -> UUID = { UUIDv7.generate() }
    var settingsStore = BudgetSettingsStore()

    /// Generates every period missing between the last stored one and `today`,
    /// snapshotting the limits in force at each one's start.
    ///
    /// Returns what it created, so a caller can tell "nothing to do" from "filled in
    /// eight weeks" without a second query. Running it twice returns `[]` the second
    /// time — DEC-009's idempotence, which the trigger on `periods` also enforces
    /// independently.
    @discardableResult
    func generate(through today: CivilDate, in db: Database) throws -> [BudgetPeriod] {
        guard let schedule = try settingsStore.load(db).schedule else {
            throw BudgetSettingsError.notConfigured
        }

        let firstIndex = try firstMissingIndex(for: schedule, today: today, in: db)
        let periods = schedule.periods(fromIndex: firstIndex, through: today)
        for period in periods {
            try insert(period, schedule: schedule, in: db)
        }
        return periods
    }

    /// Rebuilds a period's limit snapshot from the limits currently in force.
    ///
    /// Only ever for the period in progress. DEC-008's rule is that a *past* period
    /// keeps the limit that applied then — not that a user who sets their grocery
    /// budget today should watch this period ignore it until the next one starts.
    /// Editing a limit in the current period revises the current period; every
    /// period already behind it is untouched.
    func resnapshot(period: PeriodRecord, in db: Database) throws {
        guard let startsOn = CivilDate(iso: period.startsOn),
              let id = UUID(uuidString: period.id)
        else { throw BudgetSettingsError.malformedStoredValue(period.startsOn) }

        try db.execute(sql: "DELETE FROM period_limits WHERE period_id = ?", arguments: [period.id])
        try snapshotLimits(periodID: id, startsOn: startsOn, in: db)
    }

    // MARK: - Private

    /// Where to resume.
    ///
    /// With periods already stored, the next index after the latest one. With none,
    /// the period containing today — *not* the anchor's own period. DEC-007 asks for
    /// the user's **next** payday, so at onboarding the anchor is in the future and
    /// today sits one period behind it; starting at the anchor would leave the user
    /// with no current period until their next payday arrived.
    private func firstMissingIndex(for schedule: PeriodSchedule, today: CivilDate, in db: Database) throws -> Int {
        let latest = try String.fetchOne(db, sql: """
        SELECT starts_on
          FROM periods
         WHERE deleted_at IS NULL
         ORDER BY starts_on DESC
         LIMIT 1
        """)
        guard let latest else {
            return schedule.index(containing: today)
        }
        guard let start = CivilDate(iso: latest) else {
            throw BudgetSettingsError.malformedStoredValue(latest)
        }
        return schedule.index(containing: start) + 1
    }

    private func insert(_ period: BudgetPeriod, schedule: PeriodSchedule, in db: Database) throws {
        let id = makeID()
        let timestamp = IngestFunnel.iso8601.format(now())
        try db.execute(
            sql: """
            INSERT INTO periods (
                id, starts_on, ends_on, cadence, anchor_on,
                created_at, updated_at, deleted_at, change_seq
            ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?)
            """,
            arguments: [
                id.uuidString,
                period.startsOn.iso,
                period.endsOn.iso,
                schedule.cadence.rawValue,
                schedule.anchor.iso,
                timestamp,
                timestamp,
                try AppDatabase.nextChangeSeq(db),
            ]
        )
        try snapshotLimits(periodID: id, startsOn: period.startsOn, in: db)
    }

    /// DEC-008: each period snapshots the limits in force at its start, so a past
    /// period keeps showing the limit that applied *then*. Editing a limit today
    /// must not rewrite what the user was budgeting to in March.
    ///
    /// One row per limit, each with its own id and change_seq, so the snapshot is
    /// ordinary data a future sync can carry rather than a special case.
    private func snapshotLimits(periodID: UUID, startsOn: CivilDate, in db: Database) throws {
        let inForce = try Row.fetchAll(
            db,
            sql: """
            SELECT category_id, amount_minor, currency
              FROM category_limits
             WHERE deleted_at IS NULL
               AND effective_from <= ?
               AND (effective_to IS NULL OR effective_to > ?)
            """,
            arguments: [startsOn.iso, startsOn.iso]
        )

        let timestamp = IngestFunnel.iso8601.format(now())
        for limit in inForce {
            try db.execute(
                sql: """
                INSERT INTO period_limits (
                    id, period_id, category_id, amount_minor, currency,
                    created_at, updated_at, deleted_at, change_seq
                ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?)
                """,
                arguments: [
                    makeID().uuidString,
                    periodID.uuidString,
                    limit["category_id"] as String,
                    limit["amount_minor"] as Int64,
                    limit["currency"] as String,
                    timestamp,
                    timestamp,
                    try AppDatabase.nextChangeSeq(db),
                ]
            )
        }
    }
}
