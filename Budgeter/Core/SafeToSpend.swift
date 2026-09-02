//
//  SafeToSpend.swift
//  Budgeter
//
//  DEC-009's closing line: "days-remaining is plain date arithmetic in the user's
//  calendar, inclusive of today, and safe-to-spend is `remaining_limit /
//  days_remaining_inclusive`". That is the whole rule. It is here as a function
//  rather than inline in a view so the two edges that matter — the last day of a
//  period, and a category already overspent — have somewhere to be tested.
//

import Foundation

nonisolated enum SafeToSpendError: Error, Equatable {
    /// Asked for a daily allowance on a period that is already over.
    case periodAlreadyEnded
}

nonisolated enum SafeToSpend {
    /// Days left in `period` as of `date`, counting today.
    ///
    /// Inclusive because that is what the number means to a person: on the last day
    /// of a period one day remains, not zero, and the day's allowance is the whole
    /// of what is left rather than a division by zero.
    static func daysRemaining(in period: BudgetPeriod, asOf date: CivilDate) -> Int {
        if date < period.startsOn {
            return period.lengthInDays
        }
        if date > period.endsOn {
            return 0
        }
        return date.daysInclusive(through: period.endsOn)
    }

    /// What may be spent today without eating into the rest of the period.
    ///
    /// Rounds **down**, so the figure is always affordable — the alternative rounds
    /// a fraction of a cent into a number the user cannot actually spend on the last
    /// day. An overspent category returns zero rather than a negative allowance:
    /// "you may spend nothing today" is the true statement, and the size of the hole
    /// is `remaining` itself, which the caller already has.
    static func daily(remaining: Money, daysRemaining: Int) throws -> Money {
        guard daysRemaining > 0 else { throw SafeToSpendError.periodAlreadyEnded }
        guard remaining.isPositive else { return Money.zero(remaining.currency) }
        return Money(
            minorUnits: remaining.minorUnits.flooredDividing(by: Int64(daysRemaining)),
            currency: remaining.currency
        )
    }
}

nonisolated extension Int64 {
    /// Division rounding toward negative infinity. `Money` amounts are only ever
    /// divided downward, so the truncating `/` would round an overspend *up*.
    func flooredDividing(by divisor: Int64) -> Int64 {
        let quotient = self / divisor
        return (self % divisor != 0 && (self < 0) != (divisor < 0)) ? quotient - 1 : quotient
    }
}
