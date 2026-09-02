//
//  MoneyTests.swift
//  BudgeterTests
//
//  Invariant 1. The property tests use a seeded generator so a failure reproduces
//  exactly rather than haunting CI once a fortnight.
//

import Testing
@testable import Budgeter

/// SplitMix64. Small, well-distributed, and deterministic from a seed.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Amounts in a range wide enough to be interesting, narrow enough that ordinary
/// addition never overflows — overflow gets its own dedicated tests below.
private func arbitraryAmount(_ generator: inout SeededGenerator) -> Money {
    Money(minorUnits: Int64.random(in: -1_000_000_000 ... 1_000_000_000, using: &generator), currency: .aud)
}

@Suite("Money arithmetic")
struct MoneyArithmeticTests {
    @Test("addition is associative")
    func additionIsAssociative() throws {
        var generator = SeededGenerator(seed: 0xB0D9_1234)
        for _ in 0 ..< 500 {
            let a = arbitraryAmount(&generator)
            let b = arbitraryAmount(&generator)
            let c = arbitraryAmount(&generator)

            let leftFirst = try a.adding(b).adding(c)
            let rightFirst = try a.adding(b.adding(c))
            #expect(leftFirst == rightFirst)
        }
    }

    @Test("addition is commutative")
    func additionIsCommutative() throws {
        var generator = SeededGenerator(seed: 0x1DEA_5678)
        for _ in 0 ..< 500 {
            let a = arbitraryAmount(&generator)
            let b = arbitraryAmount(&generator)
            #expect(try a.adding(b) == b.adding(a))
        }
    }

    @Test("zero is the additive identity, and subtracting yourself is zero")
    func additiveIdentity() throws {
        var generator = SeededGenerator(seed: 0xFACE_9012)
        for _ in 0 ..< 500 {
            let a = arbitraryAmount(&generator)
            #expect(try a.adding(.zero(.aud)) == a)
            #expect(try a.subtracting(a) == Money.zero(.aud))
        }
    }

    @Test("subtracting is adding the negation")
    func subtractionIsAddingNegation() throws {
        var generator = SeededGenerator(seed: 0xCAFE_3456)
        for _ in 0 ..< 500 {
            let a = arbitraryAmount(&generator)
            let b = arbitraryAmount(&generator)
            #expect(try a.subtracting(b) == a.adding(b.negated()))
        }
    }

    @Test("no precision is lost through arithmetic")
    func noPrecisionLoss() throws {
        // The whole point of integer minor units: a third of ten cents cannot
        // silently become 3.3333 anything.
        let tenCents = Money(minorUnits: 10, currency: .aud)
        let thirds = try tenCents.allocate(evenly: 3)
        #expect(thirds.map(\.minorUnits) == [4, 3, 3])

        var running = Money.zero(.aud)
        for _ in 0 ..< 1000 {
            running = try running.adding(Money(minorUnits: 1, currency: .aud))
        }
        #expect(running.minorUnits == 1000)
    }
}

@Suite("Money currency safety")
struct MoneyCurrencyTests {
    @Test("adding across currencies throws")
    func addingMismatchedCurrenciesThrows() throws {
        let aud = Money(minorUnits: 100, currency: .aud)
        let usd = Money(minorUnits: 100, currency: .usd)

        #expect(throws: MoneyError.currencyMismatch(.aud, .usd)) {
            try aud.adding(usd)
        }
    }

    @Test("subtracting across currencies throws")
    func subtractingMismatchedCurrenciesThrows() throws {
        let aud = Money(minorUnits: 500, currency: .aud)
        let jpy = Money(minorUnits: 500, currency: .jpy)

        #expect(throws: MoneyError.currencyMismatch(.aud, .jpy)) {
            try aud.subtracting(jpy)
        }
    }

    @Test("comparing across currencies throws rather than answering")
    func comparingMismatchedCurrenciesThrows() throws {
        let aud = Money(minorUnits: 1, currency: .aud)
        let eur = Money(minorUnits: 1_000_000, currency: .eur)

        #expect(throws: MoneyError.currencyMismatch(.aud, .eur)) {
            try aud.isLessThan(eur)
        }
    }

    @Test("same-currency operations are unaffected")
    func sameCurrencyIsFine() throws {
        let a = Money(minorUnits: 250, currency: .aud)
        let b = Money(minorUnits: 175, currency: .aud)
        #expect(try a.adding(b).minorUnits == 425)
        #expect(try a.subtracting(b).minorUnits == 75)
        #expect(try b.isLessThan(a))
    }
}

@Suite("Money overflow")
struct MoneyOverflowTests {
    @Test("overflowing addition throws instead of trapping")
    func additionOverflowThrows() throws {
        let big = Money(minorUnits: .max, currency: .aud)
        let one = Money(minorUnits: 1, currency: .aud)
        #expect(throws: MoneyError.overflow) { try big.adding(one) }
    }

    @Test("overflowing subtraction throws instead of trapping")
    func subtractionOverflowThrows() throws {
        let small = Money(minorUnits: .min, currency: .aud)
        let one = Money(minorUnits: 1, currency: .aud)
        #expect(throws: MoneyError.overflow) { try small.subtracting(one) }
    }

