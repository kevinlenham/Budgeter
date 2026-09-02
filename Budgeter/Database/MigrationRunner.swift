//
//  MigrationRunner.swift
//  Budgeter
//
//  Hand-written rather than GRDB's DatabaseMigrator, so the one mechanism that can
//  destroy a user's data has no magic in it: the schema version is SQLite's own
//  `user_version`, and applying a migration and recording it happen in one transaction.
//

import Foundation
import GRDB

nonisolated enum MigrationError: Error, Equatable {
    /// The database is newer than this build — a downgrade, which we refuse rather
    /// than guess at.
    case databaseAheadOfCode(databaseVersion: Int32, latestKnown: Int32)
    case versionsNotIncreasing
}

nonisolated struct MigrationRunner: Sendable {
    let migrations: [Migration]

    init(migrations: [Migration] = Migrations.all) {
        self.migrations = migrations
    }

    var latestVersion: Int32 {
        migrations.map(\.version).max() ?? 0
    }

    /// Applies every migration newer than the database's current `user_version`.
    ///
    /// Idempotent: running it against an already-current database does nothing.
    /// Runs inside the caller's transaction, so a failing migration rolls back
    /// whole rather than leaving a half-built schema behind.
    func migrate(_ db: Database) throws {
        let ordered = migrations.sorted { $0.version < $1.version }
        guard zip(ordered, ordered.dropFirst()).allSatisfy({ $0.version < $1.version }) else {
            throw MigrationError.versionsNotIncreasing
        }

        let current = try currentVersion(db)
        guard current <= latestVersion else {
            throw MigrationError.databaseAheadOfCode(
                databaseVersion: current,
                latestKnown: latestVersion
            )
        }

        for migration in ordered where migration.version > current {
            try db.execute(sql: migration.sql)
            // PRAGMA does not accept a bound parameter, and `version` is an Int32
            // from our own source, never user input.
            try db.execute(sql: "PRAGMA user_version = \(migration.version)")
        }
    }

    func currentVersion(_ db: Database) throws -> Int32 {
        try Int32.fetchOne(db, sql: "PRAGMA user_version") ?? 0
    }
}
