//
//  LimitScalingTests.swift
//  BudgeterTests
//
//  DEC-008's suggested limits. The property that matters is not that the arithmetic
//  is exact — it is a suggestion, and the user edits it — but that the figure looks
//  like one a person would have chosen. DEC-008 rejected silent scaling for
//  producing "$92.31 with no visible origin", and a suggestion screen offering
//  $434.86 would have earned the same objection.
//

import Foundation
import Testing
@testable import Budgeter

@Suite("Scaling a limit across cadences")
struct LimitScalingTests {
    private func aud(_ minorUnits: Int64) -> Money {
        Money(minorUnits: minorUnits, currency: .aud)
    }

    @Test("the same cadence changes nothing")
    func sameCadenceIsIdentity() {
        let limit = aud(20000)
        #expect(LimitScaling.suggested(limit: limit, from: .weekly, to: .weekly) == limit)
    }

    @Test("doubling the period doubles the limit exactly")
    func weeklyToFortnightly() {
        // 7 to 14 days is a clean multiple, so there is nothing for the rounding to
        // do and the answer must be exact.
        #expect(LimitScaling.suggested(limit: aud(10000), from: .weekly, to: .fortnightly) == aud(20000))
    }

    @Test("a fortnightly limit becomes a round monthly one")
    func fortnightlyToMonthly() {
        // $200 a fortnight is $434.86 a month. The suggestion is $435 — the same
        // budget, in a figure someone would actually type.
        #expect(LimitScaling.suggested(limit: aud(20000), from: .fortnightly, to: .monthly) == aud(43500))
    }

    @Test("a monthly limit becomes a round weekly one")
    func monthlyToWeekly() {
        #expect(LimitScaling.suggested(limit: aud(50000), from: .monthly, to: .weekly) == aud(11500))
    }

    @Test("small limits round to the dollar, not to five")
    func smallLimitsRoundFiner() {
        // $5 a month rounded to the nearest $5 could halve or double it, which is
        // the opposite of a helpful suggestion.
        #expect(LimitScaling.suggested(limit: aud(200), from: .fortnightly, to: .monthly) == aud(400))
    }

    @Test("a deliberate zero stays zero")
    func zeroStaysZero() {
        // A category the user zeroed is a decision, not an empty field.
        #expect(LimitScaling.suggested(limit: aud(0), from: .weekly, to: .monthly) == aud(0))
    }

    @Test("a tiny limit never rounds away to nothing")
    func neverRoundsToZero() {
        // "No limit at all" is a different statement from "a small limit", and the
        // suggestion screen must not make that change on the user's behalf.
        let scaled = LimitScaling.suggested(limit: aud(10), from: .monthly, to: .weekly)
        #expect(scaled?.isZero == false)
    }

    @Test("scaling up then back down stays in the same neighbourhood")
    func roundTripStaysClose() {
        // Not an equality: rounding is lossy by design. But a user switching
        // fortnightly → monthly → fortnightly must not find their budget has
        // wandered off, which is what an accumulating bias would do.
        let original = aud(20000)
        let monthly = LimitScaling.suggested(limit: original, from: .fortnightly, to: .monthly)
        let back = monthly.flatMap { LimitScaling.suggested(limit: $0, from: .monthly, to: .fortnightly) }
        let difference = abs((back?.minorUnits ?? 0) - original.minorUnits)
        #expect(difference <= 500, "drifted by \(difference) minor units")
    }

    @Test("a currency with no minor units rounds in whole units of itself")
    func zeroExponentCurrency() {
        // JPY has no cents, so "the nearest dollar" has to mean the nearest yen
        // rather than the nearest hundred.
        let yen = Money(minorUnits: 10000, currency: .jpy)
        let scaled = LimitScaling.suggested(limit: yen, from: .weekly, to: .fortnightly)
        #expect(scaled == Money(minorUnits: 20000, currency: .jpy))
    }
}
