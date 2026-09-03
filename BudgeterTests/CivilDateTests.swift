//
//  CivilDateTests.swift
//  BudgeterTests
//
//  DEC-009's boundary storage rests entirely on this type. If the conversions here
//  are wrong, every period boundary is wrong, and the failure is the quiet kind —
//  a transaction in the wrong month, not a crash.
//

import Foundation
import Testing
@testable import Budgeter

@Suite("CivilDate")
struct CivilDateTests {
    @Test("parses and renders the storage format, and rejects everything else")
    func parsing() {
        #expect(CivilDate(iso: "2026-03-31")?.iso == "2026-03-31")
        #expect(CivilDate(iso: "2026-01-01")?.day == 1)

        // Padding is not cosmetic: SQLite compares these as strings, so an
        // unpadded month would sort "2026-9-01" after "2026-10-01".
        #expect(CivilDate(year: 2026, month: 9, day: 1)?.iso == "2026-09-01")

        #expect(CivilDate(iso: "2026-3-31") == nil, "unpadded")
        #expect(CivilDate(iso: "2026-02-30") == nil, "not a real date")
        #expect(CivilDate(iso: "2026-13-01") == nil, "no thirteenth month")
        #expect(CivilDate(iso: "2026-00-10") == nil, "no zeroth month")
        #expect(CivilDate(iso: "2026-03-31T00:00:00Z") == nil, "an instant is not a date")
        #expect(CivilDate(iso: "not-a-date") == nil)
        #expect(CivilDate(iso: "") == nil)
    }

    @Test("30 February is not a date, and does not quietly become 2 March")
    func invalidDatesAreRejectedRatherThanRolled() {
        #expect(CivilDate(year: 2026, month: 2, day: 30) == nil)
        #expect(CivilDate(year: 2026, month: 4, day: 31) == nil)
        #expect(CivilDate(year: 2026, month: 2, day: 29) == nil, "2026 is not a leap year")
        #expect(CivilDate(year: 2024, month: 2, day: 29) != nil, "2024 is")
    }

    @Test("leap years follow the full Gregorian rule, not just the divisible-by-four half")
    func leapYears() {
        #expect(CivilDate.isLeapYear(2024))
        #expect(!CivilDate.isLeapYear(2026))
        #expect(!CivilDate.isLeapYear(1900), "divisible by 100")
        #expect(CivilDate.isLeapYear(2000), "but divisible by 400")
        #expect(CivilDate.lastDay(ofMonth: 2, year: 2000) == 29)
        #expect(CivilDate.lastDay(ofMonth: 2, year: 1900) == 28)
    }

    @Test("every date round-trips through its serial day, across two centuries")
    func serialRoundTrip() throws {
        var date = try #require(CivilDate(iso: "1970-01-01"))
        let end = try #require(CivilDate(iso: "2170-01-01"))
        var previousSerial = date.serialDay - 1

        while date < end {
            #expect(CivilDate(serialDay: date.serialDay) == date)
            #expect(date.serialDay == previousSerial + 1, "serial days must not skip or repeat")
            previousSerial = date.serialDay
            date = date.addingDays(1)
        }
    }

    @Test("the epoch is where it should be, and dates before it go negative")
    func epoch() {
        #expect(CivilDate(iso: "1970-01-01")?.serialDay == 0)
        #expect(CivilDate(iso: "1969-12-31")?.serialDay == -1)
        #expect(CivilDate(iso: "2000-01-01")?.serialDay == 10957)
    }

    @Test("day arithmetic crosses month, year and leap-day boundaries")
    func dayArithmetic() throws {
        let endOfFebruary = try #require(CivilDate(iso: "2024-02-28"))
        #expect(endOfFebruary.addingDays(1).iso == "2024-02-29", "a leap day exists")
        #expect(endOfFebruary.addingDays(2).iso == "2024-03-01")

        let newYearsEve = try #require(CivilDate(iso: "2026-12-31"))
        #expect(newYearsEve.addingDays(1).iso == "2027-01-01")
        #expect(newYearsEve.addingDays(-1).iso == "2026-12-30")

        let start = try #require(CivilDate(iso: "2026-03-01"))
        let finish = try #require(CivilDate(iso: "2026-03-15"))
        #expect(start.days(until: finish) == 14)
        #expect(finish.days(until: start) == -14, "the count is signed")
        #expect(start.daysInclusive(through: finish) == 15, "both ends counted")
        #expect(start.daysInclusive(through: start) == 1, "one day, not zero")
    }

