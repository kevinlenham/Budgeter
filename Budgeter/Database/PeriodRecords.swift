//
//  PeriodRecords.swift
//  Budgeter
//
//  Read models for migration 002. As in Records.swift, these carry no persistence
//  behaviour: writes go through PeriodGenerator and CategoryLimits, which are the
//  only things that know how to keep the ranges and snapshots consistent.
//

import Foundation
import GRDB

nonisolated struct PeriodRecord: Codable, FetchableRecord, Equatable, Sendable {
    static let databaseTableName = "periods"

    var id: String
    var startsOn: String
    /// Inclusive — the last day inside the period.
    var endsOn: String
    /// The cadence and anchor that produced this row, recorded because a period is
    /// a historical fact rather than a view of today's settings (DEC-007).
    var cadence: String
    var anchorOn: String
    var createdAt: String
    var updatedAt: String
    var deletedAt: String?
    var changeSeq: Int64

    enum CodingKeys: String, CodingKey {
        case id, cadence
        case startsOn = "starts_on"
        case endsOn = "ends_on"
        case anchorOn = "anchor_on"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case changeSeq = "change_seq"
    }

    /// The dates, back in the type that cannot be confused with an instant.
    var dates: (start: CivilDate, end: CivilDate)? {
        guard let start = CivilDate(iso: startsOn), let end = CivilDate(iso: endsOn) else { return nil }
        return (start, end)
    }
}

nonisolated struct CategoryLimitRecord: Codable, FetchableRecord, Equatable, Sendable {
    static let databaseTableName = "category_limits"

    var id: String
    var categoryId: String
    var amountMinor: Int64
    var currency: String
    var effectiveFrom: String
    /// NULL means still in force. Exclusive: the range is [from, to).
    var effectiveTo: String?
    var createdAt: String
    var updatedAt: String
    var deletedAt: String?
    var changeSeq: Int64

    enum CodingKeys: String, CodingKey {
        case id, currency
        case categoryId = "category_id"
        case amountMinor = "amount_minor"
        case effectiveFrom = "effective_from"
        case effectiveTo = "effective_to"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case changeSeq = "change_seq"
    }
}

nonisolated struct PeriodLimitRecord: Codable, FetchableRecord, Equatable, Sendable {
    static let databaseTableName = "period_limits"

    var id: String
    var periodId: String
    var categoryId: String
    var amountMinor: Int64
    var currency: String
    var createdAt: String
    var updatedAt: String
    var deletedAt: String?
    var changeSeq: Int64

    enum CodingKeys: String, CodingKey {
        case id, currency
        case periodId = "period_id"
        case categoryId = "category_id"
        case amountMinor = "amount_minor"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case changeSeq = "change_seq"
    }
}

/// A row of the `period_category_status` view: one category's standing in one
/// period. `spentMinor` is signed the way `spending` signs it, so a category whose
/// refunds outweigh its expenses reports negative spending rather than clamping.
nonisolated struct PeriodCategoryStatusRow: Codable, FetchableRecord, Equatable, Sendable {
    var periodId: String
    var startsOn: String
    var endsOn: String
    var categoryId: String
    var currency: String
    var limitMinor: Int64
    var spentMinor: Int64
    var remainingMinor: Int64

    enum CodingKeys: String, CodingKey {
        case currency
        case periodId = "period_id"
        case startsOn = "starts_on"
        case endsOn = "ends_on"
        case categoryId = "category_id"
        case limitMinor = "limit_minor"
        case spentMinor = "spent_minor"
        case remainingMinor = "remaining_minor"
    }

    func remaining() -> Money? {
        guard let currency = Currency(rawValue: currency) else { return nil }
        return Money(minorUnits: remainingMinor, currency: currency)
    }
}
