//
//  CadenceSwitch.swift
//  Budgeter
//
//  DEC-008: "the switch takes effect at the next period boundary. On confirmation,
//  show every category with a scaled-and-rounded suggested limit the user can
//  edit."
//
//  Both halves matter, and they are separated here into `plan` and `apply` so the
//  screen physically cannot do the second without showing the first. Nothing is
//  written until the user confirms.
//
//  The mechanism is DEC-007's governing principle rather than a special case:
//  *periods are immutable, append-only records, and cadence or anchor changes are
//  effective-dated forward and never regenerate history.* A switch is therefore not
//  a migration of anything — it is a new `(anchor, cadence)` whose anchor is the
//  next boundary. Every period already stored keeps the cadence and anchor recorded
//  on its own row, `PeriodGenerator` resumes at the first index the new schedule has
//  not covered, and nothing in the past moves. Partial periods never exist, so
//  "spent this period" never jumps for invisible reasons.
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
    var effectiveFrom: CivilDate
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
              let dates = current.dates
        else {
            throw CadenceSwitchError.noCurrentPeriod
        }

        // The day after the period the user is in ends. Taken from the stored row
        // rather than recomputed from the schedule, so the boundary the switch
        // hangs off is the same one the budget screen is already showing.
        let effectiveFrom = dates.end.addingDays(1)

        let limits = CategoryLimits(now: now, makeID: makeID)
        let lines = try CategoryStore().all(in: db).compactMap { category -> CadenceSwitchLine? in
            guard let id = UUID(uuidString: category.id) else { return nil }
            let currentLimit = try limits.limit(categoryID: id, on: today, in: db)
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
            lines: lines
        )
    }

    /// Commits a plan, with whatever limits the user settled on.
    ///
    /// `limits` is keyed by category and holds the figure shown on the confirmation
    /// screen, edited or not. A category absent from it keeps whatever limit it
    /// already had — which is the right behaviour for a category the user had not
    /// budgeted, and is why the screen sends back everything it displayed.
    ///
    /// The pay schedule is deliberately untouched (DEC-036): "a user switching from
    /// fortnightly to monthly budgeting has not changed jobs."
    func apply(_ plan: CadenceSwitchPlan, limits: [UUID: Money], in db: Database) throws {
        var settings = try BudgetSettingsStore(now: now).load(db)
        settings.schedule = PeriodSchedule(anchor: plan.effectiveFrom, cadence: plan.to)
        try BudgetSettingsStore(now: now).save(settings, in: db)

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
