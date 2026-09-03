//
//  MerchantKeyTests.swift
//  BudgeterTests
//
//  DEC-030's memory is only as good as its key. These are the cases that decide
//  whether "the app remembers where I shop" is true or is a table full of rows that
//  never match anything.
//

import Foundation
import Testing
@testable import Budgeter

@Suite("Merchant normalisation")
struct MerchantKeyTests {
    @Test("the same shop through different terminals produces one key")
    func sameShopOneKey() {
        let variants = [
            "WOOLWORTHS",
            "Woolworths",
            "WOOLWORTHS 1234",
            "WOOLWORTHS 1234 SYDNEY AUS",
            "  woolworths  ",
            "WOOLWORTHS PTY LTD",
        ]
        let keys = Set(variants.map { MerchantKey.normalise($0) })
        #expect(keys.count == 1, "expected one key, got \(keys)")
        #expect(keys.first == "WOOLWORTHS")
    }

    @Test("a payment processor's prefix is not part of the shop's name")
    func processorPrefixStripped() {
        #expect(MerchantKey.normalise("SQ *THE COFFEE PLACE") == "THE COFFEE PLACE")
        #expect(MerchantKey.normalise("PAYPAL *STEAM") == "STEAM")
        #expect(MerchantKey.normalise("TST* SOME CAFE") == "SOME CAFE")
    }

    @Test("a star in the middle of a real name is left alone")
    func starInsideNameKept() {
        // Bounded to the first few characters precisely so this does not become
        // "STARS": the prefix rule must not eat a name that happens to contain one.
        #expect(MerchantKey.normalise("NORTHERN LIGHTS * BAR") == "NORTHERN LIGHTS BAR")
    }

    @Test("multi-word names keep their words and their order")
    func multiWordNames() {
        #expect(MerchantKey.normalise("The Corner Store 42") == "THE CORNER STORE")
        #expect(MerchantKey.normalise("7 ELEVEN 2033") == "ELEVEN")
    }

    @Test("nothing name-like normalises to nothing rather than to an empty key")
    func unusableInputsReturnNil() {
        // An empty key would be a rule that matches every merchantless transaction,
        // which is worse than no rule at all.
        #expect(MerchantKey.normalise(nil) == nil)
        #expect(MerchantKey.normalise("") == nil)
        #expect(MerchantKey.normalise("   ") == nil)
        #expect(MerchantKey.normalise("123456") == nil)
        #expect(MerchantKey.normalise("PTY LTD AUS") == nil)
    }

    @Test("different shops stay different")
    func distinctShopsStayDistinct() {
        let coles = MerchantKey.normalise("COLES 0392 RICHMOND")
        let woolworths = MerchantKey.normalise("WOOLWORTHS 1234 RICHMOND")
        #expect(coles != woolworths)
        #expect(coles == "COLES RICHMOND")
    }

    @Test("normalisation is idempotent")
    func idempotent() {
        // A key fed back in must not normalise further, or a rule written from one
        // pass would never match a lookup that made two.
        for raw in ["WOOLWORTHS 1234 SYDNEY AUS", "SQ *THE COFFEE PLACE", "Coles"] {
            let once = MerchantKey.normalise(raw)
            #expect(MerchantKey.normalise(once) == once)
        }
    }
}
