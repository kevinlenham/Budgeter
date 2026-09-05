//
//  FinancesSnapshot.swift
//  Budgeter
//
//  Everything the Finances screen draws for one window, fetched in a single
//  observation so the heading, the total, the category breakdown and the list of
//  entries can never be a frame out of step with each other.
//
//  The derived properties at the bottom are where the screen's one real rule
//  lives: a limit belongs to a period, so it is shown as a limit only when the
//  window *is* that period, and expressed as a pace at any narrower scale.
//

import GRDB

nonisolated struct FinancesSnapshot: Equatable, Sendable {
    var window: ScaleWindow?
    var cadence: Cadence?
    var currency: Currency?
    var spent: Money?
    var income: Money?
    /// The overall limit of the period this window sits inside, whatever the
    /// window's own scale is. Held even at the day and week scales, where it is not
    /// shown as a limit but is what the pace line is computed from.
    var periodOverall: OverallBudgetLine?
    /// How many days that period runs for, for the same reason.
    var periodDayCount: Int?
    var categories: [CategorySpend] = []
    /// Per-category limits, keyed by category id. Empty away from the period scale.
    var limits: [String: BudgetLine] = [:]
    var entries: [LedgerEntry] = []
    var palette = CategoryPalette()
    var daysRemaining = 0

    init() {}

    init(scale: DateScale, offset: Int, today: CivilDate, in db: Database) throws {
        let settings = try BudgetSettingsStore().load(db)
        cadence = settings.schedule?.cadence
        palette = try CategoryPalette.load(db)

        let window = try ScaleResolver.window(
            scale: scale,
            offset: offset,
            today: today,
            cadence: cadence,
            in: db
        )
        self.window = window
        entries = try InsightQueries.entries(from: window.start, to: window.end, in: db)

        guard let currency = try InsightQueries.primaryCurrency(db) else { return }
        self.currency = currency

        spent = try InsightQueries.spend(from: window.start, to: window.end, currency: currency, in: db)
        income = try InsightQueries.income(from: window.start, to: window.end, currency: currency, in: db)
        categories = try InsightQueries.categorySpend(
            from: window.start,
            to: window.end,
            currency: currency,
            in: db
        )

        // The period the window sits inside — the same record at the period scale,
        // and the enclosing one at the narrower scales. Looked up from the window's
        // first day rather than from today, so stepping back to an old week is
        // measured against the budget that was in force then.
        let period = try window.period ?? Queries.period(containing: window.start, in: db)
        if let period {
            periodOverall = try Queries.overallStatus(periodID: period.id, in: db)
            periodDayCount = period.dates.map { $0.start.daysInclusive(through: $0.end) }

            // Per-category limits are only *shown* at the period scale. See the
            // file comment for why they are not pro-rated onto a single day.
            if window.scale == .period {
                limits = Dictionary(
                    try Queries.budgetLines(periodID: period.id, in: db).map { ($0.categoryId, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
            }
        }

        daysRemaining = SafeToSpend.daysRemaining(
            in: BudgetPeriod(index: 0, startsOn: window.start, endsOn: window.end),
            asOf: today
        )
    }

    // MARK: - Derived

    var isPeriodScale: Bool {
        window?.scale == .period
    }

    /// The overall budget, shown as a limit only when the window *is* the period it
    /// belongs to. At a narrower scale the same figure is still known, but it is
    /// expressed as a pace rather than as a limit this window could exceed.
    var overall: OverallBudgetLine? {
        isPeriodScale ? periodOverall : nil
    }

    /// The limit row for a breakdown row, when one exists and can be edited.
    ///
    /// Returns a zero-limit line for a budgetable category that has no limit yet,
    /// so tapping it opens the editor to set one rather than doing nothing.
    func budgetLine(for row: CategorySpend) -> BudgetLine? {
        guard isPeriodScale, let categoryId = row.categoryId, let currency else { return nil }
        if let existing = limits[categoryId] { return existing }
        return BudgetLine(
            categoryId: categoryId,
            categoryName: row.displayName,
            currency: currency.rawValue,
            limitMinor: 0,
            spentMinor: row.amountMinor,
            remainingMinor: -row.amountMinor
        )
    }

    /// A row's share of the window's total spend, for the inline bar. Falls back to
    /// zero rather than dividing by nothing when the window is empty.
    func share(of row: CategorySpend) -> Double {
        let total = categories.reduce(Int64(0)) { $0 + $1.amountMinor }
        guard total > 0 else { return 0 }
        return Double(row.amountMinor) / Double(total)
    }

    /// What the budget allows over a window narrower than the period.
    ///
    /// The period's overall limit spread evenly across its days, then multiplied by
    /// the days in this window — the same straight-line assumption `SafeToSpend`
    /// makes. Nil without an overall budget, because there is then no pace to be
    /// ahead or behind of.
    var pace: Money? {
        guard let window, window.scale != .period else { return nil }
        guard let limit = periodOverall?.limit else { return nil }
        guard let periodDays = periodDayCount, periodDays > 0 else { return nil }
        guard let perDay = try? limit.allocate(evenly: periodDays).first else { return nil }
        return try? perDay.multiplied(by: Int64(window.dayCount))
    }
}
