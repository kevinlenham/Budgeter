//
//  BudgetSnapshot.swift
//  Budgeter
//
//  The whole state of a period's budget in one value, fetched in one observation so
//  the period, the overall line, the category lines and the leftover categories can
//  never be a frame out of step with each other.
//
//  It lived in the old Budget screen until that screen was folded into Finances.
//  It is pure data with no view attached, so it moved here rather than being
//  rewritten — the tests that assert on it are asserting about the budget, not
//  about a tab that no longer exists.
//

import GRDB

nonisolated struct BudgetSnapshot: Equatable, Sendable {
    var period: PeriodRecord?
    var cadence: Cadence?
    var overall: OverallBudgetLine?
    var lines: [BudgetLine] = []
    var unbudgeted: [CategoryRecord] = []

    init(today: CivilDate, in db: Database) throws {
        let settings = try BudgetSettingsStore().load(db)
        cadence = settings.schedule?.cadence

        let categories = try CategoryStore().all(in: db)
        guard let record = try Queries.period(containing: today, in: db) else {
            unbudgeted = categories
            return
        }
        period = record
        overall = try Queries.overallStatus(periodID: record.id, in: db)
        lines = try Queries.budgetLines(periodID: record.id, in: db)
        let budgeted = Set(lines.map(\.categoryId))
        unbudgeted = categories.filter { !budgeted.contains($0.id) }
    }
}
