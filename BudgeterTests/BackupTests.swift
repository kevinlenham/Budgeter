//
//  BackupTests.swift
//  BudgeterTests
//
//  DEC-002's durability, which is only as real as this file makes it.
//
//  The roadmap's "done when" for the export half of Sprint 4: *exporting and
//  re-importing produces an identical dataset with zero duplicate rows.* Both halves
//  are asserted here — byte-for-byte identity of a re-export, and a second import
//  that inserts nothing at all.
//

import Foundation
import GRDB
import Testing
@testable import Budgeter

@Suite("Backup, export and restore")
struct BackupTests {
    /// A fixed clock, so two exports of the same data are the same bytes and the
    /// only thing a difference can mean is a difference in the data.
    private let clock: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_788_000_000) }

    private func date(_ iso: String) throws -> CivilDate {
        try #require(CivilDate(iso: iso))
    }

    /// A database with something of every kind in it: two accounts, limits, a
    /// merchant rule, a confirmed expense, an income row, and a deleted transaction.
    private func populated() throws -> AppDatabase {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.onboard(db)
            let savings = try AccountStore().create(name: "Savings", currency: .aud, in: db)
            let groceries = try Fixture.category("Groceries", in: db)

            try CategoryLimits().setLimit(
                categoryID: groceries,
                amount: Money(minorUnits: 50000, currency: .aud),
                effectiveFrom: try date("2026-08-28"),
                in: db
            )
            // The period was generated during onboarding, before the limit existed,
            // so its snapshot is taken again here — otherwise `period_limits` is
            // empty and the backup would not be carrying the table that matters most
            // to DEC-008.
            let period = try #require(try Queries.period(containing: try date("2026-09-02"), in: db))
            try PeriodGenerator().resnapshot(period: period, in: db)

            try MerchantRules().remember(merchant: "WOOLWORTHS 1234", categoryID: groceries, in: db)

            try TransactionStore().create(
                TransactionDraft(
                    kind: .expense,
                    amount: Money(minorUnits: 4500, currency: .aud),
                    accountID: account,
                    categoryID: groceries,
                    merchant: "Woolworths",
                    bookedOn: try date("2026-09-02")
                ),
                in: db
            )
            try TransactionStore().create(
                TransactionDraft(
                    kind: .income,
                    amount: Money(minorUnits: 250_000, currency: .aud),
                    accountID: savings,
                    merchant: "Employer",
                    bookedOn: try date("2026-08-28")
                ),
                in: db
            )

            let doomed = try TransactionStore().create(
                TransactionDraft(
                    kind: .expense,
                    amount: Money(minorUnits: 999, currency: .aud),
                    accountID: account,
                    categoryID: groceries,
                    merchant: "Mistake",
                    bookedOn: try date("2026-09-01")
                ),
                in: db
            )
            try TransactionStore().delete(id: doomed, in: db)
        }
        return database
    }

    private func export(_ database: AppDatabase) throws -> Data {
        try database.writer.read { db in
            try BackupExporter(now: clock).json(from: db)
        }
    }

    // MARK: - Round trip

    @Test("a restore into an empty database reproduces the export exactly")
    func roundTripIsIdentical() throws {
        let source = try populated()
        let backup = try export(source)

        let restored = try Fixture.database()
        let report = try restored.writer.write { db in
            try BackupImporter(now: clock).restore(from: backup, into: db)
        }

        #expect(report.settingsApplied, "a fresh install takes its schedule from the backup")
        #expect(report.totalInserted > 0)
        #expect(report.alreadyPresent == 0)

        // The roadmap's "done when", in one comparison: identical bytes means
        // identical ids, timestamps, tombstones and change sequences, not merely
        // the same amounts in the same order.
        #expect(try export(restored) == backup)
    }

    @Test("re-importing the same file a second time inserts nothing")
    func secondImportIsANoOp() throws {
        let source = try populated()
        let backup = try export(source)

        let restored = try Fixture.database()
        try restored.writer.write { db in
            _ = try BackupImporter(now: clock).restore(from: backup, into: db)
        }
        let second = try restored.writer.write { db in
            try BackupImporter(now: clock).restore(from: backup, into: db)
        }

        #expect(second.totalInserted == 0)
        #expect(second.alreadyPresent > 0)
        #expect(try export(restored) == backup, "a no-op import must also change nothing")
    }

    @Test("importing a backup into the database it came from changes nothing")
    func importingIntoItselfIsANoOp() throws {
        let source = try populated()
        let backup = try export(source)

        let report = try source.writer.write { db in
            try BackupImporter(now: clock).restore(from: backup, into: db)
        }

        #expect(report.totalInserted == 0)
        #expect(!report.settingsApplied, "a configured database keeps its own schedule")
        #expect(try export(source) == backup)
    }

    // MARK: - The things a backup has to remember

    @Test("a deleted transaction stays deleted across a restore")
    func tombstonesSurvive() throws {
        let source = try populated()
        let backup = try export(source)

        let restored = try Fixture.database()
        try restored.writer.write { db in
            _ = try BackupImporter(now: clock).restore(from: backup, into: db)
        }

        try restored.writer.read { db in
            // DEC-005: a deleted row keeps occupying its identity slot, which is
            // what stops a later import resurrecting it. A backup that dropped
            // tombstones would undo every deletion the user ever made.
            let deleted = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM transactions WHERE deleted_at IS NOT NULL
            """)
            #expect(deleted == 1)
            let ledger = try Queries.ledger(db)
            #expect(ledger.allSatisfy { $0.merchant != "Mistake" })
        }
    }

    @Test("the local change counter moves past the restored rows")
    func changeCounterAdvances() throws {
        let source = try populated()
        let backup = try export(source)

        let restored = try Fixture.database()
        let highest = try restored.writer.write { db -> Int64 in
            _ = try BackupImporter(now: clock).restore(from: backup, into: db)
            return try Int64.fetchOne(db, sql: "SELECT MAX(change_seq) FROM transactions") ?? 0
        }

        let next = try restored.writer.write { db in
            try AppDatabase.nextChangeSeq(db)
        }
        // DEC-006's promise — "what changed since N" without a table scan — quietly
        // stops being true if a local write reuses a number an imported row has.
        #expect(next > highest)
    }

    @Test("limits, periods and their snapshots all come back")
    func everyTableIsCarried() throws {
        let source = try populated()
        let backup = try export(source)

        let restored = try Fixture.database()
        try restored.writer.write { db in
            _ = try BackupImporter(now: clock).restore(from: backup, into: db)
        }

        try restored.writer.read { db in
            let today = try date("2026-09-02")
            let period = try #require(try Queries.period(containing: today, in: db))
            let lines = try Queries.budgetLines(periodID: period.id, in: db)
            let groceries = lines.first { $0.categoryName == "Groceries" }
            #expect(groceries?.limitMinor == 50000)
            #expect(try MerchantRules().suggestion(forMerchant: "Woolworths", in: db) != nil)
        }
    }

    // MARK: - Refusals

    @Test("a backup from a newer version is refused rather than half-read")
    func futureVersionRefused() throws {
        let source = try populated()
        var document = try source.writer.read { db in
            try BackupExporter(now: clock).document(from: db)
        }
        document.version = BackupDocument.currentVersion + 1

        let target = try Fixture.database()
        #expect(throws: BackupImportError.self) {
            try target.writer.write { db in
                try BackupImporter(now: clock).restore(document, into: db)
            }
        }
    }

    // MARK: - CSV

    @Test("the CSV lists live transactions and leaves deleted ones out")
    func csvOmitsDeletedRows() throws {
        let source = try populated()
        let csv = try source.writer.read { db in
            try BackupExporter(now: clock).csv(from: db)
        }
        let lines = csv.split(separator: "\n")

        #expect(lines.first?.hasPrefix("date,kind") == true)
        // Two live transactions plus the header. A spreadsheet of a person's
        // spending must not include purchases they told the app to forget.
        #expect(lines.count == 3)
        #expect(!csv.contains("Mistake"))
    }

    @Test("a merchant containing a comma does not become two columns")
    func csvQuotesSeparators() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.onboard(db)
            try TransactionStore().create(
                TransactionDraft(
                    kind: .expense,
                    amount: Money(minorUnits: 1000, currency: .aud),
                    accountID: account,
                    categoryID: try Fixture.category("Eating out", in: db),
                    merchant: "Smith, Jones & Co \"The Pub\"",
                    bookedOn: try date("2026-09-02")
                ),
                in: db
            )
        }

        let csv = try database.writer.read { db in
            try BackupExporter(now: clock).csv(from: db)
        }
        // RFC 4180: quotes are doubled inside a quoted field.
        #expect(csv.contains("\"Smith, Jones & Co \"\"The Pub\"\"\""))
        #expect(csv.split(separator: "\n").count == 2)
    }
}
