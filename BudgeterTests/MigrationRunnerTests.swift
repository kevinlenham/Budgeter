//
//  MigrationRunnerTests.swift
//  BudgeterTests
//
//  The roadmap asks for the runner to be tested against both an empty and a
//  populated database, because the failure mode that matters is a migration that
//  works on a fresh install and destroys an upgrade.
//

import Foundation
import GRDB
import Testing
@testable import Budgeter

@Suite("Migration runner")
struct MigrationRunnerTests {
    @Test("an empty database ends up at the latest version with the whole schema")
    func migratesEmptyDatabase() throws {
        let queue = try DatabaseQueue(configuration: AppDatabase.configuration())
        let runner = MigrationRunner()

        try queue.write { db in
            #expect(try runner.currentVersion(db) == 0)
            try runner.migrate(db)
            #expect(try runner.currentVersion(db) == runner.latestVersion)
        }

        try queue.read { db in
            let tables = [
                "accounts", "categories", "transactions", "change_counter",
                "budget_settings", "periods", "category_limits", "period_limits",
            ]
            for table in tables {
                let exists = try db.tableExists(table)
                #expect(exists, "missing table \(table)")
            }
            for view in ["spending", "postings", "period_category_status"] {
                let exists = try db.viewExists(view)
                #expect(exists, "missing view \(view)")
            }
        }
    }

    @Test("running twice changes nothing — the runner is idempotent")
    func migrationIsIdempotent() throws {
        let database = try AppDatabase.inMemory()
        let runner = MigrationRunner()

        try database.writer.write { db in
            let versionAfterFirst = try runner.currentVersion(db)
            try runner.migrate(db)
            try runner.migrate(db)
            #expect(try runner.currentVersion(db) == versionAfterFirst)
        }
    }

    @Test("migrating a populated database preserves its rows")
    func migratesPopulatedDatabase() throws {
        let database = try AppDatabase.inMemory()

        let accountID = try database.writer.write { db in
            let account = try Fixture.insertAccount(db, name: "Everyday")
            let category = try Fixture.insertCategory(db)
            try Fixture.insertTransaction(
                db, kind: "expense", amountMinor: 4321,
                accountID: account, categoryID: category
            )
            return account
        }

        try database.writer.write { db in
            try MigrationRunner().migrate(db)

            let accounts = try AccountRecord.fetchAll(db, sql: "SELECT * FROM accounts")
            let total = try Int64.fetchOne(db, sql: "SELECT SUM(amount_minor) FROM transactions")

            #expect(accounts.count == 1)
            #expect(accounts.first?.id == accountID.uuidString)
            #expect(total == 4321)
        }
    }

    @Test("a database from a newer build is refused rather than guessed at")
    func refusesDowngrade() throws {
        let database = try AppDatabase.inMemory()
        let runner = MigrationRunner()

        try database.writer.write { db in
            try db.execute(sql: "PRAGMA user_version = 999")

            let expected = MigrationError.databaseAheadOfCode(
                databaseVersion: 999,
                latestKnown: runner.latestVersion
            )
            #expect(throws: expected) {
                try runner.migrate(db)
            }
        }
    }

    @Test("migrations declared out of order are rejected")
    func rejectsNonIncreasingVersions() throws {
        let queue = try DatabaseQueue(configuration: AppDatabase.configuration())
        let runner = MigrationRunner(migrations: [
            Migration(version: 1, name: "first", sql: "CREATE TABLE a (id TEXT);"),
            Migration(version: 1, name: "duplicate", sql: "CREATE TABLE b (id TEXT);"),
        ])

        try queue.write { db in
            #expect(throws: MigrationError.versionsNotIncreasing) {
                try runner.migrate(db)
            }
        }
    }

    @Test("a failing migration leaves no half-built schema behind")
    func failedMigrationRollsBack() throws {
        let queue = try DatabaseQueue(configuration: AppDatabase.configuration())
        let runner = MigrationRunner(migrations: [
            Migration(
                version: 1,
                name: "broken",
                sql: """
                CREATE TABLE good (id TEXT);
                CREATE TABLE bad (this is not valid sql;
                """
            ),
        ])

        try? queue.write { db in
            try runner.migrate(db)
        }

        try queue.read { db in
            let leftBehind = try db.tableExists("good")
            let version = try Int32.fetchOne(db, sql: "PRAGMA user_version")
            #expect(leftBehind == false, "a failed migration left a table behind")
            #expect(version == 0)
        }
    }
}
