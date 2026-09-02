//
//  PeriodScheduleTests.swift
//  BudgeterTests
//
//  The roadmap names the cases that matter for this sprint, and they are all here:
//  monthly anchored on the 31st across February; an app unopened for two months
//  generating eight weekly periods in one call; and generation being deterministic
//  and idempotent by construction.
//
//  Every test in this file is pure — no database, no clock, no time zone.
//

import Foundation
import Testing
@testable import Budgeter

@Suite("Period boundaries")
struct PeriodScheduleTests {
    private func schedule(_ anchor: String, _ cadence: Cadence) throws -> PeriodSchedule {
        PeriodSchedule(anchor: try #require(CivilDate(iso: anchor)), cadence: cadence)
    }

    private func date(_ iso: String) throws -> CivilDate {
        try #require(CivilDate(iso: iso))
    }

    @Test("the anchor starts period zero, and periods run back before it")
    func anchorIsIndexZero() throws {
        let fortnightly = try schedule("2026-03-13", .fortnightly)
        #expect(fortnightly.start(ofIndex: 0).iso == "2026-03-13")
        #expect(fortnightly.start(ofIndex: 1).iso == "2026-03-27")
        #expect(fortnightly.start(ofIndex: -1).iso == "2026-02-27")
        #expect(fortnightly.start(ofIndex: -2).iso == "2026-02-13")
    }

    @Test("a period ends the day before the next one starts, with no gap and no overlap")
    func periodsAbut() throws {
        for cadence in Cadence.allCases {
            let schedule = try schedule("2026-03-13", cadence)
            for index in -30 ... 30 {
                let period = schedule.period(atIndex: index)
                let next = schedule.period(atIndex: index + 1)
                #expect(period.endsOn.addingDays(1) == next.startsOn, "\(cadence) at \(index)")
                #expect(period.endsOn >= period.startsOn)
            }
        }
    }

    @Test("every date lands in exactly one period, on both sides of the anchor")
    func everyDateHasExactlyOnePeriod() throws {
        for cadence in Cadence.allCases {
            let schedule = try schedule("2026-03-13", cadence)
            var date = try date("2025-01-01")
            let end = try self.date("2028-01-01")
            while date < end {
                let period = schedule.period(containing: date)
                #expect(period.contains(date), "\(cadence): \(date.iso) fell outside its own period")
                #expect(!schedule.period(atIndex: period.index - 1).contains(date))
                #expect(!schedule.period(atIndex: period.index + 1).contains(date))
                date = date.addingDays(1)
            }
        }
    }

    @Test("weekly and fortnightly periods are always exactly that long")
    func fixedCadenceLengths() throws {
        for (cadence, length) in [(Cadence.weekly, 7), (Cadence.fortnightly, 14)] {
            let schedule = try schedule("2026-03-13", cadence)
            for index in -30 ... 30 {
                #expect(schedule.period(atIndex: index).lengthInDays == length)
            }
        }
    }

    @Test("monthly anchored on the 31st clamps through February and comes back out at 31 — DEC-007")
    func monthlyOnTheThirtyFirst() throws {
        let schedule = try schedule("2026-01-31", .monthly)
        let starts = (0 ... 12).map { schedule.start(ofIndex: $0).iso }
        #expect(starts == [
            "2026-01-31",
            "2026-02-28", // clamped
            "2026-03-31", // and back to the 31st, not dragged to the 28th
            "2026-04-30",
            "2026-05-31",
            "2026-06-30",
            "2026-07-31",
            "2026-08-31",
            "2026-09-30",
            "2026-10-31",
            "2026-11-30",
            "2026-12-31",
            "2027-01-31",
        ])
    }

    @Test("a February clamp is one day longer in a leap year")
    func monthlyAcrossALeapFebruary() throws {
        let schedule = try schedule("2024-01-31", .monthly)
        #expect(schedule.start(ofIndex: 1).iso == "2024-02-29")
        #expect(schedule.start(ofIndex: 2).iso == "2024-03-31")
    }

    @Test("the short February period is still exactly the days between its boundaries")
    func clampedPeriodLengths() throws {
        let schedule = try schedule("2026-01-31", .monthly)
        let february = schedule.period(atIndex: 1)
        #expect(february.startsOn.iso == "2026-02-28")
        #expect(february.endsOn.iso == "2026-03-30")
        #expect(february.lengthInDays == 31)
    }

    @Test("index and start are inverses of each other, which is what makes generation idempotent")
    func indexAndStartAreInverses() throws {
        for cadence in Cadence.allCases {
            for anchor in ["2026-01-31", "2026-03-13", "2026-02-28", "2024-02-29"] {
                let schedule = try schedule(anchor, cadence)
                for index in -40 ... 40 {
                    let start = schedule.start(ofIndex: index)
                    #expect(
                        schedule.index(containing: start) == index,
                        "\(cadence) anchored \(anchor): index \(index) round-tripped wrong"
                    )
                }
            }
        }
    }

    @Test("today sits in period -1 when the anchor is the user's next payday — DEC-007")
    func anchorInTheFutureStillHasACurrentPeriod() throws {
        let schedule = try schedule("2026-03-13", .fortnightly)
        let today = try date("2026-03-05")
        let period = schedule.period(containing: today)

        #expect(period.index == -1)
        #expect(period.startsOn.iso == "2026-02-27")
        #expect(period.endsOn.iso == "2026-03-12")
        #expect(period.contains(today), "onboarding must not leave the user without a current period")
    }

    @Test("an app unopened for two months generates eight weekly periods in one call — DEC-009")
    func fillsALongGapInOneCall() throws {
        let schedule = try schedule("2026-01-02", .weekly)
        let lastGenerated = schedule.index(containing: try date("2026-01-02"))
        let periods = schedule.periods(fromIndex: lastGenerated + 1, through: try date("2026-03-01"))

        #expect(periods.count == 8)
        #expect(periods.first?.startsOn.iso == "2026-01-09")
        #expect(periods.last?.startsOn.iso == "2026-02-27")
        #expect(periods.last?.contains(try date("2026-03-01")) == true)
        #expect(periods.map(\.index) == Array(1 ... 8))
    }

    @Test("generating with nothing missing returns nothing, so calling it on every launch is free")
    func noGapMeansNoWork() throws {
        let schedule = try schedule("2026-01-02", .weekly)
        let current = schedule.index(containing: try date("2026-01-15"))
        #expect(schedule.periods(fromIndex: current + 1, through: try date("2026-01-15")).isEmpty)
    }
}