    @Test("negating Int64.min throws, because its positive has no representation")
    func negationOverflowThrows() throws {
        #expect(throws: MoneyError.overflow) {
            try Money(minorUnits: .min, currency: .aud).negated()
        }
    }

    @Test("overflowing multiplication throws instead of trapping")
    func multiplicationOverflowThrows() throws {
        let big = Money(minorUnits: Int64.max / 2, currency: .aud)
        #expect(throws: MoneyError.overflow) { try big.multiplied(by: 3) }
    }
}

@Suite("Money allocation")
struct MoneyAllocationTests {
    @Test("allocation never loses or invents a minor unit")
    func allocationSumsExactly() throws {
        var generator = SeededGenerator(seed: 0x5EED_7890)
        for _ in 0 ..< 500 {
            let amount = arbitraryAmount(&generator)
            let count = Int.random(in: 1 ... 12, using: &generator)
            let ratios = (0 ..< count).map { _ in Int.random(in: 0 ... 100, using: &generator) }
            guard ratios.contains(where: { $0 > 0 }) else { continue }

            let shares = try amount.allocate(ratios: ratios)
            let total = try shares.reduce(Money.zero(.aud)) { try $0.adding($1) }

            #expect(total == amount)
            #expect(shares.count == ratios.count)
        }
    }

    @Test("an even split distributes the remainder one unit at a time")
    func evenSplitDistributesRemainder() throws {
        let hundredDollars = Money(minorUnits: 10000, currency: .aud)
        let thirds = try hundredDollars.allocate(evenly: 3)
        #expect(thirds.map(\.minorUnits) == [3334, 3333, 3333])

        let total = try thirds.reduce(Money.zero(.aud)) { try $0.adding($1) }
        #expect(total == hundredDollars)
    }

    @Test("shares in an even split never differ by more than one minor unit")
    func evenSplitIsBalanced() throws {
        var generator = SeededGenerator(seed: 0xD1CE_2345)
        for _ in 0 ..< 300 {
            let amount = arbitraryAmount(&generator)
            let parts = Int.random(in: 1 ... 20, using: &generator)
            let shares = try amount.allocate(evenly: parts).map(\.minorUnits)

            guard let smallest = shares.min(), let largest = shares.max() else {
                Issue.record("an allocation produced no shares")
                return
            }
            #expect(largest - smallest <= 1)
        }
    }

    @Test("negative amounts allocate in the right direction")
    func negativeAllocation() throws {
        let refund = Money(minorUnits: -10000, currency: .aud)
        let thirds = try refund.allocate(evenly: 3)

        #expect(thirds.map(\.minorUnits) == [-3334, -3333, -3333])
        let allNegative = thirds.allSatisfy(\.isNegative)
        #expect(allNegative)
        let total = try thirds.reduce(Money.zero(.aud)) { try $0.adding($1) }
        #expect(total == refund)
    }

    @Test("a zero ratio always receives exactly zero, never a stray unit")
    func zeroRatiosGetNothing() throws {
        var generator = SeededGenerator(seed: 0x0BAD_6789)
        for _ in 0 ..< 300 {
            let amount = arbitraryAmount(&generator)
            let ratios = [3, 0, 5, 0, 1]
            let shares = try amount.allocate(ratios: ratios)

            #expect(shares[1].isZero)
            #expect(shares[3].isZero)
            let total = try shares.reduce(Money.zero(.aud)) { try $0.adding($1) }
            #expect(total == amount)
        }
    }

    @Test("a bigger ratio never receives a smaller share")
    func biggerRatioNeverGetsLess() throws {
        let amount = Money(minorUnits: 9997, currency: .aud)
        let shares = try amount.allocate(ratios: [1, 2, 3, 4]).map(\.minorUnits)
        #expect(shares == shares.sorted())
    }

    @Test("allocation is deterministic, not merely correct in total")
    func allocationIsDeterministic() throws {
        let amount = Money(minorUnits: 100, currency: .aud)
        let first = try amount.allocate(ratios: [1, 1, 1, 1, 1, 1, 7])
        let second = try amount.allocate(ratios: [1, 1, 1, 1, 1, 1, 7])
        #expect(first == second)
    }

    @Test("nonsense allocations are rejected")
    func invalidAllocationsThrow() throws {
        let amount = Money(minorUnits: 100, currency: .aud)

        #expect(throws: MoneyError.self) { try amount.allocate(ratios: []) }
        #expect(throws: MoneyError.self) { try amount.allocate(ratios: [1, -1]) }
        #expect(throws: MoneyError.self) { try amount.allocate(ratios: [0, 0]) }
        #expect(throws: MoneyError.self) { try amount.allocate(evenly: 0) }
    }

    @Test("allocating zero gives everyone zero")
    func allocatingZero() throws {
        let shares = try Money.zero(.aud).allocate(evenly: 4)
        let allZero = shares.allSatisfy(\.isZero)
        #expect(allZero)
    }

    @Test("a currency with no minor unit still allocates exactly")
    func zeroExponentCurrency() throws {
        let yen = Money(minorUnits: 100, currency: .jpy)
        #expect(Currency.jpy.minorUnitExponent == 0)

        let shares = try yen.allocate(evenly: 3)
        #expect(shares.map(\.minorUnits) == [34, 33, 33])
    }
}
