//
//  Records.swift
//  Budgeter
//
//  Read models. Writes are explicit SQL (DEC-003 chose SQL over an ORM), so these
//  deliberately do not carry persistence behaviour beyond fetching.
//

import Foundation
import GRDB

nonisolated struct AccountRecord: Codable, FetchableRecord, Equatable, Sendable {
    static let databaseTableName = "accounts"

    var id: String
    var name: String
    var currency: String
    var createdAt: String
    var updatedAt: String
    var deletedAt: String?
    var changeSeq: Int64

    enum CodingKeys: String, CodingKey {
        case id, name, currency
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case changeSeq = "change_seq"
    }
}

nonisolated struct CategoryRecord: Codable, FetchableRecord, Equatable, Sendable {
    static let databaseTableName = "categories"

    var id: String
    var name: String
    var createdAt: String
    var updatedAt: String
    var deletedAt: String?
    var changeSeq: Int64

    enum CodingKeys: String, CodingKey {
        case id, name
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case changeSeq = "change_seq"
    }
}

nonisolated struct TransactionRecord: Codable, FetchableRecord, Equatable, Sendable {
    static let databaseTableName = "transactions"

    var id: String
    var kind: String
    var status: String
    var amountMinor: Int64
    var currency: String
    var accountId: String?
    var fromAccountId: String?
    var toAccountId: String?
    var categoryId: String?
    var merchant: String?
    var bookedOn: String
    var occurredAt: String
    var source: String
    var dedupeKey: String
    var createdAt: String
    var updatedAt: String
    var deletedAt: String?
    var changeSeq: Int64

    enum CodingKeys: String, CodingKey {
        case id, kind, status, currency, merchant, source
        case amountMinor = "amount_minor"
        case accountId = "account_id"
        case fromAccountId = "from_account_id"
        case toAccountId = "to_account_id"
        case categoryId = "category_id"
        case bookedOn = "booked_on"
        case occurredAt = "occurred_at"
        case dedupeKey = "dedupe_key"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case changeSeq = "change_seq"
    }
}

/// A row of the `spending` view (DEC-010). Amounts are signed here even though the
/// table's are not: expenses positive, refunds negative.
nonisolated struct SpendingRow: Codable, FetchableRecord, Equatable, Sendable {
    var transactionId: String
    var accountId: String?
    var categoryId: String?
    var merchant: String?
    var bookedOn: String
    var occurredAt: String
    var currency: String
    var amountMinor: Int64

    enum CodingKeys: String, CodingKey {
        case transactionId = "transaction_id"
        case accountId = "account_id"
        case categoryId = "category_id"
        case merchant
        case bookedOn = "booked_on"
        case occurredAt = "occurred_at"
        case currency
        case amountMinor = "amount_minor"
    }
}

/// A row of the `postings` view (DEC-028). One transfer produces two of these.
nonisolated struct PostingRow: Codable, FetchableRecord, Equatable, Sendable {
    var transactionId: String
    var accountId: String
    var amountMinor: Int64
    var currency: String
    var bookedOn: String
    var occurredAt: String

    enum CodingKeys: String, CodingKey {
        case transactionId = "transaction_id"
        case accountId = "account_id"
        case amountMinor = "amount_minor"
        case currency
        case bookedOn = "booked_on"
        case occurredAt = "occurred_at"
    }
}
