//
//  PayStatus.swift
//  Budgeter
//
//  DEC-036's in-app fallback card: "no pay logged since 14 March".
//
//  The card is not the notification's twin — it is what stands between a permission
//  the user declined and a feature that then silently does nothing. So the rule it
//  runs on is here, pure and tested, and the ledger only draws what it returns. It
//  never consults notification state, by design.
//
//  Two tolerances, both of which exist because DEC-036 says drift is normal rather
//  than a bug ("Australian payroll pays early ahead of weekends and public
//  holidays, so a one- or two-day miss is normal"):
//
//  - Pay logged *before* its own pay date still counts as that payday's pay.
//    Without this, being paid early on the Thursday before a Saturday payday makes
//    the app claim on Saturday that nothing was logged.
//  - The card waits a day after the pay date before appearing, so a payday that
//    has not been logged *yet* — at 9am, before the user has looked at their bank —
//    is not immediately a complaint.
//
//  And one boundary that is not a tolerance but a fact about what the app can know:
//  nothing before the pay anchor is ever complained about. DEC-007 asks the user for
//  their *next* payday, so the anchor is the first payday that happens while the app
//  exists. Paydays computed before it are arithmetic, not history — the user was paid
//  then, but not into a database that existed to record it, and a fresh install
//  greeting its owner with "nothing logged since 28 August" is the app being wrong
//  about its own age.
//

import Foundation

nonisolated enum PayStatus: Equatable, Sendable {
    /// Nothing to say: pay is up to date, or there is no pay schedule to judge it
    /// against, or no payday has come around yet.
    case upToDate
    /// A payday has passed with no income logged for it. `since` is that payday,
    /// and it is the date the card names.
    case unlogged(since: CivilDate)

    /// Pay booked this many days before its scheduled date still counts as that
    /// payday's pay. Four days covers being paid on the Thursday before a long
    /// weekend, which is the common Australian case.
    static let earlyPayTolerance = 4

    /// The card appears the day after the payday, not on it.
    static let graceDays = 1

    /// Whether to show the card, given the pay schedule, the most recent income
    /// already logged, and today.
    ///
    /// `lastIncomeBookedOn` is the `booked_on` of the newest income row, which is a
    /// local date — the same kind of date the pay schedule produces, so the
    /// comparison never touches a time zone (rule 6).
    static func evaluate(
        paySchedule: PeriodSchedule?,
        lastIncomeBookedOn: CivilDate?,
        today: CivilDate
    ) -> PayStatus {
        guard let paySchedule else { return .upToDate }

        // The most recent payday that has been in the past long enough to complain
        // about. Bounded at both ends: a year back is generous for someone who has
        // logged nothing in a while, and the anchor is the earliest payday this app
        // was ever in a position to observe.
        let cutoff = today.addingDays(-graceDays)
        let earliest = Swift.max(cutoff.addingDays(-366), paySchedule.anchor)
        guard earliest <= cutoff else { return .upToDate }

        let dates = paySchedule.payDates(from: earliest, through: cutoff)
        guard let payday = dates.last else { return .upToDate }

        guard let logged = lastIncomeBookedOn else { return .unlogged(since: payday) }
        return logged >= payday.addingDays(-earlyPayTolerance) ? .upToDate : .unlogged(since: payday)
    }
}
