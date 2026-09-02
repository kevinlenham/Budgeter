//
//  IngestFunnelTests.swift
//  BudgeterTests
//
//  Invariant 4 and rule 3. The funnel is what makes re-import a no-op; the unique
//  index only detects. So these tests exercise the no-op, not the constraint.
//

import Foundation
import GRDB
import Testing
@testable import Budgeter

private let fixedNow = Date(timeIntervalSince1970: 1_788_000_000)

private func makeFunnel() -> IngestFunnel {
    IngestFunnel(now: { fixedNow })
}

private func expense(
    account: UUID,
    category: UUID? = nil,
    amountMinor: Int64 = 4500,
    merchant: String? = "Woolworths",
    bookedOn: String = "2026-09-01",
    source: TransactionSource = .csv,
    dedupeKey: String
) -> IngestedTransaction {
    IngestedTransaction(
        kind: .expense,
        status: .confirmed,
        amount: Money(minorUnits: amountMinor, currency: .aud),
        accountID: account,
        categoryID: category,
        merchant: merchant,
        bookedOn: bookedOn,
        occurredAt: fixedNow,
        source: source,
        dedupeKey: dedupeKey
    )
}

@Suite("The ingest funnel")
struct IngestFunnelTests {
    @Test("a first import inserts")
    func firstImportInserts() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            let outcome = try makeFunnel().ingest(expense(account: account, dedupeKey: "row-1"), into: db)

            guard case .inserted = outcome else {
                Issue.record("expected an insert, got \(outcome)")
                return
            }
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions") == 1)
        }
    }

    @Test("re-importing the same file is a genuine no-op — invariant 4")
    func reimportIsIdempotent() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            let funnel = makeFunnel()
            let rows = (1 ... 12).map { expense(account: account, dedupeKey: "row-\($0)") }

            for row in rows {
                try funnel.ingest(row, into: db)
            }
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions") == 12)

            // The same import again, exactly as a user re-running it would.
            for row in rows {
                try funnel.ingest(row, into: db)
            }
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions") == 12,
                    "re-import duplicated rows")
        }
    }

    @Test("a row the user deleted is not resurrected, and says so — DEC-005")
    func deletedRowsAreSkippedNotResurrected() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            let funnel = makeFunnel()
            let row = expense(account: account, dedupeKey: "row-1")

            let inserted = try funnel.ingest(row, into: db)
            guard case let .inserted(id) = inserted else {
                Issue.record("expected an insert")
                return
            }

            try db.execute(
                sql: "UPDATE transactions SET deleted_at = ? WHERE id = ?",
                arguments: ["2026-09-01T12:00:00.000Z", id.uuidString]
            )

            let second = try funnel.ingest(row, into: db)
            #expect(second == .skippedDeleted(id: id))

            let stillDeleted = try String.fetchOne(
                db, sql: "SELECT deleted_at FROM transactions WHERE id = ?",
                arguments: [id.uuidString]
            )
            #expect(stillDeleted != nil, "a deliberately deleted row came back")
        }
    }

    @Test("an import summary can be built from the outcomes")
    func outcomesSupportASkipReport() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            let funnel = makeFunnel()

            for index in 1 ... 3 {
                let outcome = try funnel.ingest(
                    expense(account: account, dedupeKey: "deleted-\(index)"), into: db
                )
                guard case let .inserted(id) = outcome else { continue }
                try db.execute(
                    sql: "UPDATE transactions SET deleted_at = ? WHERE id = ?",
                    arguments: ["2026-09-01T12:00:00.000Z", id.uuidString]
                )
            }

            var outcomes: [IngestOutcome] = []
            for index in 1 ... 3 {
                outcomes.append(try funnel.ingest(
                    expense(account: account, dedupeKey: "deleted-\(index)"), into: db
                ))
            }
            for index in 1 ... 12 {
                outcomes.append(try funnel.ingest(
                    expense(account: account, dedupeKey: "fresh-\(index)"), into: db
                ))
            }

            let imported = outcomes.filter {
                if case .inserted = $0 {
                    true
                } else {
                    false
                }
            }.count
            let skipped = outcomes.filter {
                if case .skippedDeleted = $0 {
                    true
                } else {
                    false
                }
            }.count

            // "12 imported, 3 previously deleted and skipped"
            #expect(imported == 12)
            #expect(skipped == 3)
        }
    }

    @Test("a changed amount updates the existing row rather than inserting a second")
    func changedAmountUpdatesInPlace() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            let funnel = makeFunnel()

            try funnel.ingest(expense(account: account, amountMinor: 100, dedupeKey: "fuel"), into: db)
            // A fuel pre-auth settling from $1.00 to $73.00 (DEC-018).
            let outcome = try funnel.ingest(
                expense(account: account, amountMinor: 7300, dedupeKey: "fuel"), into: db
            )

            guard case .updated = outcome else {
                Issue.record("expected an update, got \(outcome)")
                return
            }
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions") == 1)
            #expect(try Int64.fetchOne(db, sql: "SELECT amount_minor FROM transactions") == 7300)
        }
    }

    @Test("two identical manual entries are two real purchases — DEC-005")
    func manualEntriesNeverCollide() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            let funnel = makeFunnel()

            // Manual entry takes a fresh UUID as its key precisely so that two
            // $4.50 coffees at the same cafe both survive.
            for _ in 0 ..< 2 {
                try funnel.ingest(
                    expense(account: account, amountMinor: 450, source: .manual,
                            dedupeKey: UUID().uuidString),
                    into: db
                )
            }

            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions") == 2)
        }
    }

    @Test("an ingested transfer dedupes on its from-account")
    func transfersDedupeThroughTheFunnel() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let from = try Fixture.insertAccount(db, name: "Everyday")
            let to = try Fixture.insertAccount(db, name: "Savings")
            let funnel = makeFunnel()

            let transfer = IngestedTransaction(
                kind: .transfer,
                status: .confirmed,
                amount: Money(minorUnits: 50000, currency: .aud),
                fromAccountID: from,
                toAccountID: to,
                bookedOn: "2026-09-01",
                occurredAt: fixedNow,
                source: .csv,
                dedupeKey: "transfer-1"
            )

            try funnel.ingest(transfer, into: db)
            try funnel.ingest(transfer, into: db)

            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions") == 1)
        }
    }

    @Test("every write stamps a fresh change_seq — DEC-006")
    func writesStampChangeSeq() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            let funnel = makeFunnel()

            try funnel.ingest(expense(account: account, dedupeKey: "a"), into: db)
            try funnel.ingest(expense(account: account, dedupeKey: "b"), into: db)
            try funnel.ingest(expense(account: account, amountMinor: 999, dedupeKey: "a"), into: db)

            let sequences = try Int64.fetchAll(
                db, sql: "SELECT change_seq FROM transactions ORDER BY change_seq"
            )
            #expect(sequences.count == 2)
            #expect(Set(sequences).count == 2, "two rows shared a change_seq")
        }
    }

    @Test("the funnel writes rows the views agree with")
    func funnelWritesFeedTheViews() throws {
        let database = try Fixture.database()
        try database.writer.write { db in
            let account = try Fixture.insertAccount(db)
            let category = try Fixture.insertCategory(db)
            let funnel = makeFunnel()

            try funnel.ingest(
                expense(account: account, category: category, amountMinor: 4500, dedupeKey: "row-1"),
                into: db
            )

            let spending = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(amount_minor), 0) FROM spending")
            let balance = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(amount_minor), 0) FROM postings")

            #expect(spending == 4500)
            #expect(balance == -4500)
        }
    }
}
