//
//  CivilDate+Clock.swift
//  Budgeter
//
//  The only place in the app where a `Date` and a `CivilDate` are allowed to meet.
//
//  `CivilDate` has no time zone precisely so that the DST bug DEC-009 describes
//  cannot be written. But two things outside our control speak in instants: the
//  system clock, and `DatePicker`. Both conversions are therefore quarantined here,
//  each taking an explicit `Calendar` rather than reaching for `.current` invisibly,
//  so that a reader looking for "where could a time zone get this wrong" has exactly
//  one file to read.
//
//  Nothing here is ever stored. A `Date` that arrives from the picker is turned into
//  its local calendar day immediately and then discarded — it never reaches
//  `booked_on`, which is the rule the whole design rests on.
//

import Foundation

nonisolated extension CivilDate {
    /// The calendar day `date` falls on, in `calendar`'s time zone.
    ///
    /// 11pm on 31 March in Melbourne is 31 March here, even though the same instant
    /// is already 1 April in UTC. That is the correct reading: the user bought
    /// something on the 31st, and which period it belongs to follows from that.
    init(localDayOf date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(
            year: parts.year ?? 1970,
            month: parts.month ?? 1,
            clampedDay: parts.day ?? 1
        )
    }

    /// Today, as the user's calendar sees it.
    static func today(calendar: Calendar = .current, now: Date = Date()) -> CivilDate {
        CivilDate(localDayOf: now, calendar: calendar)
    }

    /// Noon on this day, for handing back to a `DatePicker`.
    ///
    /// Noon rather than midnight deliberately: on the one day a year a time zone
    /// skips its midnight hour, `startOfDay` is not the instant you asked for, and
    /// the picker can land on the previous day. Midday is never skipped.
    func middayDate(calendar: Calendar = .current) -> Date {
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = 12
        return calendar.date(from: parts) ?? Date()
    }
}
