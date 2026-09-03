//
//  BackupDocument.swift
//  Budgeter
//
//  The shape of a full export.
//
//  DEC-002 chose durability over sync, and is blunt about what that costs: "durability
//  requires the export feature to actually be built, not assumed." Until this exists
//  the no-sync decision is unbacked — there is one copy of the data and a hope.
//
//  So this is a *backup*, not a report: every table, every column, tombstones
//  included. Soft-deleted rows are exported deliberately. DEC-005 makes a deleted
//  row's identity slot the thing that stops a re-import resurrecting it, and a
//  backup that dropped tombstones would restore a database in which every deletion
//  the user made comes back the next time they import a CSV.
//
//  The row types are the same `Codable` records the rest of the app reads, with the
//  same column-named coding keys. That is the point: there is no second description
//  of the schema here to drift out of step with migrations, and a column added in a
//  later migration appears in the backup by editing one struct.
//

import Foundation

nonisolated struct BackupSettings: Codable, Equatable, Sendable {
    var anchorOn: String?
    var cadence: String?
    var payAnchorOn: String?
    var payCadence: String?
    var payReminderTime: String?
    var payReminderEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case anchorOn = "anchor_on"
        case cadence
        case payAnchorOn = "pay_anchor_on"
        case payCadence = "pay_cadence"
        case payReminderTime = "pay_reminder_time"
        case payReminderEnabled = "pay_reminder_enabled"
    }

    init(_ settings: BudgetSettings) {
        anchorOn = settings.schedule?.anchor.iso
        cadence = settings.schedule?.cadence.rawValue
        payAnchorOn = settings.paySchedule?.anchor.iso
        payCadence = settings.paySchedule?.cadence.rawValue
        payReminderTime = settings.payReminderTime?.iso
        payReminderEnabled = settings.payReminderEnabled
    }

    /// Back into the in-memory form. Returns nil for a half-written pair rather
    /// than inventing the missing half, matching the CHECK on `budget_settings`.
    func settings() -> BudgetSettings {
        BudgetSettings(
            schedule: Self.schedule(anchorOn, cadence),
            paySchedule: Self.schedule(payAnchorOn, payCadence),
            payReminderTime: payReminderTime.flatMap(TimeOfDay.init(iso:)),
            payReminderEnabled: payReminderEnabled
        )
    }

    private static func schedule(_ anchor: String?, _ cadence: String?) -> PeriodSchedule? {
        guard let anchor, let cadence,
              let date = CivilDate(iso: anchor), let cadence = Cadence(rawValue: cadence)
        else { return nil }
        return PeriodSchedule(anchor: date, cadence: cadence)
    }
}

nonisolated struct BackupDocument: Codable, Equatable, Sendable {
    /// Bumped only when the format changes in a way an older reader would get
    /// wrong. `BackupImporter` refuses a version it does not know, because a
    /// backup half-understood is worse than one that will not open.
    static let currentVersion = 1

    var version: Int
    /// When the export was taken, UTC. Informational — nothing reads it back.
    var exportedAt: String
    var settings: BackupSettings
    var accounts: [AccountRecord]
    var categories: [CategoryRecord]
    var categoryLimits: [CategoryLimitRecord]
    var periods: [PeriodRecord]
    var periodLimits: [PeriodLimitRecord]
    var merchantRules: [MerchantRuleRecord]
    var transactions: [TransactionRecord]

    enum CodingKeys: String, CodingKey {
        case version, settings, accounts, categories, periods, transactions
        case exportedAt = "exported_at"
        case categoryLimits = "category_limits"
        case periodLimits = "period_limits"
        case merchantRules = "merchant_rules"
    }
}

nonisolated enum BackupCoding {
    /// Deterministic on purpose: sorted keys mean the same database exports the
    /// same bytes twice, which is what turns "export, re-import, export again" into
    /// an equality check a test can make (roadmap, Sprint 4) rather than a
    /// field-by-field comparison someone has to remember to extend.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        JSONDecoder()
    }
}
