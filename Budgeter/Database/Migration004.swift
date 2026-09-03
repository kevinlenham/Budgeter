//
//  Migration004.swift
//  Budgeter
//
//  DEC-030's merchant memory.
//
//  The table maps a *normalised* merchant string to a category, and is written
//  every time the user confirms or corrects one. That is the whole mechanism: no
//  model, no bundled data, deterministic, and explainable to the user in one
//  sentence — which is what DEC-030 chose it for over Core ML.
//
//  The normalisation itself is deliberately not in SQL. `MerchantKey` is a pure
//  Swift function with its own tests, because the rules ("WOOLWORTHS 1234 SYDNEY
//  AUS" and "Woolworths" are the same shop) are the part most likely to be wrong,
//  and SQL is the worst place to iterate on them. The column stores the result.
//

import Foundation

nonisolated extension Migrations {
    static let migration004 = Migration(
        version: 4,
        name: "merchant rules",
        sql: """
        -- ---------------------------------------------------------------------
        -- merchant_rules (DEC-030)
        --
        -- One row per remembered merchant. `merchant_key` is the normalised form
        -- and `merchant_sample` is the raw string the rule was last learned from,
        -- kept only so the rules screen can show the user something they
        -- recognise — nothing reads it to make a decision.
        --
        -- `hit_count` and `last_used_at` exist for DEC-023's stats screen, which
        -- needs "how often was the guess right" to mean anything. They are
        -- observations, never inputs to the guess: the rule for a merchant is
        -- whatever the user last said, not whatever they said most often.
        -- ---------------------------------------------------------------------
        CREATE TABLE merchant_rules (
            id              TEXT PRIMARY KEY NOT NULL,

            merchant_key    TEXT NOT NULL CHECK (length(trim(merchant_key)) > 0),
            merchant_sample TEXT,
            category_id     TEXT NOT NULL REFERENCES categories(id),

            hit_count       INTEGER NOT NULL DEFAULT 0 CHECK (hit_count >= 0),
            last_used_at    TEXT,

            created_at      TEXT NOT NULL,
            updated_at      TEXT NOT NULL,
            deleted_at      TEXT,
            change_seq      INTEGER NOT NULL
        );

        -- One live rule per merchant. Partial rather than unconditional, unlike
        -- the transactions dedupe index (DEC-005) — and the difference is the
        -- point. A deleted transaction keeps its identity slot so a re-import
        -- cannot resurrect it; a deleted *rule* is the user saying "stop guessing
        -- that", and they must be able to teach the app a new answer for the same
        -- shop afterwards. Holding the slot would make that impossible.
        CREATE UNIQUE INDEX idx_merchant_rules_key
            ON merchant_rules (merchant_key)
            WHERE deleted_at IS NULL;

        CREATE INDEX idx_merchant_rules_category ON merchant_rules (category_id);
        """
    )
}
