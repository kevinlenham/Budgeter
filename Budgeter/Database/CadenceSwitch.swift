//
//  CadenceSwitch.swift
//  Budgeter
//
//  DEC-008 asked for one thing from a cadence switch: "show every category with a
//  scaled-and-rounded suggested limit the user can edit." DEC-043 changed *when*
//  it takes effect — immediately, not at a future boundary — after finding in
//  practice that waiting (up to three weeks, for a switch to monthly) felt broken
//  rather than careful.
//
//  A switch now truncates the currently-open period to end yesterday and starts a
//  fresh one today under the new cadence, with its own budget — the current
//  period is a decision still being made, and DEC-043 treats "the day it ends" as
//  part of that decision the same way `PeriodGenerator.resnapshot` already treats
//  its limits. Every period before it is untouched: DEC-007's governing principle
//  still holds, just measured from today backward instead of from some future
//  date forward.
//
//  `plan` and `apply` stay separated so the screen physically cannot commit
//  without showing consequences first. Nothing is written until the user confirms.
//

import Foundation
import GRDB

nonisolated enum CadenceSwitchError: Error, Equatable {
    /// No budget schedule to switch away from — onboarding has not run.
    case notConfigured
    /// The current period has not been generated yet, so there is nothing to
    /// truncate. Refused rather than guessed: generation runs on launch, and a
    /// switch computed from a period nobody has stored is how two periods end up
    /// overlapping.
    case noCurrentPeriod
}

/// One category's line on the confirmation screen.
nonisolated struct CadenceSwitchLine: Equatable, Sendable, Identifiable {
    var categoryID: UUID
    var categoryName: String
    /// What the limit is under the old cadence, or nil if the category has none.
    var currentLimit: Money?
    /// What it would become, scaled and rounded (`LimitScaling`). Nil when there is
    /// nothing to scale, or when the arithmetic overflowed — in which case the
    /// screen shows an empty field and the user types a figure themselves.
    var suggestedLimit: Money?

    var id: UUID {
        categoryID
    }
}

/// A proposed switch, with everything the confirmation screen needs and nothing
/// written yet.
nonisolated struct CadenceSwitchPlan: Equatable, Sendable {
    var from: Cadence
    var to: Cadence
    /// Always today (DEC-043) — the day the new period starts and every new limit
    /// takes effect from.
    var effectiveFrom: CivilDate
    /// The period containing `effectiveFrom`, whose `ends_on` `apply` truncates to
    /// the day before it.
    var currentPeriodID: UUID
    /// When that period itself started. If it started *today*, there is nothing to
    /// truncate — `apply` retires the row instead of writing an invalid range.
    var currentPeriodStartsOn: CivilDate
    var overallCurrent: Money?
    var overallSuggested: Money?
    var lines: [CadenceSwitchLine]
}

nonisolated struct CadenceSwitch: Sendable {
    var now: @Sendable () -> Date = { Date() }
    var makeID: @Sendable () -> UUID = { UUIDv7.generate() }

    /// Works out what switching to `cadence` today would do. Writes nothing.
    func plan(to cadence: Cadence, asOf today: CivilDate, in db: Database) throws -> CadenceSwitchPlan {
        guard let schedule = try BudgetSettingsStore().load(db).schedule else {
            throw CadenceSwitchError.notConfigured
        }
        guard let current = try Queries.period(containing: today, in: db),
              let periodID = UUID(uuidString: current.id),
              let currentStartsOn = CivilDate(iso: current.startsOn)
        else {
            throw CadenceSwitchError.noCurrentPeriod
        }

        let overallCurrent = try OverallLimits().limit(on: today, in: db)

        let categoryLimits = CategoryLimits(now: now, makeID: makeID)
        let lines = try CategoryStore().all(in: db).compactMap { category -> CadenceSwitchLine? in
            guard let id = UUID(uuidString: category.id) else { return nil }
            let currentLimit = try categoryLimits.limit(categoryID: id, on: today, in: db)
            return CadenceSwitchLine(
                categoryID: id,
                categoryName: category.name,
                currentLimit: currentLimit,
                suggestedLimit: currentLimit.flatMap {
                    LimitScaling.suggested(limit: $0, from: schedule.cadence, to: cadence)
                }
            )
        }

        return CadenceSwitchPlan(
            from: schedule.cadence,
            to: cadence,
            effectiveFrom: today,
            currentPeriodID: periodID,
            currentPeriodStartsOn: currentStartsOn,
            overallCurrent: overallCurrent,
            overallSuggested: overallCurrent.flatMap {
                LimitScaling.suggested(limit: $0, from: schedule.cadence, to: cadence)
            },
            lines: lines
        )
    }

    /// Commits a plan, with whatever limits the user settled on.
    ///
    /// `limits` is keyed by category and holds the figure shown on the confirmation
    /// screen, edited or not; `overallLimit` is that same figure for the whole-
    /// period budget. Either being absent/nil means "leave that limit as it was" —
    /// the right behaviour for something the user had not budgeted, and why the
    /// screen sends back everything it displayed rather than only what changed.
    ///
    /// Truncates the current period to end yesterday, switches the active
    /// schedule to the new cadence anchored on today, and writes the new limits
    /// effective from today. `PeriodGenerator` picks up from there on its next
    /// call — the day after the truncated period ends is today, and today is
    /// exactly where the new schedule's index 0 starts.
    ///
    /// If the current period itself started today — a second switch on the same
    /// day, or the very first period of a fresh install — there is no "yesterday"
    /// within it to truncate to, and forcing one would write `ends_on < starts_on`,
    /// which the schema's own CHECK refuses. The row is retired instead: invariant
    /// 3's tombstone, not a special case. Nothing it might have snapshotted is lost
    /// — any spending already logged today is dated, not linked to a period id, so
    /// it is picked up automatically once the new period exists to claim that date.
    ///
    /// The pay schedule is deliberately untouched (DEC-036): "a user switching from
    /// fortnightly to monthly budgeting has not changed jobs."
    func apply(_ plan: CadenceSwitchPlan, overallLimit: Money?, limits: [UUID: Money], in db: Database) throws {
        let timestamp = IngestFunnel.iso8601.format(now())
        if plan.currentPeriodStartsOn == plan.effectiveFrom {
            try db.execute(
                sql: "UPDATE periods SET deleted_at = ?, updated_at = ?, change_seq = ? WHERE id = ?",
                arguments: [
                    timestamp, timestamp,
                    try AppDatabase.nextChangeSeq(db), plan.currentPeriodID.uuidString,
                ]
            )
        } else {
            try db.execute(
                sql: "UPDATE periods SET ends_on = ?, updated_at = ?, change_seq = ? WHERE id = ?",
                arguments: [
                    plan.effectiveFrom.addingDays(-1).iso, timestamp,
                    try AppDatabase.nextChangeSeq(db), plan.currentPeriodID.uuidString,
                ]
            )
        }

        var settings = try BudgetSettingsStore(now: now).load(db)
        settings.schedule = PeriodSchedule(anchor: plan.effectiveFrom, cadence: plan.to)
        try BudgetSettingsStore(now: now).save(settings, in: db)

        if let overallLimit {
            try OverallLimits(now: now, makeID: makeID).setLimit(
                amount: overallLimit, effectiveFrom: plan.effectiveFrom, in: db
            )
        }

        let store = CategoryLimits(now: now, makeID: makeID)
        for line in plan.lines {
            guard let amount = limits[line.categoryID] else { continue }
            try store.setLimit(
                categoryID: line.categoryID,
                amount: amount,
                effectiveFrom: plan.effectiveFrom,
                in: db
            )
        }
    }
}
