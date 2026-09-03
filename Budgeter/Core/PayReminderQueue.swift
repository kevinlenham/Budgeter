//
//  PayReminderQueue.swift
//  Budgeter
//
//  Which dates the payday reminder queue should contain. Pure, so the part of
//  DEC-036 that can be tested off-device is tested off-device.
//
//  DEC-036 is explicit about why this is a queue of one-shots rather than a
//  repeating trigger: iOS can express "every Thursday" and "the 15th of every
//  month", but **there is no way to express a 14-day cycle** — the one cadence most
//  Australian salaries actually use. All three cadences therefore use the same
//  rolling queue, so that monthly-on-the-31st reuses DEC-007's clamping rule
//  instead of trusting `UNCalendarNotificationTrigger` to do something defensible
//  in February.
//
//  The queue is topped up on launch, lazily, for the DEC-009 reason: `BGTaskScheduler`
//  runs when iOS chooses, and "why didn't this fire" is not a debugging session
//  worth having twice.
//

import Foundation

nonisolated enum PayReminderQueue {
    /// How many reminders to keep pending.
    ///
    /// iOS caps an app at 64 pending notifications and silently drops the rest.
    /// DEC-036 notes a year of fortnightly pay is 26; this leaves the rest of the
    /// budget unspent rather than claiming it, because DEC-011's daily draft digest
    /// is the other scheduled notification in the design and it will want room.
    static let maximumPending = 32

    /// How far ahead to schedule. A year, which comfortably contains `maximumPending`
    /// reminders at every cadence, so the two limits never fight over which one
    /// truncated the queue.
    static let horizonDays = 366

    /// The dates the queue should hold, soonest first.
    ///
    /// Today is included only when the reminder time has not already gone past:
    /// iOS discards a trigger in the past, so scheduling one is not merely useless
    /// but hides how many pending slots are actually in use.
    ///
    /// Deterministic from its arguments and nothing else — no clock, no database —
    /// which is what makes "an app opened after four months schedules the right
    /// dates" a unit test rather than a four-month wait.
    static func dates(
        schedule: PeriodSchedule,
        today: CivilDate,
        reminderTime: TimeOfDay,
        currentTime: TimeOfDay
    ) -> [CivilDate] {
        let first = reminderTime > currentTime ? today : today.addingDays(1)
        let dates = schedule.payDates(from: first, through: today.addingDays(horizonDays))
        return Array(dates.prefix(maximumPending))
    }
}
