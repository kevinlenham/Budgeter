//
//  CivilDate.swift
//  Budgeter
//
//  DEC-009 stores every boundary as a local `YYYY-MM-DD` DATE, because a boundary
//  held as an instant shifts by an hour at each Australian DST transition and puts
//  transactions near midnight into the wrong period twice a year.
//
//  Foundation's `Date` is the specific hazard: it is a UTC instant wearing a
//  local-time costume, and every conversion to or from it needs a time zone that
//  someone has to remember to supply. So this type does not contain one. It is three
//  integers and pure integer arithmetic — a calendar date, with no instant, no zone
//  and no clock anywhere in it. The DST bug is not defended against here; it is
//  unrepresentable.
//
//  The two conversions are Howard Hinnant's `days_from_civil` / `civil_from_days`
//  (the algorithms behind C++20's <chrono>), which are exact for all proleptic
//  Gregorian dates and rely only on truncating integer division — which is what
//  Swift's `/` does, the same as the C++ they were written for.
//

import Foundation

/// A date on the calendar: the kind of date a human writes on a receipt.
///
/// Ordering is chronological, so `booked_on` range checks are the same comparison
/// in Swift and in SQLite — where `YYYY-MM-DD` strings compare chronologically too.
nonisolated struct CivilDate: Equatable, Hashable, Comparable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    // MARK: - Construction

    /// Fails rather than rolls over: 30 February is not a date, and silently
    /// becoming 2 March is how a boundary ends up in the wrong month.
    init?(year: Int, month: Int, day: Int) {
        guard (1 ... 12).contains(month) else { return nil }
        guard day >= 1, day <= Self.lastDay(ofMonth: month, year: year) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Builds a date that always exists, by pulling the day back to the end of the
    /// month when it overshoots. This is DEC-007's clamping rule: a monthly budget
    /// anchored on the 31st lands on 28 February, and does so without mutating the
    /// anchor it was computed from.
    init(year: Int, month: Int, clampedDay day: Int) {
        let normalisedMonth = min(max(month, 1), 12)
        self.year = year
        self.month = normalisedMonth
        self.day = min(max(day, 1), Self.lastDay(ofMonth: normalisedMonth, year: year))
    }

    /// Parses the storage format, strictly. Anything that is not exactly
    /// `YYYY-MM-DD`, and a real date, is rejected.
    init?(iso: String) {
        let parts = iso.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    /// The storage format (DEC-009), zero-padded so string ordering is date ordering.
    var iso: String {
        let paddedMonth = month < 10 ? "0\(month)" : "\(month)"
        let paddedDay = day < 10 ? "0\(day)" : "\(day)"
        return "\(paddedYear)-\(paddedMonth)-\(paddedDay)"
    }

    private var paddedYear: String {
        guard year >= 0, year < 10000 else { return "\(year)" }
        return String(format: "%04d", year)
    }

    // MARK: - Arithmetic

    /// Days since 1970-01-01. Internal currency for every date calculation here:
    /// once a date is an integer, "how many days between" and "what is 14 days later"
    /// stop being calendar questions.
    var serialDay: Int {
        Self.serialDay(year: year, month: month, day: day)
    }

    init(serialDay: Int) {
        self = Self.civil(fromSerialDay: serialDay)
    }

    func addingDays(_ count: Int) -> CivilDate {
        CivilDate(serialDay: serialDay + count)
    }

    /// Signed day count from this date to `other`. Negative if `other` is earlier.
    func days(until other: CivilDate) -> Int {
        other.serialDay - serialDay
    }

    /// Day count treating both ends as counted, which is what "days remaining in
    /// this period" means to a person: on the last day, one day remains, not zero.
    func daysInclusive(through other: CivilDate) -> Int {
        days(until: other) + 1
    }

    /// Months are not a fixed number of days, so month arithmetic is done on the
    /// month number and the day is clamped afterwards.
    ///
    /// `preferringDay` is the *anchor's* day, never this date's. Feeding a
    /// previously-clamped day back in is the classic bug: anchored on the 31st,
    /// January → February clamps to the 28th, and stepping on from 28 February
    /// would give 28 March instead of 31 March, quietly walking the anchor
    /// backwards forever.
    func addingMonths(_ count: Int, preferringDay: Int) -> CivilDate {
        let total = (year * 12 + (month - 1)) + count
        return CivilDate(
            year: total.flooredDividing(by: 12),
            month: total.modulo(12) + 1,
            clampedDay: preferringDay
        )
    }

    // MARK: - Calendar facts

    static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    static func lastDay(ofMonth month: Int, year: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: 31
        case 4, 6, 9, 11: 30
        case 2: isLeapYear(year) ? 29 : 28
        default: 0
        }
    }

    // MARK: - Comparable

    static func < (lhs: CivilDate, rhs: CivilDate) -> Bool {
        lhs.serialDay < rhs.serialDay
    }

    // MARK: - Hinnant's civil/serial conversions

    private static func serialDay(year: Int, month: Int, day: Int) -> Int {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func civil(fromSerialDay serial: Int) -> CivilDate {
        let shifted = serial + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let month = monthPrime + (monthPrime < 10 ? 3 : -9)
        // The algorithm only ever produces a real date, so the clamping initialiser
        // is a total function here rather than a fallback.
        return CivilDate(year: month <= 2 ? year + 1 : year, month: month, clampedDay: day)
    }
}

nonisolated extension Int {
    /// Remainder that is always non-negative, unlike `%`, which follows the sign of
    /// the dividend. Month indices go negative for dates before the anchor.
    func modulo(_ divisor: Int) -> Int {
        let remainder = self % divisor
        return remainder < 0 ? remainder + divisor : remainder
    }

    /// Division that rounds toward negative infinity, unlike `/`, which truncates
    /// toward zero. A date one day before the anchor is in period -1, not period 0.
    func flooredDividing(by divisor: Int) -> Int {
        let quotient = self / divisor
        return (self % divisor != 0 && (self < 0) != (divisor < 0)) ? quotient - 1 : quotient
    }
}
