//
//  MoneyTextTests.swift
//  BudgeterTests
//
//  Invariant 1 has to survive a text field. A form that round-trips an amount
//  through a binary float has already lost the guarantee, and it loses it quietly —
//  the wrong cent shows up months later in a total nobody can reconcile.
//

import Foundation
import Testing
@testable import Budgeter

@Suite("Parsing typed amounts")
struct MoneyParsingTests {
    private func parse(_ text: String, _ currency: Currency = .aud) throws -> Int64 {
        try MoneyText.money(from: text, currency: currency).minorUnits
    }

    @Test("the ordinary forms all parse exactly")
    func ordinaryForms() throws {
        #expect(try parse("12.50") == 1250)
        #expect(try parse("12.5") == 1250, "one decimal place means tenths, not hundredths")
        #expect(try parse("12") == 1200)
        #expect(try parse("0.05") == 5)
        #expect(try parse(".5") == 50)
        #expect(try parse("0") == 0)
    }

    @Test("the values a float would get wrong are exact here")
    func noFloatingPointDrift() throws {
        // 0.1, 0.29 and 8.31 have no exact binary representation; parsed as Double
        // and multiplied by 100 they yield 9.999…, 28.999… and 830.999….
        #expect(try parse("0.10") == 10)
        #expect(try parse("0.29") == 29)
        #expect(try parse("8.31") == 831)
        #expect(try parse("1.15") == 115)
        #expect(try parse("70.07") == 7007)

        for cents in 0 ... 999 {
            let text = "\(cents / 100).\(String(cents % 100).leftPadded(to: 2, with: "0"))"
            #expect(try parse(text) == Int64(cents), "\(text) parsed wrong")
        }
    }

    @Test("symbols, spaces and grouping separators are ignored")
    func decoration() throws {
        #expect(try parse("$12.50") == 1250)
        #expect(try parse(" 12.50 ") == 1250)
        #expect(try parse("12,50") == 1250, "a comma decimal separator means what it looks like")
    }

    @Test("a negative amount keeps its sign, for callers that allow one")
    func negatives() throws {
        #expect(try parse("-12.50") == -1250)
        #expect(try parse("-0.01") == -1)
    }

    @Test("a currency with no minor unit takes whole numbers only")
    func yen() throws {
        #expect(try parse("1200", .jpy) == 1200)
        #expect(throws: MoneyParseError.tooManyDecimalPlaces(allowed: 0)) {
            try parse("12.5", .jpy)
        }
    }

    @Test("more decimal places than the currency has is refused, not rounded away")
    func tooPrecise() throws {
        #expect(throws: MoneyParseError.tooManyDecimalPlaces(allowed: 2)) {
            try parse("12.345")
        }
    }

    @Test("nonsense is rejected rather than partially read")
    func rejectsNonsense() throws {
        #expect(throws: MoneyParseError.empty) { try parse("") }
        for text in ["abc", "12.3.4", "1e5", "12-50", "--1"] {
            #expect(throws: MoneyParseError.self, "accepted \(text)") { try parse(text) }
        }
    }

    @Test("a trailing separator is the user still typing, but a bare sign is not a number")
    func midTyping() throws {
        #expect(try parse("12.") == 1200)
        #expect(throws: MoneyParseError.self) { try parse("-") }
    }
}

@Suite("Displaying amounts")
struct MoneyFormattingTests {
    @Test("the editable form round-trips exactly, for every cent in a range")
    func editableRoundTrip() throws {
        for minorUnits in Int64(-500) ... 500 {
            let money = Money(minorUnits: minorUnits, currency: .aud)
            let text = MoneyText.editableString(from: money)
            #expect(try MoneyText.money(from: text, currency: .aud) == money, "\(text)")
        }
    }

    @Test("the editable form round-trips large and awkward amounts too")
    func editableRoundTripAwkward() throws {
        for minorUnits in [Int64(1), 9, 10, 99, 100, 101, 1_000_000, 123_456_789, -123_456_789] {
            let money = Money(minorUnits: minorUnits, currency: .aud)
            let text = MoneyText.editableString(from: money)
            #expect(try MoneyText.money(from: text, currency: .aud) == money, "\(text)")
        }
    }

    @Test("the editable form pads the minor unit, so 5 cents is not 50")
    func padding() {
        #expect(MoneyText.editableString(from: Money(minorUnits: 5, currency: .aud)) == "0.05")
        #expect(MoneyText.editableString(from: Money(minorUnits: 50, currency: .aud)) == "0.50")
        #expect(MoneyText.editableString(from: Money(minorUnits: 1250, currency: .aud)) == "12.50")
        #expect(MoneyText.editableString(from: Money(minorUnits: -1250, currency: .aud)) == "-12.50")
    }

    @Test("a currency with no minor unit has no separator at all")
    func yenHasNoDecimalPoint() {
        #expect(MoneyText.editableString(from: Money(minorUnits: 1200, currency: .jpy)) == "1200")
    }

    @Test("the display form shows the currency and the right number of places")
    func display() {
        let australian = Locale(identifier: "en_AU")
        #expect(MoneyText.string(from: Money(minorUnits: 1250, currency: .aud), locale: australian)
            .contains("12.50"))
        #expect(MoneyText.string(from: Money(minorUnits: 1200, currency: .jpy), locale: australian)
            .contains("1,200"))
        #expect(!MoneyText.string(from: Money(minorUnits: 1200, currency: .jpy), locale: australian)
            .contains("1200.00"))
    }
}

@Suite("The clock boundary")
struct CivilDateClockTests {
    @Test("the local day and the UTC day genuinely differ, and booked_on follows the local one")
    func localDayWinsOverTheInstant() throws {
        var melbourne = Calendar(identifier: .gregorian)
        melbourne.timeZone = try #require(TimeZone(identifier: "Australia/Melbourne"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt

        // 11pm on 31 March 2026 in Melbourne. Australia is still on daylight saving
        // (it ends 5 April), so the clock is UTC+11 and this instant is midday UTC —
        // the same calendar day either way. This is the roadmap's case, and it is
        // the easy half.
        let lateEvening = try #require(
            melbourne.date(from: DateComponents(year: 2026, month: 3, day: 31, hour: 23))
        )
        #expect(CivilDate(localDayOf: lateEvening, calendar: melbourne).iso == "2026-03-31")

        // The hard half is the other end of the day, and it is the one that bites:
        // 9am on 1 April in Melbourne is still 31 March in UTC. A period boundary on
        // 1 April would put this purchase in the *previous* period if membership
        // were decided by the instant.
        let earlyMorning = try #require(
            melbourne.date(from: DateComponents(year: 2026, month: 4, day: 1, hour: 9))
        )
        #expect(CivilDate(localDayOf: earlyMorning, calendar: melbourne).iso == "2026-04-01")
        #expect(
            CivilDate(localDayOf: earlyMorning, calendar: utc).iso == "2026-03-31",
            "the same instant is the previous day in UTC — which is the bug booked_on avoids"
        )
    }

    @Test("a day survives the round trip through the picker's Date")
    func middayRoundTrip() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Australia/Melbourne"))

        var date = try #require(CivilDate(iso: "2025-09-01"))
        let end = try #require(CivilDate(iso: "2027-09-01"))
        while date < end {
            let picked = date.middayDate(calendar: calendar)
            #expect(
                CivilDate(localDayOf: picked, calendar: calendar) == date,
                "\(date.iso) did not survive the round trip"
            )
            date = date.addingDays(1)
        }
    }
}
