//
//  InsightQueries.swift
//  Budgeter
//
//  What the Overview, Finances and Statistics screens read.
//
//  Kept beside `Queries` rather than inside it because these all share one shape
//  the older queries do not: they are answered for an arbitrary date range, so the
//  same function serves a day, a week and a whole budget period without the caller
//  choosing between three near-identical queries. The scale selector on the
//  Finances screen is only cheap to build because of that.
//
//  Every spending figure here reads the `spending` view, so rule 9's exclusions —
//  transfers, income, drafts, soft-deleted rows — and refunds netting against
//  expenses arrive already applied. Income is the one exception, and it is
//  justified where it happens.
//

import Foundation
import GRDB

// MARK: - Rows

/// One category's spend over a range, for the breakdown list and the donut.
///
/// `categoryId` is optional because spending with no category is real and must not
/// be silently dropped from a total that claims to be everything.
nonisolated struct CategorySpend: Codable, FetchableRecord, Equatable, Sendable, Identifiable {
    var categoryId: String?
    var categoryName: String?
    var currency: String
    var amountMinor: Int64

    var id: String {
        categoryId ?? "uncategorised"
    }

    enum CodingKeys: String, CodingKey {
        case currency
        case categoryId = "category_id"
        case categoryName = "category_name"
        case amountMinor = "amount_minor"
    }

    var displayName: String {
        categoryName ?? "Uncategorised"
    }

    var amount: Money? {
        Currency(rawValue: currency).map { Money(minorUnits: amountMinor, currency: $0) }
    }
}

/// One day's spend, for the burn-rate chart.
nonisolated struct DailySpend: Codable, FetchableRecord, Equatable, Sendable {
    var bookedOn: String
    var amountMinor: Int64

    enum CodingKeys: String, CodingKey {
        case bookedOn = "booked_on"
        case amountMinor = "amount_minor"
    }

    var date: CivilDate? {
        CivilDate(iso: bookedOn)
    }
}

/// Money in and money out over one budget period, for the income-versus-expenses
/// chart.
nonisolated struct PeriodFlow: Equatable, Sendable, Identifiable {
    var periodId: String
    var startsOn: CivilDate
    var endsOn: CivilDate
    var income: Money
    var expenses: Money

    var id: String {
        periodId
    }

    /// Positive when the period took in more than it spent.
    var surplus: Money? {
        try? income.subtracting(expenses)
    }
}

/// A point on the cumulative burn line, paired with the pace the budget allows on
/// that day.
nonisolated struct BurnPoint: Equatable, Sendable, Identifiable {
    var date: CivilDate
    var spent: Money
    /// `nil` when no overall budget is set — the chart then draws actual spend
    /// alone rather than inventing a target to compare it against.
    var pace: Money?
    /// False for days after today, which are drawn for the pace line only. Actual
    /// spend must stop at today rather than flat-lining to the end of the period,
    /// which would read as "spent nothing for a fortnight".
    var isElapsed: Bool

    var id: String {
        date.iso
    }
}

// MARK: - Queries

