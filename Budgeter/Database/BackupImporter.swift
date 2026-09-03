//
//  BackupImporter.swift
//  Budgeter
//
//  Reading an export back in — the other half of DEC-002's durability, and the half
//  that decides whether the first half was worth anything.
//
//  **This is a restore, not an ingestion, and the distinction is load-bearing.**
//  Rule 3 sends all ingestion through `IngestFunnel`, and Sprint 4's roadmap entry
//  assumed a re-import would exercise it. Implementation says otherwise, and
//  DEC-042 records why: the funnel's own doc comment describes its input as "a
//  transaction on its way in, *before* it has an identity in our database". A row
//  from our own export already has one. Pushing it through the funnel would mint a
//  fresh UUIDv7 and fresh timestamps for a row that already has both — and since
//  `category_limits`, `period_limits` and `transactions` all reference ids, a
//  restore that renumbers everything has to rewrite every reference on the way
//  past. A restore that keeps ids has nothing to rewrite.
//
//  The idempotency the funnel would have provided is kept, by the same means the
//  funnel uses: nothing is inserted whose identity is already present. Re-importing
//  the same file twice inserts nothing the second time — for transactions, checked
//  against both the primary key *and* DEC-005's `(account, source, dedupe_key)`
//  index, so a row that arrived by two different routes still cannot double.
//

import Foundation
import GRDB

nonisolated enum BackupImportError: Error, Equatable {
    /// A file written by a newer version of the app. Refused rather than
    /// half-read: a backup partially understood is worse than one that will not
    /// open, because the user believes their data is restored.
    case unsupportedVersion(Int)
}

/// What a restore did. Shown to the user, and the thing the round-trip test
/// asserts on — "0 inserted, everything already present" is the whole proof that
/// re-importing your own export is a no-op.
nonisolated struct BackupImportReport: Equatable, Sendable {
    var accountsInserted = 0
    var categoriesInserted = 0
    var categoryLimitsInserted = 0
    var periodsInserted = 0
    var periodLimitsInserted = 0
    var merchantRulesInserted = 0
    var transactionsInserted = 0
    /// Rows whose identity was already present, and which were therefore left
    /// exactly as they were. A second import of the same file reports everything
    /// here and nothing above.
    var alreadyPresent = 0
    /// Whether the schedule settings were taken from the file. False when the
    /// database already had its own — see `restore`.
    var settingsApplied = false

    var totalInserted: Int {
        accountsInserted + categoriesInserted + categoryLimitsInserted + periodsInserted
            + periodLimitsInserted + merchantRulesInserted + transactionsInserted
    }
}

