//
//  SafeToSpendTests.swift
//  BudgeterTests
//
//  DEC-009's closing rule — `remaining_limit / days_remaining_inclusive` — and the
//  two edges that matter: the last day of a period, and a category already overspent.
//

import Foundation
import Testing
@testable import Budgeter

@Suite("Safe to spend — DEC-009")
struct SafeToSpendTests {
    private func period(_ start: String, _ end: String) throws -> BudgetPeriod {
        BudgetPeriod(
            index: 0,
            startsOn: try #require(CivilDate(iso: start)),
            endsOn: try #require(CivilDate(iso: end))
        )
    }

    private func date(_ iso: String) throws -> CivilDate {
        try #require(CivilDate(iso: iso))
    }

    @Test("days remaining counts today, so the last day of a period has one day left")
    func daysRemainingIsInclusive() throws {
        let march = try period("2026-03-01", "2026-03-31")
        #expect(SafeToSpend.daysRemaining(in: march, asOf: try date("2026-03-01")) == 31)
        #expect(SafeToSpend.daysRemaining(in: march, asOf: try date("2026-03-15")) == 17)
        #expect(SafeToSpend.daysRemaining(in: march, asOf: try date("2026-03-31")) == 1, "not zero")
        #expect(SafeToSpend.daysRemaining(in: march, asOf: try date("2026-04-01")) == 0)
        #expect(SafeToSpend.daysRemaining(in: march, asOf: try date("2026-02-01")) == 31, "not yet started")
    }

    @Test("the daily allowance is the remainder spread over the days that are left")
    func dailyAllowance() throws {
        let remaining = Money(minorUnits: 16000, currency: .aud)
        #expect(try SafeToSpend.daily(remaining: remaining, daysRemaining: 16).minorUnits == 1000)
        #expect(try SafeToSpend.daily(remaining: remaining, daysRemaining: 1).minorUnits == 16000)
    }

    @Test("the allowance rounds down, so the figure is always actually affordable")
    func roundsDown() throws {
        let remaining = Money(minorUnits: 1000, currency: .aud)
        #expect(try SafeToSpend.daily(remaining: remaining, daysRemaining: 3).minorUnits == 333)
        #expect(try SafeToSpend.daily(remaining: remaining, daysRemaining: 7).minorUnits == 142)
    }

    @Test("an overspent category may spend nothing today, rather than a negative amount")
    func overspentGivesZero() throws {
        let overspent = Money(minorUnits: -12500, currency: .aud)
        #expect(try SafeToSpend.daily(remaining: overspent, daysRemaining: 10).isZero)
        #expect(try SafeToSpend.daily(remaining: Money.zero(.aud), daysRemaining: 10).isZero)
    }

    @Test("the currency survives the division")
    func currencyIsPreserved() throws {
        let remaining = Money(minorUnits: 10000, currency: .jpy)
        #expect(try SafeToSpend.daily(remaining: remaining, daysRemaining: 4).currency == .jpy)
    }

    @Test("a finished period throws rather than dividing by zero")
    func endedPeriodThrows() throws {
        #expect(throws: SafeToSpendError.periodAlreadyEnded) {
            try SafeToSpend.daily(remaining: Money(minorUnits: 100, currency: .aud), daysRemaining: 0)
        }
    }
}
