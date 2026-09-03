//
//  MerchantKey.swift
//  Budgeter
//
//  DEC-030's normalisation, on its own, with no database anywhere near it.
//
//  A card descriptor is not a shop name. The same Woolworths produces "WOOLWORTHS
//  1234 SYDNEY AUS", "WOOLWORTHS ONLINE", and "SQ *WOOLWORTHS" depending on who
//  processed the payment, and a memory keyed on the raw string learns each of them
//  separately and is therefore useless. Everything here exists to collapse those
//  onto one key.
//
//  Two rules govern what is safe to strip:
//
//  1. **Only strip what is provably not the name.** Digits, payment-processor
//     prefixes, company-form suffixes and country codes are noise in every case.
//     Suburbs and states are not on the list, tempting as they are: "Sydney
//     Seafood" is a shop, and there is no way to tell it from a location token
//     without a gazetteer, which is exactly the rotting data set DEC-030 refused.
//
//  2. **Collisions are cheap; over-splitting is not.** Two genuinely different
//     shops that normalise together produce one wrong guess, which the user
//     corrects in a tap and which then re-teaches the rule. A shop that fails to
//     normalise together with itself produces a memory that never fires at all —
//     silently, with nothing on screen to correct.
//

import Foundation

nonisolated enum MerchantKey {
    /// Tokens that are never part of a shop's name.
    private static let noise: Set<String> = [
        "PTY", "LTD", "PTYLTD", "LIMITED", "INC", "LLC", "AUS", "AU", "AUSTRALIA",
        "NZ", "USA", "US", "GB", "UK",
    ]

    /// Payment processors that prefix the real merchant with their own tag: "SQ
    /// *THE COFFEE PLACE" is Square's descriptor for a shop that has no idea it is
    /// being labelled this way. The `*` is the giveaway and is what is matched, so
    /// a processor nobody has heard of yet is handled without a list to maintain.
    private static let maximumPrefixLength = 8

    /// The key a rule is stored and looked up under.
    ///
    /// Returns nil for a string with nothing name-like left in it — an all-digits
    /// descriptor, or a blank field. A transaction with no usable merchant simply
    /// teaches nothing, which is better than teaching a rule keyed on "" that then
    /// matches every other merchantless transaction.
    static func normalise(_ raw: String?) -> String? {
        guard let raw, let trimmed = raw.trimmedOrNil else { return nil }

        let withoutPrefix = strippingProcessorPrefix(trimmed.uppercased())
        let tokens = withoutPrefix
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { isNameLike($0) }

        guard !tokens.isEmpty else { return nil }
        return tokens.joined(separator: " ")
    }

    // MARK: - Private

    /// Drops a leading `PROCESSOR *` tag. Bounded to the first few characters so a
    /// `*` appearing in the middle of a genuine name is left where it is.
    private static func strippingProcessorPrefix(_ text: String) -> String {
        guard let star = text.firstIndex(of: "*") else { return text }
        guard text.distance(from: text.startIndex, to: star) <= maximumPrefixLength else { return text }
        return String(text[text.index(after: star)...])
    }

    /// A token survives if it could be part of a name.
    ///
    /// Anything containing a digit goes: store numbers, terminal ids, card tails
    /// and dates all take that shape, and a shop whose name is genuinely numeric
    /// ("7 ELEVEN") still keeps its letter tokens and normalises consistently.
    private static func isNameLike(_ token: String) -> Bool {
        guard !token.contains(where: \.isNumber) else { return false }
        return !noise.contains(token)
    }
}
