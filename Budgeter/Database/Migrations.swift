//
//  Migrations.swift
//  Budgeter
//
//  Migrations are hand-written SQL (DEC-003). Each one is immutable once it has run
//  on a real device — edit a shipped migration and the schema silently diverges
//  between a fresh install and an upgraded one. Add a new migration instead.
//

import Foundation

nonisolated struct Migration: Sendable {
    /// Written into `PRAGMA user_version` once this migration has run. Strictly increasing.
    let version: Int32
    let name: String
    let sql: String
}

nonisolated enum Migrations {
    static let all: [Migration] = [migration001]

    /// The schema core. Every invariant that can be expressed structurally is
    /// expressed here rather than in Swift, so no write path can bypass it.
    static let migration001 = Migration(
        version: 1,
        name: "schema core",
        sql: """
        -- ---------------------------------------------------------------------
        -- change_seq allocator (DEC-006)
        --
        -- A single monotonic local counter. A future sync client asks "what
        -- changed since N" and gets an answer without a full table scan.
        -- ---------------------------------------------------------------------
        CREATE TABLE change_counter (
            id       INTEGER PRIMARY KEY CHECK (id = 1),
            next_seq INTEGER NOT NULL
        );

        INSERT INTO change_counter (id, next_seq) VALUES (1, 0);

        -- ---------------------------------------------------------------------
        -- accounts
        --
        -- Every table carries the DEC-006 four: id (UUIDv7), created_at,
        -- updated_at, deleted_at (the soft-delete tombstone, invariant 3), and
        -- change_seq. Timestamps are UTC ISO 8601 strings.
        -- ---------------------------------------------------------------------
        CREATE TABLE accounts (
            id         TEXT PRIMARY KEY NOT NULL,
            name       TEXT NOT NULL CHECK (length(trim(name)) > 0),
            currency   TEXT NOT NULL CHECK (length(currency) = 3 AND currency = upper(currency)),

            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            deleted_at TEXT,
            change_seq INTEGER NOT NULL
        );

        -- ---------------------------------------------------------------------
        -- categories
        -- ---------------------------------------------------------------------
        CREATE TABLE categories (
            id         TEXT PRIMARY KEY NOT NULL,
            name       TEXT NOT NULL CHECK (length(trim(name)) > 0),

            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            deleted_at TEXT,
            change_seq INTEGER NOT NULL
        );

        -- ---------------------------------------------------------------------
        -- transactions
        --
        -- One row per real-world event, whatever its shape. A transfer is a
        -- single row rather than a linked pair (DEC-028), so a half-recorded
        -- transfer cannot exist. Sign lives in the views, never here (DEC-035,
        -- DEC-037): amount_minor is unsigned, and what a row means is decided
        -- by its kind.
        --
        -- Two time fields, never conflated (DEC-009):
        --   booked_on   local YYYY-MM-DD, decides period membership
        --   occurred_at UTC instant, for intra-day ordering and dedupe windows
        -- ---------------------------------------------------------------------
        CREATE TABLE transactions (
            id              TEXT NOT NULL PRIMARY KEY,

            kind            TEXT NOT NULL CHECK (kind IN ('expense', 'refund', 'transfer', 'income')),
            status          TEXT NOT NULL CHECK (status IN ('draft', 'confirmed')),

            amount_minor    INTEGER NOT NULL CHECK (amount_minor >= 0),
            currency        TEXT NOT NULL CHECK (length(currency) = 3 AND currency = upper(currency)),

            account_id      TEXT REFERENCES accounts(id),
            from_account_id TEXT REFERENCES accounts(id),
            to_account_id   TEXT REFERENCES accounts(id),
            category_id     TEXT REFERENCES categories(id),

            merchant        TEXT,
            booked_on       TEXT NOT NULL
                            CHECK (booked_on GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
            occurred_at     TEXT NOT NULL,

            source          TEXT NOT NULL CHECK (source IN ('manual', 'wallet', 'csv', 'bank')),
            dedupe_key      TEXT NOT NULL,

            created_at      TEXT NOT NULL,
            updated_at      TEXT NOT NULL,
            deleted_at      TEXT,
            change_seq      INTEGER NOT NULL,

            -- Account shape per kind. A transfer names both ends and no single
            -- account; everything else names exactly one account.
            CHECK (
                (
                    kind IN ('expense', 'refund', 'income')
                    AND account_id IS NOT NULL
                    AND from_account_id IS NULL
                    AND to_account_id IS NULL
                )
                OR (
                    kind = 'transfer'
                    AND account_id IS NULL
                    AND from_account_id IS NOT NULL
                    AND to_account_id IS NOT NULL
                    AND from_account_id <> to_account_id
                )
            ),

            -- Rule 9. Income and transfers never carry a category, and the
            -- constraint says so rather than trusting every write path to.
            -- Refunds do carry one: reducing the right category is their point.
            CHECK (
                (kind IN ('transfer', 'income') AND category_id IS NULL)
                OR kind IN ('expense', 'refund')
            )
        );

        -- ---------------------------------------------------------------------
        -- Idempotency (DEC-005)
        --
        -- Unconditional, so it covers soft-deleted rows too: a deleted row keeps
        -- occupying its identity slot, and re-importing a file whose rows the
        -- user deleted is a genuine no-op rather than a resurrection.
        --
        -- COALESCE is load-bearing. Transfers carry from_account_id and no
        -- account_id, and SQLite treats NULLs as distinct — without it, every
        -- ingested transfer would be unique and none would ever dedupe.
        -- ---------------------------------------------------------------------
        CREATE UNIQUE INDEX idx_transactions_dedupe
            ON transactions (COALESCE(account_id, from_account_id), source, dedupe_key);

        CREATE INDEX idx_transactions_booked_on ON transactions (booked_on);
        CREATE INDEX idx_transactions_category  ON transactions (category_id);
        CREATE INDEX idx_transactions_account   ON transactions (account_id);

        -- ---------------------------------------------------------------------
        -- spending (DEC-010, rule 1)
        --
        -- The only thing any spending aggregate is ever permitted to read.
        -- Encapsulates, in one definition rather than at every callsite:
        --   confirmed only          (rule 7: drafts are unverified)
        --   not soft-deleted        (invariant 3)
        --   transfers excluded      (invariant 2)
        --   income excluded         (rule 9)
        --   refunds subtract        (DEC-037)
        -- ---------------------------------------------------------------------
        CREATE VIEW spending AS
        SELECT
            t.id            AS transaction_id,
            t.account_id    AS account_id,
            t.category_id   AS category_id,
            t.merchant      AS merchant,
            t.booked_on     AS booked_on,
            t.occurred_at   AS occurred_at,
            t.currency      AS currency,
            CASE t.kind
                WHEN 'expense' THEN  t.amount_minor
                ELSE                -t.amount_minor
            END             AS amount_minor
        FROM transactions t
        WHERE t.kind IN ('expense', 'refund')
          AND t.status = 'confirmed'
          AND t.deleted_at IS NULL;

        -- ---------------------------------------------------------------------
        -- postings (DEC-028, rule 2)
        --
        -- The only thing any balance is ever permitted to read. Expands each
        -- transaction into signed rows against real accounts, so a balance is a
        -- plain SUM: a transfer becomes two rows that cancel, which is what
        -- keeps invariant 2 true no matter how the balance is queried.
        -- ---------------------------------------------------------------------
        CREATE VIEW postings AS
        SELECT id AS transaction_id, account_id AS account_id,
               -amount_minor AS amount_minor, currency, booked_on, occurred_at
        FROM transactions
        WHERE kind = 'expense' AND status = 'confirmed' AND deleted_at IS NULL

        UNION ALL
        SELECT id, account_id, amount_minor, currency, booked_on, occurred_at
        FROM transactions
        WHERE kind IN ('refund', 'income') AND status = 'confirmed' AND deleted_at IS NULL

        UNION ALL
        SELECT id, from_account_id, -amount_minor, currency, booked_on, occurred_at
        FROM transactions
        WHERE kind = 'transfer' AND status = 'confirmed' AND deleted_at IS NULL

        UNION ALL
        SELECT id, to_account_id, amount_minor, currency, booked_on, occurred_at
        FROM transactions
        WHERE kind = 'transfer' AND status = 'confirmed' AND deleted_at IS NULL;
        """
    )
}
