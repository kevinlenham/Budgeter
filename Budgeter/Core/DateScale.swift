//
//  DateScale.swift
//  Budgeter
//
//  The three zoom levels the Finances screen works at: a day, a week, and one
//  budget period.
//
//  The third one is deliberately the *budget period* rather than a calendar month.
//  A month is the familiar unit, but this app budgets on a cadence the user chose,
//  and on a fortnightly cadence a calendar-month total reconciles with nothing else
//  in the app — not the limits, not the Budget figures, not the Statistics. So the
//  widest scale is the period, and it takes its name from the cadence: "Fortnight"
//  on a fortnightly budget, "Month" on a monthly one. On a weekly cadence the
//  period *is* the week, and the scale collapses to two rather than showing the
//  same range twice under two names.
//
//  A window is resolved against the database rather than computed, because the
//  period scale has to find real `periods` rows. Day and week could be pure date
//  maths, and are — they simply take the same route so the screen has one code path.
//

import Foundation
import GRDB

nonisolated enum DateScale: String, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case period

    var id: String { rawValue }

    /// What the segment reads. The period segment borrows the cadence's name,
    /// because "Period" is jargon and "Fortnight" is not.
    func title(cadence: Cadence?) -> String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .period:
            switch cadence {
            case .monthly: "Month"
            case .fortnightly: "Fortnight"
            case .weekly, .none: "Period"
            }
        }
    }

    /// The scales worth offering for a cadence. A weekly budget drops the period
    /// scale, which would otherwise duplicate the week.
    static func available(for cadence: Cadence?) -> [DateScale] {
        cadence == .weekly ? [.day, .week] : allCases
    }
}

/// A resolved range: which days it covers, what to call it, and whether stepping
/// further in either direction leads anywhere.
nonisolated struct ScaleWindow: Equatable, Sendable {
    var scale: DateScale
    var start: CivilDate
    var end: CivilDate
    var title: String
    /// False at the newest window, so the forward chevron can be disabled rather
    /// than walking the user into empty future ranges.
    var canGoForward: Bool
    /// The period this window belongs to, when the window is a whole period.
    /// Carried so the screen can show limits without looking the period up again.
    var period: PeriodRecord?

    var dayCount: Int {
        start.daysInclusive(through: end)
    }

    func contains(_ date: CivilDate) -> Bool {
        !(date < start) && !(end < date)
    }
}

nonisolated enum ScaleResolver {
    /// Resolves `scale` stepped `offset` windows back from today. `offset` is zero
    /// or negative; the screen never steps forward past the current window.
    static func window(
        scale: DateScale,
        offset: Int,
        today: CivilDate,
        cadence: Cadence?,
        in db: Database
    ) throws -> ScaleWindow {
        switch scale {
        case .day:
            let date = today.addingDays(offset)
            return ScaleWindow(
                scale: .day,
                start: date,
                end: date,
                title: dayTitle(date, today: today),
                canGoForward: offset < 0,
                period: nil
            )

        case .week:
            let start = today.mostRecentMonday().addingDays(offset * 7)
            let end = start.addingDays(6)
            return ScaleWindow(
                scale: .week,
                start: start,
                end: end,
                title: weekTitle(start: start, end: end, offset: offset),
                canGoForward: offset < 0,
                period: nil
            )

        case .period:
            return try periodWindow(offset: offset, today: today, cadence: cadence, in: db)
        }
    }

    // MARK: - Period

    /// Walks back through generated periods. Falls back to the current period when
    /// the user steps past the oldest one that exists — the alternative is an empty
    /// screen with no way to tell that it is empty because there is no such period
    /// rather than because nothing was spent.
    private static func periodWindow(
        offset: Int,
        today: CivilDate,
        cadence: Cadence?,
        in db: Database
    ) throws -> ScaleWindow {
        let records = try PeriodRecord.fetchAll(
            db,
            sql: """
            SELECT * FROM periods
             WHERE deleted_at IS NULL AND starts_on <= ?
             ORDER BY starts_on DESC
             LIMIT ?
            """,
            arguments: [today.iso, -offset + 1]
        )

        guard let record = records.last, let dates = record.dates else {
            // No periods generated yet. The whole of today is the honest answer.
            return ScaleWindow(
                scale: .period,
                start: today,
                end: today,
                title: DateScale.period.title(cadence: cadence),
                canGoForward: false,
                period: nil
            )
        }

        let isCurrent = !(today < dates.start) && !(dates.end < today)
        return ScaleWindow(
            scale: .period,
            start: dates.start,
            end: dates.end,
            title: isCurrent ? "This \(DateScale.period.title(cadence: cadence).lowercased())"
                : rangeTitle(start: dates.start, end: dates.end),
            canGoForward: offset < 0,
            period: record
        )
    }

    // MARK: - Titles

    private static func dayTitle(_ date: CivilDate, today: CivilDate) -> String {
        switch date.days(until: today) {
        case 0: "Today"
        case 1: "Yesterday"
        default: date.middayDate().formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
    }

    private static func weekTitle(start: CivilDate, end: CivilDate, offset: Int) -> String {
        switch offset {
        case 0: "This week"
        case -1: "Last week"
        default: rangeTitle(start: start, end: end)
        }
    }

    private static func rangeTitle(start: CivilDate, end: CivilDate) -> String {
        let from = start.middayDate().formatted(.dateTime.day().month(.abbreviated))
        let to = end.middayDate().formatted(.dateTime.day().month(.abbreviated))
        return "\(from) – \(to)"
    }
}