nonisolated struct BackupImporter: Sendable {
    var now: @Sendable () -> Date = { Date() }

    func restore(from data: Data, into db: Database) throws -> BackupImportReport {
        try restore(BackupCoding.decoder().decode(BackupDocument.self, from: data), into: db)
    }

    /// Restores a decoded document.
    ///
    /// Settings are applied **only into a database that has none** — a fresh
    /// install restoring a backup. Importing into a configured database leaves its
    /// anchor and cadence alone, because overwriting them would move where future
    /// periods fall while the periods already generated stay put, and DEC-007's
    /// governing principle exists to stop exactly that. Merging two people's
    /// budgets is not a feature; restoring one person's is.
    func restore(_ document: BackupDocument, into db: Database) throws -> BackupImportReport {
        guard document.version == BackupDocument.currentVersion else {
            throw BackupImportError.unsupportedVersion(document.version)
        }

        var report = BackupImportReport()

        if try BudgetSettingsStore().load(db).schedule == nil {
            try BudgetSettingsStore(now: now).save(document.settings.settings(), in: db)
            report.settingsApplied = true
        }

        // Order matters: every table below references one above it, and the foreign
        // keys are on (`AppDatabase.configuration`), so a file with a dangling
        // reference fails loudly here rather than restoring a database that is
        // quietly missing its categories.
        let accounts = try restore(document.accounts, into: "accounts", id: \.id, in: db)
        let categories = try restore(document.categories, into: "categories", id: \.id, in: db)
        let categoryLimits = try restore(
            document.categoryLimits, into: "category_limits", id: \.id,
            clashes: openLimitClashes, in: db
        )
        let periods = try restore(
            document.periods, into: "periods", id: \.id, clashes: periodOverlaps, in: db
        )
        let periodLimits = try restore(
            document.periodLimits, into: "period_limits", id: \.id,
            clashes: periodLimitClashes, in: db
        )
        let merchantRules = try restore(
            document.merchantRules, into: "merchant_rules", id: \.id,
            clashes: merchantKeyTaken, in: db
        )
        let transactions = try restore(
            document.transactions, into: "transactions", id: \.id,
            clashes: dedupeSlotTaken, in: db
        )

        report.accountsInserted = accounts.inserted
        report.categoriesInserted = categories.inserted
        report.categoryLimitsInserted = categoryLimits.inserted
        report.periodsInserted = periods.inserted
        report.periodLimitsInserted = periodLimits.inserted
        report.merchantRulesInserted = merchantRules.inserted
        report.transactionsInserted = transactions.inserted
        report.alreadyPresent = [
            accounts, categories, categoryLimits, periods,
            periodLimits, merchantRules, transactions,
        ]
        .reduce(0) { $0 + $1.present }

        try advanceChangeCounter(past: document, in: db)
        return report
    }

    // MARK: - Insertion

    /// Inserts each row verbatim unless something already occupies its identity.
    ///
    /// Two kinds of identity are checked. The primary key, always — and, for the
    /// tables that have one, the *other* unique constraint the schema imposes,
    /// passed in as `clashes`. Both are needed: the first stops the same file being
    /// imported twice, and the second stops a row arriving under a new id into a
    /// slot the database considers occupied, which the unique index would otherwise
    /// reject by aborting the entire restore.
    ///
    /// `PersistableRecord` is deliberately not adopted by the record types — DEC-003
    /// chose explicit SQL, and Records.swift says they carry no persistence
    /// behaviour — so columns come from the record's own `Codable` encoding, whose
    /// keys already *are* the column names. One list, not two, and a column added by
    /// a later migration flows through by editing the struct alone.
    private func restore<Stored: Encodable>(
        _ rows: [Stored],
        into table: String,
        id: (Stored) -> String,
        clashes: (Stored, Database) throws -> Bool = { _, _ in false },
        in db: Database
    ) throws -> (inserted: Int, present: Int) {
        var inserted = 0
        var present = 0

        for row in rows {
            let taken = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS (SELECT 1 FROM \(table) WHERE id = ?)",
                arguments: [id(row)]
            ) ?? false

            guard !taken, try !clashes(row, db) else {
                present += 1
                continue
            }

            let columns = try BackupRow.columns(of: row)
            let names = columns.map(\.name).joined(separator: ", ")
            let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
            try db.execute(
                sql: "INSERT INTO \(table) (\(names)) VALUES (\(placeholders))",
                arguments: StatementArguments(columns.map(\.value))
            )
            inserted += 1
        }

        return (inserted, present)
    }

    // MARK: - Identity clashes other than the primary key

    /// DEC-005's index: `(COALESCE(account_id, from_account_id), source, dedupe_key)`,
    /// unconditional, so it covers soft-deleted rows too.
    private func dedupeSlotTaken(_ transaction: TransactionRecord, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS (
                SELECT 1 FROM transactions
                 WHERE COALESCE(account_id, from_account_id) IS ?
                   AND source = ? AND dedupe_key = ? AND id <> ?
            )
            """,
            arguments: [
                transaction.accountId ?? transaction.fromAccountId,
                transaction.source, transaction.dedupeKey, transaction.id,
            ]
        ) ?? false
    }

    /// At most one open-ended limit per category (`idx_category_limits_open`).
    private func openLimitClashes(_ limit: CategoryLimitRecord, in db: Database) throws -> Bool {
        guard limit.effectiveTo == nil, limit.deletedAt == nil else { return false }
        return try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS (
                SELECT 1 FROM category_limits
                 WHERE category_id = ? AND effective_to IS NULL AND deleted_at IS NULL AND id <> ?
            )
            """,
            arguments: [limit.categoryId, limit.id]
        ) ?? false
    }

    /// The `trg_periods_no_overlap` trigger aborts the whole transaction, so an
    /// overlapping period is detected before it is offered rather than after.
    private func periodOverlaps(_ period: PeriodRecord, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS (
                SELECT 1 FROM periods
                 WHERE deleted_at IS NULL AND id <> ?
                   AND ? <= ends_on AND ? >= starts_on
            )
            """,
            arguments: [period.id, period.startsOn, period.endsOn]
        ) ?? false
    }

    /// `idx_period_limits` is unique on (period_id, category_id).
    private func periodLimitClashes(_ limit: PeriodLimitRecord, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS (
                SELECT 1 FROM period_limits
                 WHERE period_id = ? AND category_id = ? AND id <> ?
            )
            """,
            arguments: [limit.periodId, limit.categoryId, limit.id]
        ) ?? false
    }

    /// `idx_merchant_rules_key` is unique on live rows only.
    private func merchantKeyTaken(_ rule: MerchantRuleRecord, in db: Database) throws -> Bool {
        guard rule.deletedAt == nil else { return false }
        return try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS (
                SELECT 1 FROM merchant_rules
                 WHERE merchant_key = ? AND deleted_at IS NULL AND id <> ?
            )
            """,
            arguments: [rule.merchantKey, rule.id]
        ) ?? false
    }

    // MARK: - change_seq (DEC-006)

    /// Restored rows keep the sequence numbers they were exported with, so the
    /// local counter has to be moved past them. Skipping this hands the next local
    /// write a number an imported row already used, and DEC-006's whole promise —
    /// "what changed since N" answerable without a table scan — quietly stops being
    /// true for every row in between.
    private func advanceChangeCounter(past document: BackupDocument, in db: Database) throws {
        let highest = [
            document.accounts.map(\.changeSeq).max(),
            document.categories.map(\.changeSeq).max(),
            document.categoryLimits.map(\.changeSeq).max(),
            document.periods.map(\.changeSeq).max(),
            document.periodLimits.map(\.changeSeq).max(),
            document.merchantRules.map(\.changeSeq).max(),
            document.transactions.map(\.changeSeq).max(),
        ]
        .compactMap { $0 }
        .max()

        guard let highest else { return }
        try db.execute(
            sql: "UPDATE change_counter SET next_seq = MAX(next_seq, ?) WHERE id = 1",
            arguments: [highest]
        )
    }
}

/// Turning a `Codable` record back into the columns it came from.
///
/// The records' `CodingKeys` are already the column names — that is how they are
/// read — so encoding one to a keyed container and reading the keys back out gives
/// the insert statement its columns without a second list to maintain.
nonisolated enum BackupRow {
    struct Column {
        var name: String
        var value: (any DatabaseValueConvertible)?
    }

    static func columns(of record: some Encodable) throws -> [Column] {
        let data = try JSONEncoder().encode(record)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let fields = object as? [String: Any] else { return [] }

        return fields.keys.sorted().map { name in
            Column(name: name, value: value(of: fields[name]))
        }
    }

    /// JSON has three scalar types and SQLite has four; only the mapping between
    /// them is interesting. `NSNumber` is the awkward one — `JSONSerialization`
    /// hands back booleans and integers as the same class — so integers are read
    /// as `Int64`, which is what every numeric column in this schema is.
    private static func value(of raw: Any?) -> (any DatabaseValueConvertible)? {
        switch raw {
        case let text as String: text
        case let number as NSNumber: number.int64Value
        default: nil
        }
    }
}