    @Test("month arithmetic clamps to the end of a shorter month — DEC-007")
    func monthClamping() throws {
        let january31 = try #require(CivilDate(iso: "2026-01-31"))
        #expect(january31.addingMonths(1, preferringDay: 31).iso == "2026-02-28")
        // Non-cumulative: clamping in February must not drag March back to the 28th.
        #expect(january31.addingMonths(2, preferringDay: 31).iso == "2026-03-31")
        #expect(january31.addingMonths(3, preferringDay: 31).iso == "2026-04-30")
        #expect(january31.addingMonths(12, preferringDay: 31).iso == "2027-01-31")

        let leapYear = try #require(CivilDate(iso: "2024-01-31"))
        #expect(leapYear.addingMonths(1, preferringDay: 31).iso == "2024-02-29")
    }

    @Test("month arithmetic runs backwards and across year boundaries")
    func negativeMonths() throws {
        let march = try #require(CivilDate(iso: "2026-03-31"))
        #expect(march.addingMonths(-1, preferringDay: 31).iso == "2026-02-28")
        #expect(march.addingMonths(-3, preferringDay: 31).iso == "2025-12-31")
        #expect(march.addingMonths(-15, preferringDay: 31).iso == "2024-12-31")
    }

    @Test("ordering is chronological, and matches the string ordering SQLite uses")
    func ordering() throws {
        let earlier = try #require(CivilDate(iso: "2026-09-30"))
        let later = try #require(CivilDate(iso: "2026-10-01"))
        #expect(earlier < later)
        #expect(earlier.iso < later.iso, "SQLite compares these as strings; the two orders must agree")

        var date = try #require(CivilDate(iso: "2025-11-01"))
        for _ in 0 ..< 500 {
            let next = date.addingDays(1)
            #expect(date < next)
            #expect(date.iso < next.iso, "\(date.iso) should sort before \(next.iso)")
            date = next
        }
    }
}

@Suite("Calendar week and month anchors — DEC-043")
struct CivilDateCalendarAnchorTests {
    private func date(_ iso: String) throws -> CivilDate {
        try #require(CivilDate(iso: iso))
    }

    @Test("1970-01-01, a known Thursday, has weekday index 3")
    func weekdayIndexMatchesTheEpoch() throws {
        // The one external fact this formula rests on: the Unix epoch was a
        // Thursday. Monday-indexed, that is 3.
        #expect(try date("1970-01-01").weekdayIndex == 3)
    }

    @Test("a full week of weekday indices runs 0 through 6, Monday first")
    func weekdayIndexCyclesThroughAWeek() throws {
        let monday = try date("2026-09-14")
        let indices = (0 ..< 7).map { monday.addingDays($0).weekdayIndex }
        #expect(indices == [0, 1, 2, 3, 4, 5, 6])
    }

    @Test("a Monday's most recent Monday is itself")
    func mondayIsItsOwnMonday() throws {
        let monday = try date("2026-09-14")
        #expect(monday.mostRecentMonday() == monday)
    }

    @Test("every other day of the week resolves to the same Monday")
    func mostRecentMondayIsStableAcrossTheWeek() throws {
        let monday = try date("2026-09-14")
        for offset in 1 ... 6 {
            #expect(monday.addingDays(offset).mostRecentMonday() == monday)
        }
    }

    @Test("start of month is the 1st, whatever day it is asked from")
    func startOfMonth() throws {
        #expect(try date("2026-09-01").startOfMonth() == (try date("2026-09-01")))
        #expect(try date("2026-09-15").startOfMonth() == (try date("2026-09-01")))
        #expect(try date("2026-09-30").startOfMonth() == (try date("2026-09-01")))
    }
}

@Suite("CalendarCadence — DEC-043")
struct CalendarCadenceTests {
    private func date(_ iso: String) throws -> CivilDate {
        try #require(CivilDate(iso: iso))
    }

