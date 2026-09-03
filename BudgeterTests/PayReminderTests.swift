//
//  PayReminderTests.swift
//  BudgeterTests
//
//  DEC-036, all of it that can be tested without a phone and a payday.
//
//  DEC-036 is explicit that "scheduling behaviour is device-only — the simulator
//  proves nothing useful and full verification needs a real payday. The pure
//  date-queue function must therefore be a plain unit test off-device, leaving only
//  the thin `UNUserNotificationCenter` binding unverified." This is that test, plus
//  the card that has to keep working when the notification does not.
//

import Foundation
import Testing
@testable import Budgeter

@Suite("Payday reminder queue")
struct PayReminderQueueTests {
    private func date(_ iso: String) throws -> CivilDate {
        try #require(CivilDate(iso: iso))
    }

    private func time(_ iso: String) throws -> TimeOfDay {
        try #require(TimeOfDay(iso: iso))
    }

    private func schedule(_ anchor: String, _ cadence: Cadence) throws -> PeriodSchedule {
        PeriodSchedule(anchor: try date(anchor), cadence: cadence)
    }

    @Test("a fortnightly cycle is a queue of one-shots, fourteen days apart")
    func fortnightlyQueue() throws {
        // The cadence iOS cannot express as a repeating trigger, and the reason
        // DEC-036 uses a rolling queue for all three rather than two mechanisms.
        let dates = PayReminderQueue.dates(
            schedule: try schedule("2026-09-11", .fortnightly),
            today: try date("2026-09-01"),
            reminderTime: try time("09:00"),
            currentTime: try time("08:00")
        )
        #expect(dates.prefix(3) == [
            try date("2026-09-11"), try date("2026-09-25"), try date("2026-10-09"),
        ])
    }

    @Test("today is included only while the reminder time is still ahead")
    func todayIncludedOnlyBeforeItsTime() throws {
        let payday = try date("2026-09-11")
        let onSchedule = try schedule("2026-09-11", .fortnightly)

        let beforeNine = PayReminderQueue.dates(
            schedule: onSchedule, today: payday,
            reminderTime: try time("09:00"), currentTime: try time("07:30")
        )
        #expect(beforeNine.first == payday)

        // iOS discards a trigger in the past, so scheduling one is not merely
        // useless — it hides how many of the 64 pending slots are really in use.
        let afterNine = PayReminderQueue.dates(
            schedule: onSchedule, today: payday,
            reminderTime: try time("09:00"), currentTime: try time("09:30")
        )
        #expect(afterNine.first == try date("2026-09-25"))
    }

    @Test("the queue stays well inside the 64 pending notifications iOS allows")
    func queueIsCapped() throws {
        // Weekly is the worst case: 52 a year, against a cap of 64 shared with
        // every other notification the app will ever schedule.
        let dates = PayReminderQueue.dates(
            schedule: try schedule("2026-09-11", .weekly),
            today: try date("2026-09-01"),
            reminderTime: try time("09:00"),
            currentTime: try time("08:00")
        )
        #expect(dates.count == PayReminderQueue.maximumPending)
        #expect(dates.count < 64)
    }

    @Test("monthly on the 31st clamps in February rather than skipping it")
    func monthlyClampsInFebruary() throws {
        let dates = PayReminderQueue.dates(
            schedule: try schedule("2027-01-31", .monthly),
            today: try date("2027-01-01"),
            reminderTime: try time("09:00"),
            currentTime: try time("08:00")
        )
        // The same clamping rule as `generatePeriods`, reused rather than
        // reimplemented — which is why DEC-036 put pay dates in `PeriodSchedule`.
        #expect(dates.prefix(3) == [
            try date("2027-01-31"), try date("2027-02-28"), try date("2027-03-31"),
        ])
    }

    @Test("an app unopened for months schedules from today, not from the backlog")
    func noBacklogScheduled() throws {
        let dates = PayReminderQueue.dates(
            schedule: try schedule("2026-01-15", .fortnightly),
            today: try date("2026-09-01"),
            reminderTime: try time("09:00"),
            currentTime: try time("08:00")
        )
        // Paydays that have already gone by cannot be notified about. That is the
        // in-app card's job, not the queue's.
        let today = try date("2026-09-01")
        #expect(dates.allSatisfy { $0 >= today })
    }
}

@Suite("The unlogged-pay card")
struct PayStatusTests {
    private func date(_ iso: String) throws -> CivilDate {
        try #require(CivilDate(iso: iso))
    }

    private func schedule(_ anchor: String) throws -> PeriodSchedule {
        PeriodSchedule(anchor: try date(anchor), cadence: .fortnightly)
    }

