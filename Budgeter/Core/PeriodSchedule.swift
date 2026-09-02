//
//  PeriodSchedule.swift
//  Budgeter
//
//  DEC-009's `generatePeriods(upTo:)`, and DEC-036's `payDates(from:upTo:)`, are the
//  same arithmetic: given an anchor date and a cadence, which dates does the cycle
//  land on? Both are pure functions of `(anchor, cadence)` and nothing else — no
//  clock, no database, no time zone — so both are exhaustively testable off-device,
//  which is the whole reason they live here rather than next to the SQL.
//
//  Everything is expressed in terms of a period *index*: the anchor starts period 0,
//  the cycle before it is period -1, and so on. Two consequences fall out for free:
//  generation is deterministic (index n always yields the same date), and it is
//  idempotent (a period already stored has a known index, so it is never a candidate
//  again). DEC-009 asks for exactly those two properties.
//
//  A negative index is normal, not an error case. DEC-007 asks the user for their
//  *next* payday, so at onboarding the anchor is in the future and today sits in
//  period -1 — the app must budget the fortnight the user is already in, not wait a
//  fortnight for the anchor to arrive.
//

import Foundation

/// The three cadences, exactly (design brief, rule set).
nonisolated enum Cadence: String, Codable, Sendable, CaseIterable {
    case weekly
    case fortnightly
    case monthly

    /// Nil for monthly, which is not a fixed number of days — the distinction this
    /// whole type exists to keep honest.
    var lengthInDays: Int? {
        switch self {
        case .weekly: 7
        case .fortnightly: 14
        case .monthly: nil
        }
    }
}

/// A budget period: a closed range of calendar dates, both ends counted.
nonisolated struct BudgetPeriod: Equatable, Sendable {
    let index: Int
    let startsOn: CivilDate
    /// The last day *inside* the period — the day before the next one starts.
    /// Closed rather than half-open because it is stored, displayed and compared
    /// against `booked_on`, and "ends 13 March" is what the user is shown.
    let endsOn: CivilDate

    func contains(_ date: CivilDate) -> Bool {
        date >= startsOn && date <= endsOn
    }

    var lengthInDays: Int {
        startsOn.daysInclusive(through: endsOn)
    }
}

/// An anchor plus a cadence: everything needed to say where every boundary falls,
/// forever, in both directions.
nonisolated struct PeriodSchedule: Equatable, Sendable {
    /// The date a period starts on. DEC-007: the user's next payday.
    let anchor: CivilDate
    let cadence: Cadence

    // MARK: - Boundaries

    /// The first day of period `index`.
    func start(ofIndex index: Int) -> CivilDate {
        if let length = cadence.lengthInDays {
            return anchor.addingDays(index * length)
        }
        // Monthly clamping is always measured from the anchor's own day, never from
        // the previous period's clamped day (see `addingMonths(_:preferringDay:)`).
        return anchor.addingMonths(index, preferringDay: anchor.day)
    }

    /// The index of the period that `date` falls inside. Total: every date is in
    /// exactly one period.
    func index(containing date: CivilDate) -> Int {
        if let length = cadence.lengthInDays {
            return anchor.days(until: date).flooredDividing(by: length)
        }
        // The candidate shares `date`'s month, so it is out by at most one, and only
        // ever too late — when the clamped anchor day falls after `date` in its month.
        let candidate = (date.year * 12 + date.month) - (anchor.year * 12 + anchor.month)
        return start(ofIndex: candidate) > date ? candidate - 1 : candidate
    }

    func period(atIndex index: Int) -> BudgetPeriod {
        BudgetPeriod(
            index: index,
            startsOn: start(ofIndex: index),
            endsOn: start(ofIndex: index + 1).addingDays(-1)
        )
    }

    func period(containing date: CivilDate) -> BudgetPeriod {
        period(atIndex: index(containing: date))
    }

    // MARK: - Generation

    /// Every period from `first` through the one containing `date`, in order.
    ///
    /// DEC-009's "an app unopened for two months generates eight weekly periods
    /// instantly": the caller passes the index after the last one it stored, and
    /// gets the whole gap in one call. Returns empty when there is no gap, which is
    /// what makes calling it on every launch free.
    func periods(fromIndex first: Int, through date: CivilDate) -> [BudgetPeriod] {
        let last = index(containing: date)
        guard first <= last else { return [] }
        return (first ... last).map { period(atIndex: $0) }
    }

    // MARK: - Pay dates (DEC-036)

    /// The pay dates falling in `start ... end`, inclusive at both ends.
    ///
    /// Same cycle arithmetic as periods, deliberately: DEC-036 keeps the pay schedule
    /// in its own `(pay_anchor, pay_cadence)` because pay rhythm and budget rhythm
    /// are the same by default and not by definition — but they are the same *shape*,
    /// so monthly-on-the-31st clamps here exactly as it does for periods rather than
    /// leaving February to a second, differently-wrong implementation.
    func payDates(from start: CivilDate, through end: CivilDate) -> [CivilDate] {
        guard start <= end else { return [] }
        let firstIndex = index(containing: start)
        var dates: [CivilDate] = []
        var index = self.start(ofIndex: firstIndex) < start ? firstIndex + 1 : firstIndex
        while true {
            let date = self.start(ofIndex: index)
            guard date <= end else { break }
            dates.append(date)
            index += 1
        }
        return dates
    }
}
