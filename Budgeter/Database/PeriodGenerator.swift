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
//  All of the arithmetic lives in `PeriodSchedule` and `CalendarCadence`, which know
//  nothing about SQLite. This type only decides *which* indices are missing and
//  writes them.
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
        return try generate(using: schedule, through: today, in: db)
    }

    /// Rebuilds a period's limit snapshot from the limits currently in force —
    /// both the per-category ones and DEC-043's overall figure.
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
        try snapshotCategoryLimits(periodID: id, startsOn: startsOn, in: db)
        try snapshotOverallLimit(periodID: id, startsOn: startsOn, in: db)
    }

    // MARK: - Private

    private func generate(
        using schedule: PeriodSchedule, through today: CivilDate, in db: Database
    ) throws -> [BudgetPeriod] {
        let firstIndex = try firstMissingIndex(for: schedule, today: today, in: db)
        let periods = schedule.periods(fromIndex: firstIndex, through: today)
        for period in periods {
            try insert(period, schedule: schedule, in: db)
        }
        return periods
    }

    /// Where to resume.
    ///
    /// With periods already stored, the index `schedule` assigns to the day right
    /// after the latest one ends. With none, the period containing today — *not*
    /// the anchor's own period. DEC-007 asks for the user's **next** payday, so at
    /// onboarding the anchor is in the future and today sits one period behind it;
    /// starting at the anchor would leave the user with no current period until
    /// their next payday arrived.
    ///
    /// Deliberately keyed off the day after the last period *ends*, not off the
    /// last period's own start reinterpreted under `schedule`. Those agree as long
    /// as `schedule` never changes, but after a DEC-043 cadence switch `schedule`'s
    /// anchor has no relationship to a period stored under the old one — indexing
    /// the old start under the new schedule can land on an index whose period
    /// overlaps the row already on disk, which the `trg_periods_no_overlap` trigger
    /// then rejects. The boundary date is schedule-agnostic: `CadenceSwitch.apply`
    /// truncates the old period to end the day before the new schedule's anchor,
    /// precisely so the new schedule's first period starts there and nowhere else.
    private func firstMissingIndex(for schedule: PeriodSchedule, today: CivilDate, in db: Database) throws -> Int {
        let latest = try String.fetchOne(db, sql: """
        SELECT ends_on
          FROM periods
         WHERE deleted_at IS NULL
         ORDER BY starts_on DESC
         LIMIT 1
        """)
        guard let latest else {
            return schedule.index(containing: today)
        }
        guard let end = CivilDate(iso: latest) else {
            throw BudgetSettingsError.malformedStoredValue(latest)
        }
        return schedule.index(containing: end.addingDays(1))
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
        try snapshotCategoryLimits(periodID: id, startsOn: period.startsOn, in: db)
        try snapshotOverallLimit(periodID: id, startsOn: period.startsOn, in: db)
    }

    /// DEC-008: each period snapshots the limits in force at its start, so a past
    /// period keeps showing the limit that applied *then*. Editing a limit today
    /// must not rewrite what the user was budgeting to in March.
    ///
    /// One row per limit, each with its own id and change_seq, so the snapshot is
    /// ordinary data a future sync can carry rather than a special case.
    private func snapshotCategoryLimits(periodID: UUID, startsOn: CivilDate, in db: Database) throws {
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

    /// DEC-043's whole-period snapshot: at most one figure, so it is written
    /// directly onto the period row rather than into a table sized for many.
    /// Left `NULL` when there is nothing in force, matching how an unbudgeted
    /// category simply has no row in `period_limits`.
    private func snapshotOverallLimit(periodID: UUID, startsOn: CivilDate, in db: Database) throws {
        let limit = try OverallLimits().limit(on: startsOn, in: db)
        try db.execute(
            sql: """
            UPDATE periods SET overall_limit_minor = ?, overall_limit_currency = ? WHERE id = ?
            """,
            arguments: [limit?.minorUnits, limit?.currency.rawValue, periodID.uuidString]
        )
    }
}
