//
//  Migration002.swift
//  Budgeter
//
//  One migration per file. A shipped migration is immutable (see Migrations.swift),
//  so this list only ever grows, and keeping each one whole in its own file means a
//  later reader can see exactly what version 2 did without scrolling past version 1.
//

import Foundation

nonisolated extension Migrations {
    /// Periods and limits. Everything here exists to make DEC-007's governing
    /// principle structural: *periods are immutable, append-only records, and
    /// cadence or anchor changes are effective-dated forward and never regenerate
    /// history.*
    static let migration002 = Migration(
        version: 2,
        name: "periods and limits",
        sql: """
        -- ---------------------------------------------------------------------
        -- budget_settings (DEC-007, DEC-036)
        --
        -- One row, like change_counter. Holds the two schedules the app cannot
        -- derive: the budget anchor the user gives at onboarding, and — kept
        -- deliberately separate (DEC-036) — the pay schedule. They are the same
        -- by default and not by definition: switching from fortnightly to
        -- monthly budgeting is not a change of job, and one field serving both
        -- would silently be wrong for one of them the instant they diverge.
        --
        -- Both are NULL until onboarding runs. Period generation refuses to
        -- guess an anchor rather than inventing one from the install date.
        -- ---------------------------------------------------------------------
        CREATE TABLE budget_settings (
            id                   INTEGER PRIMARY KEY CHECK (id = 1),

            anchor_on            TEXT CHECK (anchor_on IS NULL OR
                                 anchor_on GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
            cadence              TEXT CHECK (cadence IS NULL OR
                                 cadence IN ('weekly', 'fortnightly', 'monthly')),

            pay_anchor_on        TEXT CHECK (pay_anchor_on IS NULL OR
                                 pay_anchor_on GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
            pay_cadence          TEXT CHECK (pay_cadence IS NULL OR
                                 pay_cadence IN ('weekly', 'fortnightly', 'monthly')),
            -- Two patterns rather than one: '[0-2][0-9]' would admit 25:00.
            pay_reminder_time    TEXT CHECK (pay_reminder_time IS NULL OR
                                 pay_reminder_time GLOB '[0-1][0-9]:[0-5][0-9]' OR
                                 pay_reminder_time GLOB '2[0-3]:[0-5][0-9]'),
            pay_reminder_enabled INTEGER NOT NULL DEFAULT 0
                                 CHECK (pay_reminder_enabled IN (0, 1)),

            updated_at           TEXT NOT NULL,
            change_seq           INTEGER NOT NULL,

            -- An anchor without a cadence says nothing, and a cadence without an
            -- anchor has nowhere to start. Neither half is meaningful alone.
            CHECK ((anchor_on IS NULL) = (cadence IS NULL)),
            CHECK ((pay_anchor_on IS NULL) = (pay_cadence IS NULL)),

            -- DEC-036's reminder cannot be switched on before there is a schedule
            -- and a time to fire it at.
            CHECK (
                pay_reminder_enabled = 0
                OR (pay_anchor_on IS NOT NULL AND pay_reminder_time IS NOT NULL)
            )
        );

        INSERT INTO budget_settings (id, updated_at, change_seq)
        VALUES (1, '1970-01-01T00:00:00.000Z', 0);

        -- ---------------------------------------------------------------------
        -- periods (DEC-007, DEC-009)
        --
        -- Boundaries are local YYYY-MM-DD dates, never instants: stored as
        -- timestamps, the Australian DST transitions shift a boundary by an hour
        -- and an 11pm 31 March purchase lands in April.
        --
        -- Each row records the cadence and anchor that produced it. A period is a
        -- historical fact, not a view derived from today's settings — so a later
        -- cadence change leaves every existing row exactly as it was, and the
        -- period a past transaction belongs to can never move underneath it.
        -- ---------------------------------------------------------------------
        CREATE TABLE periods (
            id         TEXT PRIMARY KEY NOT NULL,

            starts_on  TEXT NOT NULL
                       CHECK (starts_on GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
            -- Inclusive: the last day *inside* the period. Closed rather than
            -- half-open because it is compared against booked_on and shown to the
            -- user, and "ends 13 March" is what a person understands.
            ends_on    TEXT NOT NULL
                       CHECK (ends_on GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),

            cadence    TEXT NOT NULL CHECK (cadence IN ('weekly', 'fortnightly', 'monthly')),
            anchor_on  TEXT NOT NULL
                       CHECK (anchor_on GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),

            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            deleted_at TEXT,
            change_seq INTEGER NOT NULL,

            CHECK (ends_on >= starts_on)
        );

        CREATE UNIQUE INDEX idx_periods_starts_on ON periods (starts_on);

        -- Every date belongs to exactly one period, so overlap is not a bad state
        -- to be tidied up later — it is a state in which "which period is this
        -- transaction in" has no answer. Enforced here rather than trusted to the
        -- generator, because the generator is not the only thing that will ever
        -- write this table.
        CREATE TRIGGER trg_periods_no_overlap
        BEFORE INSERT ON periods
        FOR EACH ROW
        WHEN EXISTS (
            SELECT 1 FROM periods
             WHERE deleted_at IS NULL
               AND NEW.starts_on <= ends_on
               AND NEW.ends_on   >= starts_on
        )
        BEGIN
            SELECT RAISE(ABORT, 'periods must not overlap');
        END;

        -- ---------------------------------------------------------------------
        -- category_limits (DEC-008)
        --
        -- Effective-dated rows, not a single current value. DEC-008's schema
        -- consequence, stated there: "a past period must display the limit that
        -- applied *then*, not today's. Without this, editing a limit silently
        -- rewrites history."
        --
        -- The range is half-open — [effective_from, effective_to) — so closing one
        -- row and opening the next on the same date leaves no gap and no overlap.
        -- ---------------------------------------------------------------------
        CREATE TABLE category_limits (
            id             TEXT PRIMARY KEY NOT NULL,
            category_id    TEXT NOT NULL REFERENCES categories(id),

            amount_minor   INTEGER NOT NULL CHECK (amount_minor >= 0),
            currency       TEXT NOT NULL
                           CHECK (length(currency) = 3 AND currency = upper(currency)),

            effective_from TEXT NOT NULL
                           CHECK (effective_from GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
            -- NULL means "still in force". Exclusive, per the half-open range.
            effective_to   TEXT
                           CHECK (effective_to IS NULL OR
                                  effective_to GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),

            created_at     TEXT NOT NULL,
            updated_at     TEXT NOT NULL,
            deleted_at     TEXT,
            change_seq     INTEGER NOT NULL,

            CHECK (effective_to IS NULL OR effective_to > effective_from)
        );

        -- A category has at most one limit still in force. Two open-ended rows is
        -- the one overlap a range table cannot recover from — every later query
        -- would have to pick a winner, and any rule for picking is arbitrary.
        CREATE UNIQUE INDEX idx_category_limits_open
            ON category_limits (category_id)
            WHERE effective_to IS NULL AND deleted_at IS NULL;

        CREATE INDEX idx_category_limits_category ON category_limits (category_id);

        -- ---------------------------------------------------------------------
        -- period_limits (DEC-008)
        --
        -- The snapshot each period takes of the limits in force on its start date.
        -- Written once, when the period is generated, and never recomputed: that
        -- is what makes "what was my grocery budget in March" answerable in March's
        -- own terms rather than today's.
        -- ---------------------------------------------------------------------
        CREATE TABLE period_limits (
            id           TEXT PRIMARY KEY NOT NULL,
            period_id    TEXT NOT NULL REFERENCES periods(id),
            category_id  TEXT NOT NULL REFERENCES categories(id),

            amount_minor INTEGER NOT NULL CHECK (amount_minor >= 0),
            currency     TEXT NOT NULL
                         CHECK (length(currency) = 3 AND currency = upper(currency)),

            created_at   TEXT NOT NULL,
            updated_at   TEXT NOT NULL,
            deleted_at   TEXT,
            change_seq   INTEGER NOT NULL
        );

        CREATE UNIQUE INDEX idx_period_limits ON period_limits (period_id, category_id);

        -- ---------------------------------------------------------------------
        -- period_category_status
        --
        -- "$340 of $500" for one category in one period, in one place.
        --
        -- Reads `spending` and never `transactions`, so every exclusion the
        -- invariants demand — transfers, income, drafts, soft-deleted rows — is
        -- inherited rather than restated here, where it could drift.
        --
        -- Period membership is a plain string comparison against booked_on, which
        -- is exactly right: YYYY-MM-DD sorts chronologically, and both sides are
        -- local dates, so no time zone is consulted to decide which period a
        -- transaction is in.
        -- ---------------------------------------------------------------------
        CREATE VIEW period_category_status AS
        SELECT
            period_id,
            starts_on,
            ends_on,
            category_id,
            currency,
            limit_minor,
            spent_minor,
            limit_minor - spent_minor AS remaining_minor
        FROM (
            SELECT
                p.id          AS period_id,
                p.starts_on   AS starts_on,
                p.ends_on     AS ends_on,
                pl.category_id AS category_id,
                pl.currency   AS currency,
                pl.amount_minor AS limit_minor,
                (
                    SELECT COALESCE(SUM(s.amount_minor), 0)
                      FROM spending s
                     WHERE s.category_id = pl.category_id
                       AND s.currency    = pl.currency
                       AND s.booked_on  >= p.starts_on
                       AND s.booked_on  <= p.ends_on
                )             AS spent_minor
            FROM periods p
            JOIN period_limits pl
              ON pl.period_id = p.id
             AND pl.deleted_at IS NULL
            WHERE p.deleted_at IS NULL
        );
        """
    )
}