@Suite("Pay dates — DEC-036")
struct PayDateTests {
    private func schedule(_ anchor: String, _ cadence: Cadence) throws -> PeriodSchedule {
        PeriodSchedule(anchor: try #require(CivilDate(iso: anchor)), cadence: cadence)
    }

    private func date(_ iso: String) throws -> CivilDate {
        try #require(CivilDate(iso: iso))
    }

    @Test("a year of fortnightly pay is 26 dates, which fits inside iOS's 64-notification cap")
    func aYearOfFortnightlyPay() throws {
        let schedule = try schedule("2026-01-08", .fortnightly)
        let dates = schedule.payDates(from: try date("2026-01-08"), through: try date("2026-12-31"))
        #expect(dates.count == 26)
        #expect(dates.first?.iso == "2026-01-08")
    }

    @Test("both ends of the range are included")
    func rangeIsInclusive() throws {
        let schedule = try schedule("2026-01-08", .fortnightly)
        let dates = schedule.payDates(from: try date("2026-01-08"), through: try date("2026-02-05"))
        #expect(dates.map(\.iso) == ["2026-01-08", "2026-01-22", "2026-02-05"])
    }

    @Test("a range starting mid-cycle skips the pay date that already passed")
    func startsMidCycle() throws {
        let schedule = try schedule("2026-01-08", .fortnightly)
        let dates = schedule.payDates(from: try date("2026-01-09"), through: try date("2026-02-05"))
        #expect(dates.map(\.iso) == ["2026-01-22", "2026-02-05"])
    }

    @Test("monthly pay on the 31st reuses the DEC-007 clamping rule rather than skipping February")
    func monthlyPayOnTheThirtyFirst() throws {
        let schedule = try schedule("2026-01-31", .monthly)
        let dates = schedule.payDates(from: try date("2026-01-31"), through: try date("2026-04-30"))
        #expect(dates.map(\.iso) == ["2026-01-31", "2026-02-28", "2026-03-31", "2026-04-30"])
    }

    @Test("an empty or backwards range yields nothing rather than looping")
    func degenerateRanges() throws {
        let schedule = try schedule("2026-01-08", .weekly)
        #expect(schedule.payDates(from: try date("2026-02-05"), through: try date("2026-01-08")).isEmpty)
        #expect(schedule.payDates(from: try date("2026-01-09"), through: try date("2026-01-14")).isEmpty)
        #expect(schedule.payDates(from: try date("2026-01-15"), through: try date("2026-01-15")).count == 1)
    }
}
