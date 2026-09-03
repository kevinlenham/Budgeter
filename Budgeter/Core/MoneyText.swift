//
//  MoneyText.swift
//  Budgeter
//
//  The boundary between `Money` and the screen, in both directions.
//
//  Invariant 1 says money is never a `Double`, and that has to survive contact with
//  a text field: a form that parses "12.10" into a binary float and back has already
//  lost the guarantee the whole type exists to provide. So parsing here is integer
//  string work — digits before a separator, digits after it — and never `Double(_:)`.
//
//  Formatting is allowed one concession: `Decimal`, which is base-10 and exact, so
//  the conversion loses nothing. It buys the platform's own currency symbols,
//  grouping and negative-number conventions, which are not worth hand-rolling and
//  are locale-sensitive in ways a hand-rolled version would get wrong.
//

import Foundation

nonisolated enum MoneyParseError: Error, Equatable {
    case empty
    case notANumber
    /// More decimal places than the currency has — "12.345" in dollars. Refused
    /// rather than rounded: the user typed something specific, and silently
    /// discarding a digit is how a form lies about what it recorded.
    case tooManyDecimalPlaces(allowed: Int)
    case overflow
}

nonisolated enum MoneyText {
    // MARK: - Display

    /// The amount as the user's locale writes it: `$12.50`, `¥1,200`.
    static func string(from money: Money, locale: Locale = .current) -> String {
        let exponent = money.currency.minorUnitExponent
        let value = Decimal(money.minorUnits) / pow(Decimal(10), exponent)
        return value.formatted(
            .currency(code: money.currency.rawValue)
                .locale(locale)
                .precision(.fractionLength(exponent))
        )
    }

    /// The amount without a currency symbol, for a text field the user is editing.
    /// Always plain digits and at most one separator, so re-parsing it is exact.
    static func editableString(from money: Money) -> String {
        let exponent = money.currency.minorUnitExponent
        let magnitude = money.minorUnits.magnitude
        let sign = money.isNegative ? "-" : ""
        guard exponent > 0 else { return "\(sign)\(magnitude)" }

        let divisor = (0 ..< exponent).reduce(UInt64(1)) { product, _ in product * 10 }
        let whole = magnitude / divisor
        let fraction = magnitude % divisor
        let padded = String(fraction).leftPadded(to: exponent, with: "0")
        return "\(sign)\(whole).\(padded)"
    }

    // MARK: - Input

    /// Parses what a person typed into an exact amount.
    ///
    /// Accepts `12`, `12.5`, `12.50`, `.50`, `$12.50`, `1,234.50` and a leading `-`.
    /// Both `.` and `,` are accepted as the decimal separator, because the numeric
    /// keypad offers whichever the locale prefers and a user typing the other one
    /// means the obvious thing.
    static func money(from text: String, currency: Currency) throws -> Money {
        let exponent = currency.minorUnitExponent
        let scanned = try scan(text)

        guard !scanned.whole.isEmpty || !scanned.fraction.isEmpty else {
            throw text.isEmpty ? MoneyParseError.empty : MoneyParseError.notANumber
        }
        guard scanned.fraction.count <= exponent else {
            throw MoneyParseError.tooManyDecimalPlaces(allowed: exponent)
        }

        // A trailing separator ("12.") is the user mid-type, not an error, so the
        // fraction is padded out rather than rejected.
        let minorDigits = scanned.whole + scanned.fraction.leftPadded(to: exponent, with: "0", trailing: true)
        guard let magnitude = Int64(minorDigits.isEmpty ? "0" : minorDigits) else {
            throw MoneyParseError.overflow
        }
        return Money(minorUnits: scanned.isNegative ? -magnitude : magnitude, currency: currency)
    }

    // MARK: - Private

    private struct Scanned {
        var whole = ""
        var fraction = ""
        var sawSeparator = false
        var isNegative = false
    }

    /// Splits the typed text into sign, whole digits and fraction digits, rejecting
    /// anything that is not one of those. Currency symbols and spaces are ignored so
    /// a pasted "$12.50" works.
    private static func scan(_ text: String) throws -> Scanned {
        var scanned = Scanned()
        for character in text {
            switch character {
            case "-" where scanned.whole.isEmpty && !scanned.sawSeparator && !scanned.isNegative:
                scanned.isNegative = true
            case ".", ",":
                guard !scanned.sawSeparator else { throw MoneyParseError.notANumber }
                scanned.sawSeparator = true
            case let digit where digit.isNumber:
                if scanned.sawSeparator {
                    scanned.fraction.append(digit)
                } else {
                    scanned.whole.append(digit)
                }
            case " ", "$", "\u{00A5}", "\u{00A3}", "\u{20AC}", "\u{00A0}":
                continue
            default:
                throw MoneyParseError.notANumber
            }
        }
        return scanned
    }
}

nonisolated extension String {
    /// Pads with `character` so the result is exactly `width` long. Used to turn
    /// "5" into "50" cents (trailing) and 7 into "07" (leading).
    func leftPadded(to width: Int, with character: Character, trailing: Bool = false) -> String {
        guard count < width else { return self }
        let padding = String(repeating: character, count: width - count)
        return trailing ? self + padding : padding + self
    }
}
