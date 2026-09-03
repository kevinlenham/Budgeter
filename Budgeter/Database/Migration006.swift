//
//  Migration006.swift
//  Budgeter
//
//  A one-line index change, and a bug that made the app unusable.
//
//  `idx_periods_starts_on` was written in Migration002, when a period was only
//  ever inserted and never retired: an unconditional unique index on `starts_on`
//  was then simply "one period per start date". DEC-043 changed that. Switching
//  cadence on the *first day* of the period in progress has no "yesterday" inside
//  that period to truncate to, so `CadenceSwitch.apply` retires the row instead —
//  invariant 3's tombstone. `PeriodGenerator` then inserts the new period, which
//  by construction starts on that same date, and the index refused it: the
//  tombstone was still holding the slot.
//
//  The failure landed in `AppModel.start()`, which reports it as `.failed` — so
//  the whole app was replaced by "Budgeter could not start", and stayed that way
//  on every subsequent launch, because the tombstone and the failing insert were
//  both still there. A cadence switch on a Monday (weekly, fortnightly) or on the
//  1st (monthly) bricked the app.
//
//  The predicate here is the one `trg_periods_no_overlap` has always used, and the
//  one `idx_category_limits_open`, `idx_overall_limits_open` and
//  `idx_merchant_rules_key` all use: a tombstoned row is not a period, so it does
//  not own a start date. The unconditional form was the outlier.
//
//  This heals an already-bricked install on the next launch rather than needing
//  the user to reinstall: dropping the index is all it takes for the insert that
//  was failing to succeed.
//

import Foundation

nonisolated extension Migrations {
    static let migration006 = Migration(
        version: 6,
        name: "periods start-date uniqueness ignores tombstones",
        sql: """
        DROP INDEX idx_periods_starts_on;

        CREATE UNIQUE INDEX idx_periods_starts_on
            ON periods (starts_on)
            WHERE deleted_at IS NULL;
        """
    )
}
