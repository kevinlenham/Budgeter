//
//  Migration005.swift
//  Budgeter
//
//  DEC-043's two structural additions: a pending cadence switch, and a whole-period
//  budget that sits alongside the per-category ones rather than replacing them.
//

import Foundation

nonisolated extension Migrations {
    static let migration005 = Migration(
        version: 5,
        name: "pending cadence switch and overall limits",
        sql: """
        -- ---------------------------------------------------------------------
        -- Pending cadence switch (DEC-043)
        --
        -- A switch is confirmed immediately but takes effect on a future date —
        -- the next real Monday or 1st-of-month, per `CalendarCadence`. Storing it
        -- here rather than overwriting `cadence`/`anchor_on` outright means the
        -- schedule that governs *today* stays exactly what it already was until
        -- that date arrives; `PeriodGenerator` promotes pending to active the
        -- first time it generates on or after it.
        --
        -- Both columns null, or both set — the same pairing `anchor_on`/`cadence`
        -- already enforces, for the same reason: one half means nothing alone.
        -- ---------------------------------------------------------------------
        ALTER TABLE budget_settings ADD COLUMN pending_cadence TEXT
            CHECK (pending_cadence IS NULL OR pending_cadence IN ('weekly', 'fortnightly', 'monthly'));
        ALTER TABLE budget_settings ADD COLUMN pending_anchor_on TEXT
            CHECK (pending_anchor_on IS NULL OR
                   pending_anchor_on GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]');

        -- ---------------------------------------------------------------------
        -- overall_limits (DEC-043)
        --
        -- The whole-period budget, effective-dated exactly like `category_limits`
        -- and for the same reason (DEC-008): a past period must keep showing the
        -- limit that applied then. There is only ever one of these in force at a
        -- time — nothing to key it by, unlike a category — so the partial unique
        -- index is on the constant `1` rather than on a column: every open row
        -- shares that value, so SQLite refuses a second one exactly as
        -- `idx_category_limits_open` refuses two open rows for one category.
        -- ---------------------------------------------------------------------
        CREATE TABLE overall_limits (
            id             TEXT PRIMARY KEY NOT NULL,

            amount_minor   INTEGER NOT NULL CHECK (amount_minor >= 0),
            currency       TEXT NOT NULL
                           CHECK (length(currency) = 3 AND currency = upper(currency)),

            effective_from TEXT NOT NULL
                           CHECK (effective_from GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
            effective_to   TEXT
                           CHECK (effective_to IS NULL OR
                                  effective_to GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),

            created_at     TEXT NOT NULL,
            updated_at     TEXT NOT NULL,
            deleted_at     TEXT,
            change_seq     INTEGER NOT NULL,

            CHECK (effective_to IS NULL OR effective_to > effective_from)
        );

        CREATE UNIQUE INDEX idx_overall_limits_open
            ON overall_limits ((1))
            WHERE effective_to IS NULL AND deleted_at IS NULL;

        -- ---------------------------------------------------------------------
        -- The overall snapshot lives directly on `periods`, not in a second
        -- snapshot table alongside `period_limits`. `period_limits` needs its own
        -- table because a period can hold many category rows; a period holds at
        -- most one overall figure, so a nullable pair of columns says the same
        -- thing with no join required to read it.
        -- ---------------------------------------------------------------------
        ALTER TABLE periods ADD COLUMN overall_limit_minor INTEGER;
        ALTER TABLE periods ADD COLUMN overall_limit_currency TEXT
            CHECK (overall_limit_currency IS NULL OR
                   (length(overall_limit_currency) = 3 AND overall_limit_currency = upper(overall_limit_currency)));

        -- ---------------------------------------------------------------------
        -- period_overall_status
        --
        -- The whole-period twin of `period_category_status`: "$1,200 of $2,000"
        -- for the entire period, reading `spending` and never `transactions` for
        -- the same reason that view does — every invariant exclusion is inherited
        -- rather than restated. A period with no overall limit set is simply
        -- absent from this view, matching how an unbudgeted category is absent
        -- from `period_category_status`.
        -- ---------------------------------------------------------------------
        CREATE VIEW period_overall_status AS
        SELECT
            id                     AS period_id,
            starts_on,
            ends_on,
            overall_limit_currency AS currency,
            overall_limit_minor    AS limit_minor,
            (
                SELECT COALESCE(SUM(s.amount_minor), 0)
                  FROM spending s
                 WHERE s.currency  = periods.overall_limit_currency
                   AND s.booked_on >= periods.starts_on
                   AND s.booked_on <= periods.ends_on
            ) AS spent_minor,
            overall_limit_minor - (
                SELECT COALESCE(SUM(s.amount_minor), 0)
                  FROM spending s
                 WHERE s.currency  = periods.overall_limit_currency
                   AND s.booked_on >= periods.starts_on
                   AND s.booked_on <= periods.ends_on
            ) AS remaining_minor
        FROM periods
        WHERE deleted_at IS NULL AND overall_limit_minor IS NOT NULL;
        """
    )
}