    @Test("no schedule means nothing to complain about")
    func noScheduleIsQuiet() throws {
        #expect(
            PayStatus.evaluate(
                paySchedule: nil, lastIncomeBookedOn: nil, today: try date("2026-09-20")
            ) == .upToDate
        )
    }

    @Test("a fresh install is not greeted with a payday it was never running for")
    func freshInstallIsQuiet() throws {
        // Onboarding asks for the user's *next* payday (DEC-007), so on day one
        // every payday the arithmetic can produce is before the app existed.
        // Complaining about one would be the app being wrong about its own age.
        let status = PayStatus.evaluate(
            paySchedule: try schedule("2026-09-11"),
            lastIncomeBookedOn: nil,
            today: try date("2026-09-03")
        )
        #expect(status == .upToDate)
    }

    @Test("a payday that has gone by unlogged raises the card")
    func unloggedPaydayRaisesCard() throws {
        let status = PayStatus.evaluate(
            paySchedule: try schedule("2026-09-11"),
            lastIncomeBookedOn: nil,
            today: try date("2026-09-15")
        )
        #expect(status == .unlogged(since: try date("2026-09-11")))
    }

    @Test("logging the pay clears it")
    func loggingClearsCard() throws {
        let status = PayStatus.evaluate(
            paySchedule: try schedule("2026-09-11"),
            lastIncomeBookedOn: try date("2026-09-11"),
            today: try date("2026-09-15")
        )
        #expect(status == .upToDate)
    }

    @Test("being paid early still counts as that payday's pay")
    func earlyPayCounts() throws {
        // DEC-036: "Australian payroll pays early ahead of weekends and public
        // holidays, so a one- or two-day miss is normal, not a bug." Without the
        // tolerance the app claims on Saturday that nothing was logged, having
        // watched the user log it on Thursday.
        let status = PayStatus.evaluate(
            paySchedule: try schedule("2026-09-12"),
            lastIncomeBookedOn: try date("2026-09-10"),
            today: try date("2026-09-14")
        )
        #expect(status == .upToDate)
    }

    @Test("the card waits a day rather than complaining on the morning of payday")
    func graceOnTheDayItself() throws {
        let payday = try date("2026-09-11")
        // The previous payday was logged, so the only question is this one.
        let previous = try date("2026-08-28")

        #expect(
            PayStatus.evaluate(
                paySchedule: try schedule("2026-09-11"), lastIncomeBookedOn: previous, today: payday
            ) == .upToDate,
            "at 9am on payday the money may not have landed yet"
        )
        #expect(
            PayStatus.evaluate(
                paySchedule: try schedule("2026-09-11"),
                lastIncomeBookedOn: previous,
                today: payday.addingDays(1)
            ) == .unlogged(since: payday)
        )
    }

    @Test("months of silence name the most recent payday, not the oldest")
    func namesTheLatestMissedPayday() throws {
        let status = PayStatus.evaluate(
            paySchedule: try schedule("2026-01-16"),
            lastIncomeBookedOn: try date("2026-01-16"),
            today: try date("2026-09-01")
        )
        // Anything else tells the user they have not been paid since January, which
        // is true and useless.
        #expect(status == .unlogged(since: try date("2026-08-28")))
    }

    @Test("pay logged after the last payday keeps the card away")
    func laterPayIsFine() throws {
        let status = PayStatus.evaluate(
            paySchedule: try schedule("2026-09-11"),
            lastIncomeBookedOn: try date("2026-09-26"),
            today: try date("2026-09-27")
        )
        #expect(status == .upToDate)
    }
}

@Suite("Times of day")
struct TimeOfDayTests {
    @Test("the storage format round-trips")
    func roundTrip() {
        for iso in ["00:00", "09:00", "09:05", "23:59"] {
            #expect(TimeOfDay(iso: iso)?.iso == iso)
        }
    }

    @Test("anything that is not a real time is rejected")
    func invalidTimesRejected() {
        // The same strictness as the CHECK on `budget_settings.pay_reminder_time`,
        // which admits neither of these.
        #expect(TimeOfDay(iso: "24:00") == nil)
        #expect(TimeOfDay(iso: "09:60") == nil)
        #expect(TimeOfDay(iso: "9:00") == nil)
        #expect(TimeOfDay(iso: "0900") == nil)
        #expect(TimeOfDay(hour: 25, minute: 0) == nil)
    }

    @Test("times order by the clock")
    func ordering() throws {
        let morning = try #require(TimeOfDay(iso: "09:00"))
        let evening = try #require(TimeOfDay(iso: "18:30"))
        #expect(morning < evening)
    }
}
