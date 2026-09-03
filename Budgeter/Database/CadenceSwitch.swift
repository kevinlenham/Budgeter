//
//  CadenceSwitch.swift
//  Budgeter
//
//  DEC-008: "the switch takes effect at the next period boundary. On confirmation,
//  show every category with a scaled-and-rounded suggested limit the user can
//  edit."
//
//  DEC-043 changed what "the next boundary" means. Budget periods are calendar-
//  anchored now — weekly is Monday–Sunday, monthly is the calendar month — so the
//  boundary a switch waits for is the next *real* one (`CalendarCadence`), which
//  can fall a few days after the day the current period would otherwise have
//  ended. Rather than invent a short bridging period to cover that gap — exactly
//  what DEC-008 already refused to do — the currently-open period's `ends_on` is
//  extended to reach it. That is not the same move as truncating a period, which
//  DEC-008 rejected for cutting the period the user is *already partway through*
//  short; extending the period still in progress has precedent in this codebase
//  already, in `PeriodGenerator.resnapshot`, which revises the current period's
//  limits while leaving every past one untouched.
//
//  Both halves — `plan` and `apply` — stay separated so the screen physically
//  cannot commit without showing consequences first. Nothing is written until the
//  user confirms.
//

import Foundation
import GRDB

nonisolated enum CadenceSwitchError: Error, Equatable {
    /// No budget schedule to switch away from — onboarding has not run.
    case notConfigured
    /// The current period has not been generated yet, so where the next boundary
    /// falls is unknown. Refused rather than guessed: generation runs on launch,
    /// and a switch computed from a boundary nobody has stored is how two periods
    /// end up overlapping.
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
    /// The first day of the first period on the new cadence — DEC-008's "your new
    /// cadence starts 14 March", and the date every new limit takes effect from.
    /// DEC-043: the next *real* calendar boundary for `to`, not simply the day
    /// after the current period ends.
    var effectiveFrom: CivilDate
    /// The period containing `asOf`, whose `ends_on` `apply` extends to
    /// `effectiveFrom.addingDays(-1)` if there is a gap to bridge.
    var currentPeriodID: UUID
    var overallCurrent: Money?
    var overallSuggested: Money?
    var lines: [CadenceSwitchLine]
}

nonisolated struct CadenceSwitch: Sendable {
    var now: @Sendable () -> Date = { Date() }
    var makeID: @Sendable () -> UUID = { UUIDv7.generate() }

    /// Works out what switching to `cadence` would do. Writes nothing.
    func plan(to cadence: Cadence, asOf today: CivilDate, in db: Database) throws -> CadenceSwitchPlan {
        guard let schedule = try BudgetSettingsStore().load(db).schedule else {
            throw CadenceSwitchError.notConfigured
        }
        guard let current = try Queries.period(containing: today, in: db),
              let dates = current.dates,
              let periodID = UUID(uuidString: current.id)
        else {
            throw CadenceSwitchError.noCurrentPeriod
        }

        // DEC-043: the next date `cadence` may naturally start on, no earlier than
        // the day after the current period ends. A switch to fortnightly never
        // asks which week of the cycle it lands in — it always starts a fresh
        // "week 1", so there is no phase question here the way onboarding has one.
        let effectiveFrom = CalendarCadence.nextNaturalBoundary(
            for: cadence, onOrAfter: dates.end.addingDays(1)
        )

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
            effectiveFrom: effectiveFrom,
            currentPeriodID: periodID,
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
    /// The switch itself does **not** take effect here (DEC-043): it is recorded
    /// as pending, and `PeriodGenerator` promotes it once `plan.effectiveFrom`
    /// actually arrives. What does happen now is extending the currently-open
    /// period to reach that date, so no day is ever left without one.
    ///
    /// The pay schedule is deliberately untouched (DEC-036): "a user switching from
    /// fortnightly to monthly budgeting has not changed jobs."
    func apply(_ plan: CadenceSwitchPlan, overallLimit: Money?, limits: [UUID: Money], in db: Database) throws {
        let timestamp = IngestFunnel.iso8601.format(now())
        try db.execute(
            sql: """
            UPDATE periods SET ends_on = ?, updated_at = ?, change_seq = ? WHERE id = ?
            """,
            arguments: [
                plan.effectiveFrom.addingDays(-1).iso, timestamp,
                try AppDatabase.nextChangeSeq(db), plan.currentPeriodID.uuidString,
            ]
        )

        var settings = try BudgetSettingsStore(now: now).load(db)
        settings.pendingSchedule = PeriodSchedule(anchor: plan.effectiveFrom, cadence: plan.to)
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
