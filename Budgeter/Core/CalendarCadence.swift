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
//     once, mid-cycle. A cadence *switch* never asks, because DEC-043 makes a
//     switch take effect immediately, today — there is no "already in progress"
//     to describe, only a fresh cycle starting now.
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
}
