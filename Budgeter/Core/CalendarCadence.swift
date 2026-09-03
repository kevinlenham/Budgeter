//
//  CalendarCadence.swift
//  Budgeter
//
//  DEC-043 decoupled the budget period from payday: weekly is Monday–Sunday,
//  monthly is the calendar month, and fortnightly is a pair of calendar weeks
//  whose phase is chosen once (DEC-036's payday reminder keeps its own, separate,
//  real-payday-anchored schedule — this file has nothing to do with it).
//
//  Two consequences fall out of "calendar-anchored" that are worth being explicit
//  about, because they are the whole reason this file exists rather than reusing
//  `PeriodSchedule` alone:
//
//  1. Weekly and monthly anchors are **computed, never asked for**. Any Monday
//     produces Monday–Sunday periods forever in both directions (7 divides every
//     week), and any 1st-of-a-month produces full calendar months forever (day 1
//     never needs the DEC-007 clamping rule). There is nothing for onboarding to
//     ask.
//  2. Fortnightly has one genuine ambiguity a calendar cannot resolve on its own:
//     which of two adjacent Mondays starts "week 1" of the cycle. Onboarding asks
//     once, mid-cycle. A cadence *switch* never asks, because a switch always
//     starts a fresh cycle — there is no "already in progress" to describe.
//

import Foundation

nonisolated enum CalendarCadence {
    /// The anchor for a brand-new schedule of `cadence`, given today and — for
    /// fortnightly only — which week of the cycle today falls in.
    ///
    /// `isSecondWeek` is ignored for weekly and monthly, where there is no phase to
    /// choose.
    static func anchor(for cadence: Cadence, today: CivilDate, isSecondWeek: Bool) -> CivilDate {
        switch cadence {
        case .weekly:
            today.mostRecentMonday()
        case .monthly:
            today.startOfMonth()
        case .fortnightly:
            isSecondWeek ? today.mostRecentMonday().addingDays(-7) : today.mostRecentMonday()
        }
    }

    /// The next date on or after `from` that a period of `cadence` may naturally
    /// start on — the next Monday for weekly and fortnightly, the next 1st for
    /// monthly. `from` itself, when it already is one.
    ///
    /// This is what a cadence switch waits for: DEC-043 chose calendar rigidity
    /// over an instant switch, so "the next boundary" (DEC-008) now means the next
    /// *real* one, even when that is a few days further off than the day the
    /// current period happens to end.
    static func nextNaturalBoundary(for cadence: Cadence, onOrAfter from: CivilDate) -> CivilDate {
        switch cadence {
        case .weekly, .fortnightly:
            let index = from.weekdayIndex
            return index == 0 ? from : from.addingDays(7 - index)
        case .monthly:
            return from.day == 1 ? from : from.startOfMonth().addingMonths(1, preferringDay: 1)
        }
    }
}
