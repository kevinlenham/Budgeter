//
//  AppDatabase.swift
//  Budgeter
//
//  Owns the one SQLite connection and the configuration that has to be right on
//  every connection rather than remembered at each callsite.
//

import Foundation
import GRDB

nonisolated struct AppDatabase: Sendable {
    let writer: DatabaseQueue

    // MARK: - Construction

    /// The on-device database, in Application Support so it is covered by encrypted
    /// device backup (DEC-002) and by the OS file protection DEC-026 relies on.
    static func onDisk(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let queue = try DatabaseQueue(path: url.path, configuration: configuration())
        return try AppDatabase(writer: queue)
    }

    /// An empty in-memory database. Sprints 1, 2 and 8 are pure logic and must never
    /// need a device build, so the whole schema is exercised here instead.
    static func inMemory() throws -> AppDatabase {
        let queue = try DatabaseQueue(configuration: configuration())
        return try AppDatabase(writer: queue)
    }

    private init(writer: DatabaseQueue) throws {
        self.writer = writer
        try writer.write { db in
            try MigrationRunner().migrate(db)
        }
    }

    // MARK: - Configuration

    static func configuration() -> Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            // Off by default in SQLite and set per connection, which silently
            // disables half the schema when forgotten. GRDB defaults it on; this
            // states it anyway, and `SchemaConstraintTests` proves it is on.
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        return configuration
    }

    // MARK: - change_seq (DEC-006)

    /// Claims the next local change sequence number.
    ///
    /// Must be called inside the same transaction as the write it stamps, so a
    /// rolled-back write does not burn a sequence number.
    static func nextChangeSeq(_ db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: """
        UPDATE change_counter
           SET next_seq = next_seq + 1
         WHERE id = 1
        RETURNING next_seq
        """) ?? 0
    }
}
