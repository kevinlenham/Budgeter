//
//  Migration003.swift
//  Budgeter
//
//  The ledger's own view.
//
//  The Sprint 3 plan said the ledger would read `spending`, and that turns out to be
//  half right. `spending` is deliberately narrow — it answers "what counts against a
//  budget", so it excludes income and transfers by design (rule 9, invariant 2). A
//  ledger built on it would show the user a list their own payday is missing from,
//  which makes income entry unverifiable from the first usable build.
//
//  So the ledger gets a view of its own: every transaction the user has, one row
//  each, signed for display. `spending` remains the only thing any *aggregate*
//  reads — rule 1 is about totals, and no total is computed from this.
//

import Foundation

nonisolated extension Migrations {
    static let migration003 = Migration(
        version: 3,
        name: "ledger view",
        sql: """
        -- ---------------------------------------------------------------------
        -- ledger
        --
        -- One row per transaction, unlike `postings`, which splits a transfer into
        -- two — correct for balances, wrong for a list of things that happened.
        --
        -- The sign here is a display convention, not an accounting one: money out
        -- is negative, money in is positive, from the user's own point of view. A
        -- transfer is money leaving the account it left, which is the row the user
        -- recognises.
        --
        -- Drafts are included and carry their status, because rule 7 says a draft
        -- must not count toward the authoritative number — not that it must be
        -- invisible. The review UX in a later sprint depends on seeing them.
        -- ---------------------------------------------------------------------
        CREATE VIEW ledger AS
        SELECT
            t.id          AS transaction_id,
            t.kind        AS kind,
            t.status      AS status,
            t.merchant    AS merchant,
            t.booked_on   AS booked_on,
            t.occurred_at AS occurred_at,
            t.currency    AS currency,
            CASE t.kind
                WHEN 'expense'  THEN -t.amount_minor
                WHEN 'transfer' THEN -t.amount_minor
                ELSE                  t.amount_minor
            END           AS amount_minor,
            t.category_id AS category_id,
            c.name        AS category_name,
            COALESCE(t.account_id, t.from_account_id) AS account_id,
            a.name        AS account_name
        FROM transactions t
        LEFT JOIN categories c
               ON c.id = t.category_id
              AND c.deleted_at IS NULL
        LEFT JOIN accounts a
               ON a.id = COALESCE(t.account_id, t.from_account_id)
              AND a.deleted_at IS NULL
        WHERE t.deleted_at IS NULL;
        """
    )
}
