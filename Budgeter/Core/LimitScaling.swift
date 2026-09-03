//
//  LimitScaling.swift
//  Budgeter
//
//  The suggested limits DEC-008 puts on the cadence-switch confirmation screen.
//
//  DEC-008's objection to silent scaling is worth restating, because it is the
//  reason this file rounds at all: scaling "produces numbers no human chose
//  ($92.31) with no visible origin". The fix is not to stop scaling — a $200 limit
//  is meaningless without its cadence, so a switch must do *something* — it is to
//  put the scaled figure in front of the user as an editable suggestion, and to
//  make that suggestion look like a number a person would have picked.
//
//  So: scale exactly, then round to something choosable. Nothing here is ever
//  written without the user seeing it and being able to change it.
//

import Foundation

nonisolated enum LimitScaling {
    /// Cadence length in hundredths of a day.
    ///
    /// Integers rather than a `Double`, for the same reason `Money` is integers: a
    /// budgeting app has no business doing binary floating-point arithmetic on an
    /// amount, even one it is about to round. The monthly figure is the mean
    /// Gregorian month, 365.2425 / 12, so a weekly→monthly suggestion is not
    /// quietly 1.5% light the way a flat 30 would make it.
    private static func hundredthsOfADay(_ cadence: Cadence) -> Int64 {
        switch cadence {
        case .weekly: 700
        case .fortnightly: 1400
        case .monthly: 3044
        }
    }

    /// A suggested limit for `to`, given the limit that applied under `from`.
    ///
    /// Returns nil on overflow rather than a wrong number: the screen then offers
    /// no suggestion for that category and the user types one, which is a worse
    /// experience than a suggestion and a much better one than a silently wrong
    /// limit. Zero in gives zero out — a category the user deliberately zeroed is
    /// not one to start suggesting money for.
    static func suggested(limit: Money, from: Cadence, to: Cadence) -> Money? {
        guard from != to else { return limit }
        guard !limit.isZero else { return limit }

        let (scaled, overflowed) = limit.minorUnits.multipliedReportingOverflow(by: hundredthsOfADay(to))
        guard !overflowed else { return nil }

        let exact = scaled / hundredthsOfADay(from)
        return Money(minorUnits: rounded(exact, currency: limit.currency), currency: limit.currency)
    }

    // MARK: - Private

    /// Rounds to a figure a person would plausibly have typed: the nearest $5 once
    /// the amount is big enough for $5 to be a rounding error rather than a real
    /// share of the budget, and the nearest $1 below that. Never down to zero —
    /// a limit of nothing is a different decision from a small limit, and the
    /// switch screen must not make it on the user's behalf.
    private static func rounded(_ minorUnits: Int64, currency: Currency) -> Int64 {
        let major = majorUnit(currency)
        let step = minorUnits >= 50 * major ? 5 * major : major
        let rounded = ((minorUnits + step / 2) / step) * step
        return max(rounded, step)
    }

    /// One whole unit of the currency, in minor units: 100 cents, or 1 yen.
    private static func majorUnit(_ currency: Currency) -> Int64 {
        (0 ..< currency.minorUnitExponent).reduce(Int64(1)) { total, _ in total * 10 }
    }
}
