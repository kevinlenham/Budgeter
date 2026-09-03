//
//  MerchantRulesTests.swift
//  BudgeterTests
//
//  DEC-030's memory, against a real database.
//
//  The behaviour worth pinning down is not "it remembers" — it is what happens on
//  the second, third and corrected sightings, because that is where a memory either
//  becomes useful or starts arguing with the user.
//

import Foundation
import GRDB
import Testing
@testable import Budgeter

@Suite("Merchant memory")
struct MerchantRulesTests {
    @Test("a category learned once is proposed the next time, through a different terminal")
    func learnsAndProposes() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try Fixture.onboard(db)
            let groceries = try Fixture.category("Groceries", in: db)

            try MerchantRules().remember(merchant: "WOOLWORTHS 1234 SYDNEY", categoryID: groceries, in: db)

            // The whole point of normalising: the second sighting almost never
            // matches the first byte for byte.
            #expect(try MerchantRules().suggestion(forMerchant: "Woolworths", in: db) == groceries)
            #expect(try MerchantRules().suggestion(forMerchant: "WOOLWORTHS 9876 MELBOURNE", in: db) == groceries)
        }
    }

    @Test("a correction wins immediately rather than being outvoted")
    func correctionWinsImmediately() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try Fixture.onboard(db)
            let groceries = try Fixture.category("Groceries", in: db)
            let eatingOut = try Fixture.category("Eating out", in: db)

            for _ in 0 ..< 5 {
                try MerchantRules().remember(merchant: "Corner Shop", categoryID: groceries, in: db)
            }
            try MerchantRules().remember(merchant: "Corner Shop", categoryID: eatingOut, in: db)

            // A vote would need five more corrections to change its mind, while the
            // app kept proposing a category the user had visibly stopped choosing.
            #expect(try MerchantRules().suggestion(forMerchant: "Corner Shop", in: db) == eatingOut)
        }
    }

    @Test("one merchant has one rule, however many times it is seen")
    func oneRulePerMerchant() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try Fixture.onboard(db)
            let groceries = try Fixture.category("Groceries", in: db)

            for merchant in ["WOOLWORTHS", "Woolworths 1234", "WOOLWORTHS SYDNEY AUS"] {
                try MerchantRules().remember(merchant: merchant, categoryID: groceries, in: db)
            }
            #expect(try MerchantRules().all(in: db).count == 1)
        }
    }

    @Test("confirmations are counted, and a correction resets the count")
    func hitCountTracksTheStandingGuess() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try Fixture.onboard(db)
            let groceries = try Fixture.category("Groceries", in: db)
            let eatingOut = try Fixture.category("Eating out", in: db)

            try MerchantRules().remember(merchant: "Corner Shop", categoryID: groceries, in: db)
            try MerchantRules().remember(merchant: "Corner Shop", categoryID: groceries, in: db)
            #expect(try MerchantRules().all(in: db).first?.hitCount == 1)

            // DEC-023 wants "how often was the guess right". That question is only
            // meaningful about one guess, so a new guess starts from nothing rather
            // than inheriting a score it never earned.
            try MerchantRules().remember(merchant: "Corner Shop", categoryID: eatingOut, in: db)
            #expect(try MerchantRules().all(in: db).first?.hitCount == 0)
        }
    }

    @Test("a merchant with nothing name-like in it teaches nothing")
    func unusableMerchantsTeachNothing() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try Fixture.onboard(db)
            let groceries = try Fixture.category("Groceries", in: db)

            #expect(try MerchantRules().remember(merchant: nil, categoryID: groceries, in: db) == false)
            #expect(try MerchantRules().remember(merchant: "  ", categoryID: groceries, in: db) == false)
            #expect(try MerchantRules().remember(merchant: "40213", categoryID: groceries, in: db) == false)

            // A rule keyed on "" would fire for every transaction with no merchant.
            #expect(try MerchantRules().all(in: db).isEmpty)
        }
    }

    @Test("a forgotten merchant can be taught a different answer")
    func deletingFreesTheKey() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            try Fixture.onboard(db)
            let groceries = try Fixture.category("Groceries", in: db)
            let eatingOut = try Fixture.category("Eating out", in: db)

            try MerchantRules().remember(merchant: "Corner Shop", categoryID: groceries, in: db)
            let rule = try #require(try MerchantRules().all(in: db).first)
            try MerchantRules().delete(id: try #require(UUID(uuidString: rule.id)), in: db)
            #expect(try MerchantRules().suggestion(forMerchant: "Corner Shop", in: db) == nil)

            // The unique index is partial on `deleted_at IS NULL` for exactly this:
            // deleting a rule is "stop guessing that", not "never ask again".
            try MerchantRules().remember(merchant: "Corner Shop", categoryID: eatingOut, in: db)
            #expect(try MerchantRules().suggestion(forMerchant: "Corner Shop", in: db) == eatingOut)
        }
    }

    @Test("saving a transaction is what teaches the rule")
    func savingATransactionTeaches() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.onboard(db)
            let groceries = try Fixture.category("Groceries", in: db)
            let draft = TransactionDraft(
                kind: .expense,
                amount: Money(minorUnits: 4500, currency: .aud),
                accountID: account,
                categoryID: groceries,
                merchant: "WOOLWORTHS 1234",
                bookedOn: try #require(CivilDate(iso: "2026-09-02"))
            )

            // The form's save path, in the same order it runs it.
            try TransactionStore().create(draft, in: db)
            try MerchantRules().remember(
                merchant: draft.merchant, categoryID: try #require(draft.effectiveCategoryID), in: db
            )

            #expect(try MerchantRules().suggestion(forMerchant: "Woolworths", in: db) == groceries)
        }
    }

    @Test("income never teaches a rule, because income has no category")
    func incomeTeachesNothing() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.onboard(db)
            let draft = TransactionDraft(
                kind: .income,
                amount: Money(minorUnits: 250_000, currency: .aud),
                accountID: account,
                categoryID: try Fixture.category("Groceries", in: db),
                merchant: "Employer",
                bookedOn: try #require(CivilDate(iso: "2026-09-11"))
            )

            // Rule 9 is enforced by `effectiveCategoryID` returning nil, so there is
            // nothing for the form to remember — the guard is one place, not two.
            #expect(draft.effectiveCategoryID == nil)
            try TransactionStore().create(draft, in: db)
            #expect(try MerchantRules().all(in: db).isEmpty)
        }
    }
}
