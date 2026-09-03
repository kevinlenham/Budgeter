//
//  BackupExporter.swift
//  Budgeter
//
//  Reading the whole database out, in two formats with two different jobs.
//
//  **JSON** is the backup: every table, every column, tombstones included, and the
//  only one of the two that `BackupImporter` reads back. This is what makes DEC-002's
//  "durability only, no sync" an actual position rather than an assumption.
//
//  **CSV** is for everyone else — a spreadsheet, an accountant, another budgeting
//  app. It is lossy by design: one row per transaction, names instead of ids, and
//  no attempt to represent settings, periods or limit history. Nothing reads it
//  back, so it is free to be readable rather than faithful.
//
//  Every query orders by `id`, which is a UUIDv7 (DEC-006) and therefore orders by
//  creation time. So the export is both deterministic and in an order a human
//  scrolling the file would expect.
//

import Foundation
import GRDB

nonisolated struct BackupExporter: Sendable {
    var now: @Sendable () -> Date = { Date() }

    // MARK: - JSON

    func document(from db: Database) throws -> BackupDocument {
        BackupDocument(
            version: BackupDocument.currentVersion,
            exportedAt: IngestFunnel.iso8601.format(now()),
            settings: BackupSettings(try BudgetSettingsStore().load(db)),
            accounts: try AccountRecord.fetchAll(db, sql: "SELECT * FROM accounts ORDER BY id"),
            categories: try CategoryRecord.fetchAll(db, sql: "SELECT * FROM categories ORDER BY id"),
            categoryLimits: try CategoryLimitRecord.fetchAll(
                db, sql: "SELECT * FROM category_limits ORDER BY id"
            ),
            periods: try PeriodRecord.fetchAll(db, sql: "SELECT * FROM periods ORDER BY id"),
            periodLimits: try PeriodLimitRecord.fetchAll(
                db, sql: "SELECT * FROM period_limits ORDER BY id"
            ),
            merchantRules: try MerchantRuleRecord.fetchAll(
                db, sql: "SELECT * FROM merchant_rules ORDER BY id"
            ),
            transactions: try TransactionRecord.fetchAll(db, sql: "SELECT * FROM transactions ORDER BY id")
        )
    }

    func json(from db: Database) throws -> Data {
        try BackupCoding.encoder().encode(document(from: db))
    }

    // MARK: - CSV

    /// One row per transaction, in the shape a person opening it in a spreadsheet
    /// expects: newest last, amounts signed the way the ledger shows them, and
    /// dates as plain `YYYY-MM-DD` rather than instants.
    ///
    /// Soft-deleted rows are omitted here, unlike in the JSON. The two formats have
    /// different jobs: a backup must remember what was deleted (DEC-005), and a
    /// spreadsheet of a person's spending must not include purchases they told the
    /// app to forget.
    func csv(from db: Database) throws -> String {
        let rows = try LedgerEntry.fetchAll(db, sql: """
        SELECT * FROM ledger ORDER BY booked_on, occurred_at
        """)

        var lines = [Self.csvHeader.joined(separator: ",")]
        for row in rows {
            lines.append(
                [
                    row.bookedOn,
                    row.kind,
                    row.status,
                    row.accountName ?? "",
                    row.categoryName ?? "",
                    row.merchant ?? "",
                    row.currency,
                    Self.plainAmount(row),
                    row.occurredAt,
                    row.transactionId,
                ]
                .map(Self.quoted)
                .joined(separator: ",")
            )
        }
        // A trailing newline, so the file ends the way every other tool writes one.
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Private

    private static let csvHeader = [
        "date", "kind", "status", "account", "category", "merchant",
        "currency", "amount", "occurred_at", "id",
    ]

    /// The amount as digits and a decimal point, with no currency symbol and no
    /// thousands separator — `MoneyText.editableString`, which exists precisely
    /// because the locale-formatted version is for reading, not for parsing.
    /// A spreadsheet must be handed the machine-readable one.
    private static func plainAmount(_ row: LedgerEntry) -> String {
        row.amount.map { MoneyText.editableString(from: $0) } ?? ""
    }

    /// RFC 4180 quoting. Applied to every field rather than only the ones that need
    /// it: a merchant containing a comma is not an edge case in this data, and a
    /// rule with no exceptions is a rule nobody has to check.
    private static func quoted(_ field: String) -> String {
        "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