    @Test("weekly needs no user input: any Monday produces Monday–Sunday forever")
    func weeklyAnchorIsAlwaysAMonday() throws {
        let today = try date("2026-09-16") // a Wednesday
        let anchor = CalendarCadence.anchor(for: .weekly, today: today, isSecondWeek: false)
        #expect(anchor == (try date("2026-09-14")))
        #expect(anchor.weekdayIndex == 0)
    }

    @Test("monthly needs no user input: it is always the 1st of the current month")
    func monthlyAnchorIsAlwaysTheFirst() throws {
        let today = try date("2026-09-16")
        let anchor = CalendarCadence.anchor(for: .monthly, today: today, isSecondWeek: false)
        #expect(anchor == (try date("2026-09-01")))
    }

    @Test("fortnightly's phase choice picks this Monday or last Monday")
    func fortnightlyAnchorUsesThePhaseChoice() throws {
        let today = try date("2026-09-16") // a Wednesday, in the week of 2026-09-14
        let weekOne = CalendarCadence.anchor(for: .fortnightly, today: today, isSecondWeek: false)
        let weekTwo = CalendarCadence.anchor(for: .fortnightly, today: today, isSecondWeek: true)
        #expect(weekOne == (try date("2026-09-14")))
        #expect(weekTwo == (try date("2026-09-07")))
        #expect(weekOne.days(until: weekTwo) == -7)
    }

    @Test("the next natural boundary for weekly and fortnightly is the next Monday")
    func nextNaturalBoundaryForWeekly() throws {
        // 2026-09-11 is a Friday.
        let boundary = CalendarCadence.nextNaturalBoundary(for: .weekly, onOrAfter: try date("2026-09-11"))
        #expect(boundary == (try date("2026-09-14")))
    }

    @Test("a date that already is a Monday is its own boundary")
    func nextNaturalBoundaryIsIdempotentOnAMonday() throws {
        let monday = try date("2026-09-14")
        #expect(CalendarCadence.nextNaturalBoundary(for: .weekly, onOrAfter: monday) == monday)
        #expect(CalendarCadence.nextNaturalBoundary(for: .fortnightly, onOrAfter: monday) == monday)
    }

    @Test("the next natural boundary for monthly is the next 1st")
    func nextNaturalBoundaryForMonthly() throws {
        // 2026-09-11 is not the 1st, so the boundary is 2026-10-01.
        let boundary = CalendarCadence.nextNaturalBoundary(for: .monthly, onOrAfter: try date("2026-09-11"))
        #expect(boundary == (try date("2026-10-01")))
    }

    @Test("the 1st is its own monthly boundary")
    func nextNaturalBoundaryIsIdempotentOnTheFirst() throws {
        let firstOfMonth = try date("2026-10-01")
        #expect(CalendarCadence.nextNaturalBoundary(for: .monthly, onOrAfter: firstOfMonth) == firstOfMonth)
    }

    @Test("the monthly boundary crosses a year, at December")
    func nextNaturalBoundaryCrossesAYear() throws {
        let boundary = CalendarCadence.nextNaturalBoundary(for: .monthly, onOrAfter: try date("2026-12-15"))
        #expect(boundary == (try date("2027-01-01")))
    }
}

@Suite("Integer helpers")
struct IntegerHelperTests {
    @Test("modulo is never negative, unlike %")
    func nonNegativeModulo() {
        #expect((-1).modulo(12) == 11)
        #expect((-12).modulo(12) == 0)
        #expect((-13).modulo(12) == 11)
        #expect(13.modulo(12) == 1)
    }

    @Test("floored division rounds toward negative infinity, unlike /")
    func flooredDivision() {
        #expect(13.flooredDividing(by: 7) == 1)
        #expect(7.flooredDividing(by: 7) == 1)
        #expect(0.flooredDividing(by: 7) == 0)
        // The one that matters: a date one day before the anchor is in period -1.
        #expect((-1).flooredDividing(by: 7) == -1)
        #expect((-7).flooredDividing(by: 7) == -1)
        #expect((-8).flooredDividing(by: 7) == -2)
    }

    @Test("Int64 floored division matches, so an overspend never rounds upward")
    func int64FlooredDivision() {
        #expect(Int64(1000).flooredDividing(by: 3) == 333)
        #expect(Int64(-1000).flooredDividing(by: 3) == -334, "toward negative infinity, not toward zero")
        #expect(Int64(-999).flooredDividing(by: 3) == -333)
    }
}
