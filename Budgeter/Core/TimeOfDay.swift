//
//  TimeOfDay.swift
//  Budgeter
//
//  A wall-clock time with no date and no time zone attached, for DEC-036's "fire
//  the payday reminder at 9am".
//
//  The same argument as `CivilDate`, one level down. 9am is not an instant — it is
//  9am wherever the user is standing, on whichever day the reminder lands, and a
//  reminder time stored as a `Date` is a bug waiting for a flight or a DST
//  transition. iOS agrees: `UNCalendarNotificationTrigger` wants `DateComponents`
//  holding an hour and a minute, not a moment.
//

import Foundation

/// An hour and a minute on a 24-hour clock.
nonisolated struct TimeOfDay: Equatable, Hashable, Comparable, Sendable {
    let hour: Int
    let minute: Int

    /// Fails rather than clamps: 25:00 is not a time, and a reminder that silently
    /// became 11:59pm would be indistinguishable from one the user chose.
    init?(hour: Int, minute: Int) {
        guard (0 ... 23).contains(hour), (0 ... 59).contains(minute) else { return nil }
        self.init(clampedHour: hour, minute: minute)
    }

    /// Builds a time that always exists, for the two callers that have no sensible
    /// failure to report: a fixed default, and a `DateComponents` that has already
    /// been produced by `Calendar` and cannot be out of range.
    private init(clampedHour hour: Int, minute: Int) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    /// Parses the storage format, `HH:MM`, exactly as strictly as the CHECK
    /// constraint on `budget_settings.pay_reminder_time` accepts it.
    init?(iso: String) {
        let parts = iso.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let hour = Int(parts[0]), let minute = Int(parts[1])
        else { return nil }
        self.init(hour: hour, minute: minute)
    }

    var iso: String {
        "\(String(format: "%02d", hour)):\(String(format: "%02d", minute))"
    }

    static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
    }
}

nonisolated extension TimeOfDay {
    /// The default offered when the reminder is switched on. Late enough that a
    /// morning deposit has usually landed, early enough to be dealt with before the
    /// day gets away.
    static let defaultReminder = TimeOfDay(clampedHour: 9, minute: 0)

    /// The local time of day `date` falls on. Quarantined here for the same reason
    /// the two `CivilDate` conversions are quarantined in `CivilDate+Clock`: this
    /// is the only direction a `DatePicker`'s instant may travel.
    init(localTimeOf date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        self.init(clampedHour: parts.hour ?? 0, minute: parts.minute ?? 0)
    }

    /// This time on `day`, for handing back to a `DatePicker`.
    func date(on day: CivilDate, calendar: Calendar = .current) -> Date? {
        var parts = DateComponents()
        parts.year = day.year
        parts.month = day.month
        parts.day = day.day
        parts.hour = hour
        parts.minute = minute
        return calendar.date(from: parts)
    }
}
