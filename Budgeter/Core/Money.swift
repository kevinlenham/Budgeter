//
//  Money.swift
//  Budgeter
//
//  Invariant 1: money is an integer of minor units plus a currency code, never a Double.
//  There are deliberately no arithmetic operators here — every operation is a named,
//  throwing function, so a currency mismatch cannot be written by accident.
//

import Foundation

/// An ISO 4217 currency, with the exponent that defines its minor unit.
nonisolated enum Currency: String, Codable, Sendable, CaseIterable {
    case aud = "AUD"
    case nzd = "NZD"
    case usd = "USD"
    case gbp = "GBP"
    case eur = "EUR"
    case jpy = "JPY"

    /// Decimal places in the minor unit: 2 for dollars-and-cents, 0 for yen.
    var minorUnitExponent: Int {
        switch self {
        case .jpy: 0
        case .aud, .nzd, .usd, .gbp, .eur: 2
        }
    }
}

nonisolated enum MoneyError: Error, Equatable {
    /// Two amounts in different currencies were combined.
    case currencyMismatch(Currency, Currency)
    /// The result does not fit in `Int64`.
    case overflow
    case invalidAllocation(String)
}

/// An exact amount of money, held as a whole number of minor units.
///
/// `Money(minorUnits: 1250, currency: .aud)` is $12.50. There is no fractional
/// representation anywhere in the type, so no rounding error can enter.
nonisolated struct Money: Equatable, Hashable, Sendable {
    let minorUnits: Int64
    let currency: Currency

    static func zero(_ currency: Currency) -> Money {
        Money(minorUnits: 0, currency: currency)
    }

    var isZero: Bool {
        minorUnits == 0
    }

    var isNegative: Bool {
        minorUnits < 0
    }

    var isPositive: Bool {
        minorUnits > 0
    }

    // MARK: - Arithmetic

    func adding(_ other: Money) throws -> Money {
        try requireSameCurrency(as: other)
        let (sum, overflowed) = minorUnits.addingReportingOverflow(other.minorUnits)
        guard !overflowed else { throw MoneyError.overflow }
        return Money(minorUnits: sum, currency: currency)
    }

    func subtracting(_ other: Money) throws -> Money {
        try requireSameCurrency(as: other)
        let (difference, overflowed) = minorUnits.subtractingReportingOverflow(other.minorUnits)
        guard !overflowed else { throw MoneyError.overflow }
        return Money(minorUnits: difference, currency: currency)
    }

    func negated() throws -> Money {
        guard minorUnits != Int64.min else { throw MoneyError.overflow }
        return Money(minorUnits: -minorUnits, currency: currency)
    }

    func multiplied(by factor: Int64) throws -> Money {
        let (product, overflowed) = minorUnits.multipliedReportingOverflow(by: factor)
        guard !overflowed else { throw MoneyError.overflow }
        return Money(minorUnits: product, currency: currency)
    }

    /// Ordering, which only means anything within a single currency.
    ///
    /// Deliberately not `Comparable`: that protocol cannot throw, so conforming would
    /// force a silent answer for the one comparison that has no correct one.
    func isLessThan(_ other: Money) throws -> Bool {
        try requireSameCurrency(as: other)
        return minorUnits < other.minorUnits
    }

    // MARK: - Allocation

    /// Splits this amount in the given proportions, losing nothing.
    ///
    /// The shares always sum to exactly `self`. Whatever cannot be divided evenly is
    /// handed out one minor unit at a time, largest fractional remainder first, so
    /// `$100` in three parts is `[33.34, 33.33, 33.33]` rather than `[33.33, 33.33, 33.33]`
    /// with a cent quietly destroyed. Ties go to the earlier index, so the result is
    /// deterministic rather than merely correct in aggregate.
    func allocate(ratios: [Int]) throws -> [Money] {
        guard !ratios.isEmpty else {
            throw MoneyError.invalidAllocation("ratios must not be empty")
        }
        guard ratios.allSatisfy({ $0 >= 0 }) else {
            throw MoneyError.invalidAllocation("ratios must not be negative")
        }

        var total: Int64 = 0
        for ratio in ratios {
            let (sum, overflowed) = total.addingReportingOverflow(Int64(ratio))
            guard !overflowed else { throw MoneyError.overflow }
            total = sum
        }
        guard total > 0 else {
            throw MoneyError.invalidAllocation("ratios must not sum to zero")
        }

        var shares: [Int64] = []
        var remainders: [(index: Int, remainder: Int64)] = []
        shares.reserveCapacity(ratios.count)
        remainders.reserveCapacity(ratios.count)

        for (index, ratio) in ratios.enumerated() {
            let (product, overflowed) = minorUnits.multipliedReportingOverflow(by: Int64(ratio))
            guard !overflowed else { throw MoneyError.overflow }
            shares.append(product / total)
            remainders.append((index, product % total))
        }

        // `leftover` carries the sign of the original amount, and its magnitude is
        // strictly less than the number of non-zero remainders — so a zero ratio,
        // whose remainder is always zero and which therefore sorts last, never
        // receives a stray unit.
        let distributed = shares.reduce(Int64(0), +)
        let leftover = minorUnits - distributed
        let step: Int64 = leftover < 0 ? -1 : 1

        let order = remainders.sorted { lhs, rhs in
            let left = lhs.remainder.magnitude
            let right = rhs.remainder.magnitude
            return left == right ? lhs.index < rhs.index : left > right
        }

        let spare = Int(leftover.magnitude)
        guard spare <= order.count else {
            throw MoneyError.invalidAllocation("allocation left more units than shares")
        }
        for position in 0 ..< spare {
            shares[order[position].index] += step
        }

        return shares.map { Money(minorUnits: $0, currency: currency) }
    }

    /// Splits this amount into `parts` as evenly as possible, losing nothing.
    func allocate(evenly parts: Int) throws -> [Money] {
        guard parts > 0 else {
            throw MoneyError.invalidAllocation("parts must be greater than zero")
        }
        return try allocate(ratios: Array(repeating: 1, count: parts))
    }

    // MARK: - Private

    private func requireSameCurrency(as other: Money) throws {
        guard currency == other.currency else {
            throw MoneyError.currencyMismatch(currency, other.currency)
        }
    }
}
