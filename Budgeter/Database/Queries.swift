//
//  Queries.swift
//  Budgeter
//
//  What the two screens read. Kept out of the views so that a screen never assembles
//  SQL of its own, and so each of these can be handed to GRDB's `ValueObservation`
//  unchanged — the observation and the one-off fetch are then provably the same
//  query, rather than two that have to be kept in step by hand.
//

import Foundation
import GRDB

/// One row of the ledger list.
nonisolated struct LedgerEntry: Codable, FetchableRecord, Equatable, Sendable, Identifiable {
    var transactionId: String
    var kind: String
    var status: String
    var merchant: String?
    var bookedOn: String
    var occurredAt: String
    var currency: String
    /// Signed for display: money out negative, money in positive.
    var amountMinor: Int64
    var categoryId: String?
    var categoryName: String?
    var accountId: String?
    var accountName: String?

    var id: String {
        transactionId
    }

    enum CodingKeys: String, CodingKey {
        case kind, status, merchant, currency
        case transactionId = "transaction_id"
        case bookedOn = "booked_on"
        case occurredAt = "occurred_at"
        case amountMinor = "amount_minor"
        case categoryId = "category_id"
        case categoryName = "category_name"
        case accountId = "account_id"
        case accountName = "account_name"
    }

    var amount: Money? {
        Currency(rawValue: currency).map { Money(minorUnits: amountMinor, currency: $0) }
    }

    var isDraft: Bool {
        status == TransactionStatus.draft.rawValue
    }
}

/// One category's standing in the current period, with the name attached.
nonisolated struct BudgetLine: Codable, FetchableRecord, Equatable, Sendable, Identifiable {
    var categoryId: String
    var categoryName: String
    var currency: String
    var limitMinor: Int64
    var spentMinor: Int64
    var remainingMinor: Int64

    var id: String {
        categoryId
    }

    enum CodingKeys: String, CodingKey {
        case currency
        case categoryId = "category_id"
        case categoryName = "category_name"
        case limitMinor = "limit_minor"
        case spentMinor = "spent_minor"
        case remainingMinor = "remaining_minor"
    }

    private var money: Currency? {
        Currency(rawValue: currency)
    }

    var limit: Money? {
        money.map { Money(minorUnits: limitMinor, currency: $0) }
    }

    var spent: Money? {
        money.map { Money(minorUnits: spentMinor, currency: $0) }
    }

    var remaining: Money? {
        money.map { Money(minorUnits: remainingMinor, currency: $0) }
    }

    /// Zero when the limit is zero, rather than a division by it.
    var fractionSpent: Double {
        guard limitMinor > 0 else { return spentMinor > 0 ? 1 : 0 }
        return max(0, min(1, Double(spentMinor) / Double(limitMinor)))
    }

    var isOverspent: Bool {
        remainingMinor < 0
    }
}

nonisolated enum Queries {
    /// The whole ledger, newest first. `occurred_at` breaks ties within a day, which
    /// is exactly the job DEC-009 gave it.
    static func ledger(_ db: Database) throws -> [LedgerEntry] {
        try LedgerEntry.fetchAll(db, sql: """
        SELECT * FROM ledger
        ORDER BY booked_on DESC, occurred_at DESC
        """)
    }

    /// The period containing `date`, if it has been generated.
    static func period(containing date: CivilDate, in db: Database) throws -> PeriodRecord? {
        try PeriodRecord.fetchOne(
            db,
            sql: """
            SELECT * FROM periods
             WHERE deleted_at IS NULL AND starts_on <= ? AND ends_on >= ?
             LIMIT 1
            """,
            arguments: [date.iso, date.iso]
        )
    }

    /// Every budgeted category in a period. Categories with no limit do not appear:
    /// a category the user has not budgeted has nothing to report against, and
    /// showing "$40 of $0" reads as a failure rather than as an absence.
    static func budgetLines(periodID: String, in db: Database) throws -> [BudgetLine] {
        try BudgetLine.fetchAll(
            db,
            sql: """
            SELECT s.category_id, c.name AS category_name, s.currency,
                   s.limit_minor, s.spent_minor, s.remaining_minor
              FROM period_category_status s
              JOIN categories c ON c.id = s.category_id AND c.deleted_at IS NULL
             WHERE s.period_id = ?
             ORDER BY c.name
            """,
            arguments: [periodID]
        )
    }

    /// Total spending in a period, across every category — including categories with
    /// no limit, which `budgetLines` deliberately omits. Reads `spending`, so every
    /// exclusion is inherited.
    static func totalSpent(in period: BudgetPeriod, currency: Currency, in db: Database) throws -> Money {
        let total = try Int64.fetchOne(
            db,
            sql: """
            SELECT COALESCE(SUM(amount_minor), 0) FROM spending
             WHERE currency = ? AND booked_on >= ? AND booked_on <= ?
            """,
            arguments: [currency.rawValue, period.startsOn.iso, period.endsOn.iso]
        )
        return Money(minorUnits: total ?? 0, currency: currency)
    }
}