nonisolated enum InsightQueries {
    /// The currency the app is working in — the first account's.
    ///
    /// Single-currency by construction today: onboarding creates one account and
    /// `AccountStore` refuses to change its currency. This returns an optional
    /// rather than defaulting to AUD, because a screen that shows dollars for a
    /// database holding pounds is worse than a screen that shows nothing.
    static func primaryCurrency(_ db: Database) throws -> Currency? {
        let code = try String.fetchOne(db, sql: """
        SELECT currency FROM accounts
         WHERE deleted_at IS NULL
         ORDER BY created_at
         LIMIT 1
        """)
        return code.flatMap(Currency.init(rawValue:))
    }

    /// Total spent between two dates, both inclusive.
    static func spend(
        from start: CivilDate,
        to end: CivilDate,
        currency: Currency,
        in db: Database
    ) throws -> Money {
        let total = try Int64.fetchOne(
            db,
            sql: """
            SELECT COALESCE(SUM(amount_minor), 0) FROM spending
             WHERE currency = ? AND booked_on >= ? AND booked_on <= ?
            """,
            arguments: [currency.rawValue, start.iso, end.iso]
        )
        return Money(minorUnits: total ?? 0, currency: currency)
    }

    /// Total income between two dates, both inclusive.
    ///
    /// Reads `transactions` rather than a view, for the reason `lastIncomeBookedOn`
    /// already gives: `spending` excludes income by design and `postings` folds
    /// income together with refunds and transfer legs, so neither can answer "how
    /// much came in". The exclusions are therefore stated here explicitly —
    /// confirmed, not deleted — and kept identical to the ones the views apply.
    static func income(
        from start: CivilDate,
        to end: CivilDate,
        currency: Currency,
        in db: Database
    ) throws -> Money {
        let total = try Int64.fetchOne(
            db,
            sql: """
            SELECT COALESCE(SUM(amount_minor), 0) FROM transactions
             WHERE kind = 'income' AND status = 'confirmed' AND deleted_at IS NULL
               AND currency = ? AND booked_on >= ? AND booked_on <= ?
            """,
            arguments: [currency.rawValue, start.iso, end.iso]
        )
        return Money(minorUnits: total ?? 0, currency: currency)
    }

    /// Ledger rows in a date range, newest first.
    static func entries(
        from start: CivilDate,
        to end: CivilDate,
        in db: Database
    ) throws -> [LedgerEntry] {
        try LedgerEntry.fetchAll(
            db,
            sql: """
            SELECT * FROM ledger
             WHERE booked_on >= ? AND booked_on <= ?
             ORDER BY booked_on DESC, occurred_at DESC
            """,
            arguments: [start.iso, end.iso]
        )
    }

    /// The most recent ledger rows regardless of date, for the Overview card.
    static func recentEntries(limit: Int, in db: Database) throws -> [LedgerEntry] {
        try LedgerEntry.fetchAll(
            db,
            sql: """
            SELECT * FROM ledger
             ORDER BY booked_on DESC, occurred_at DESC
             LIMIT ?
            """,
            arguments: [limit]
        )
    }

    /// Spend per category over a range, biggest first.
    ///
    /// Categories are joined without requiring a match, so spending whose category
    /// was later retired still appears — under its name if the row survives, as
    /// "Uncategorised" if it does not. Dropping it would make the breakdown
    /// disagree with the total beside it, which is the one thing a breakdown must
    /// never do.
    ///
    /// A category whose refunds exceed its expenses nets negative. Those rows are
    /// filtered out rather than drawn, because a donut cannot represent a negative
    /// slice; the total keeps them, so the parts are then knowingly short of the
    /// whole rather than accidentally so.
    static func categorySpend(
        from start: CivilDate,
        to end: CivilDate,
        currency: Currency,
        in db: Database
    ) throws -> [CategorySpend] {
        try CategorySpend.fetchAll(
            db,
            sql: """
            SELECT s.category_id AS category_id,
                   c.name AS category_name,
                   s.currency AS currency,
                   SUM(s.amount_minor) AS amount_minor
              FROM spending s
              LEFT JOIN categories c ON c.id = s.category_id
             WHERE s.currency = ? AND s.booked_on >= ? AND s.booked_on <= ?
             GROUP BY s.category_id, c.name, s.currency
            HAVING SUM(s.amount_minor) > 0
             ORDER BY amount_minor DESC
            """,
            arguments: [currency.rawValue, start.iso, end.iso]
        )
    }

    /// Spend per day over a range. Days with nothing on them are absent, and the
    /// burn chart fills them in — SQLite has no calendar to join against, and
    /// generating one in SQL to return a run of zeroes is work the caller is
    /// already doing as it walks the period.
    static func dailySpend(
        from start: CivilDate,
        to end: CivilDate,
        currency: Currency,
        in db: Database
    ) throws -> [DailySpend] {
        try DailySpend.fetchAll(
            db,
            sql: """
            SELECT booked_on, SUM(amount_minor) AS amount_minor
              FROM spending
             WHERE currency = ? AND booked_on >= ? AND booked_on <= ?
             GROUP BY booked_on
             ORDER BY booked_on
            """,
            arguments: [currency.rawValue, start.iso, end.iso]
        )
    }

    /// The most recent periods, oldest first, up to `limit`.
    ///
    /// Ordered descending in SQL so `LIMIT` takes the newest, then reversed, which
    /// is the order a chart reads left to right.
    static func recentPeriods(limit: Int, upTo date: CivilDate, in db: Database) throws -> [PeriodRecord] {
        let rows = try PeriodRecord.fetchAll(
            db,
            sql: """
            SELECT * FROM periods
             WHERE deleted_at IS NULL AND starts_on <= ?
             ORDER BY starts_on DESC
             LIMIT ?
            """,
            arguments: [date.iso, limit]
        )
        return rows.reversed()
    }

    /// Money in and money out for each of the last `limit` periods.
    static func flows(
        periods limit: Int,
        upTo date: CivilDate,
        currency: Currency,
        in db: Database
    ) throws -> [PeriodFlow] {
        try recentPeriods(limit: limit, upTo: date, in: db).compactMap { record in
            guard let dates = record.dates else { return nil }
            return try PeriodFlow(
                periodId: record.id,
                startsOn: dates.start,
                endsOn: dates.end,
                income: income(from: dates.start, to: dates.end, currency: currency, in: db),
                expenses: spend(from: dates.start, to: dates.end, currency: currency, in: db)
            )
        }
    }

    /// The cumulative-spend line for a period, with the straight-line pace an
    /// overall budget allows drawn against it.
    ///
    /// Pace is the limit spread evenly across the period's days — the same
    /// assumption `SafeToSpend` already makes, restated as a line rather than as a
    /// daily figure. It is a reference, not a forecast: nothing here predicts what
    /// the user will spend tomorrow.
    static func burn(
        in period: (start: CivilDate, end: CivilDate),
        limit: Money?,
        currency: Currency,
        today: CivilDate,
        in db: Database
    ) throws -> [BurnPoint] {
        let daily = try dailySpend(from: period.start, to: period.end, currency: currency, in: db)
        let byDay = Dictionary(daily.map { ($0.bookedOn, $0.amountMinor) }, uniquingKeysWith: +)

        let dayCount = period.start.daysInclusive(through: period.end)
        guard dayCount > 0 else { return [] }

        // Allocated rather than divided, so the pace line lands exactly on the
        // limit on the final day instead of a cent or two short of it.
        let paceSteps = try limit?.allocate(evenly: dayCount)

        var runningSpend: Int64 = 0
        var runningPace = limit.map { Money.zero($0.currency) }

        return try (0 ..< dayCount).map { offset in
            let date = period.start.addingDays(offset)
            runningSpend += byDay[date.iso] ?? 0
            if let step = paceSteps?[offset], let current = runningPace {
                runningPace = try current.adding(step)
            }
            return BurnPoint(
                date: date,
                spent: Money(minorUnits: runningSpend, currency: currency),
                pace: runningPace,
                isElapsed: !(today < date)
            )
        }
    }
}
