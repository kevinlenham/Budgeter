//
//  PayReminderServiceTests.swift
//  BudgeterTests
//
//  The decisions between the settings row and iOS, driven against a fake.
//
//  DEC-036 draws the line explicitly: the pure date arithmetic is a unit test, "the
//  thin `UNUserNotificationCenter` binding" is not testable off-device. Everything
//  in `PayReminderService` sits on this side of that line — including the two cases
//  most likely to be got wrong and least likely to be noticed, which are permission
//  being refused and permission being revoked later.
//

import Foundation
import GRDB
import Testing
@testable import Budgeter

/// Stands in for `UNUserNotificationCenter`. An actor rather than a locked class
/// because every method on the protocol is already async, so there is nothing to
/// give up.
actor FakePayReminderScheduler: PayReminderScheduling {
    var isGranted: Bool
    private(set) var authorisationRequests = 0
    private(set) var queue: [Date] = []
    private(set) var clearCount = 0

    init(isGranted: Bool = true) {
        self.isGranted = isGranted
    }

    func requestAuthorisation() async throws -> Bool {
        authorisationRequests += 1
        return isGranted
    }

    func isAuthorised() async -> Bool {
        isGranted
    }

    func replaceQueue(with dates: [Date]) async throws {
        queue = dates
    }

    func clearQueue() async {
        clearCount += 1
        queue = []
    }

    func revokePermission() {
        isGranted = false
    }
}

@Suite("Scheduling payday reminders")
struct PayReminderServiceTests {
    /// Melbourne, fixed, so "9am on the 11th" is one instant and not whatever the
    /// CI runner's time zone makes of it.
    private var melbourne: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Melbourne") ?? .gmt
        return calendar
    }

    /// 2026-09-01, 08:00 local.
    private func clock() -> Date {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 9
        parts.day = 1
        parts.hour = 8
        return melbourne.date(from: parts) ?? Date()
    }

    private func reminders(_ scheduler: FakePayReminderScheduler) -> PayReminderService {
        let calendar = melbourne
        let now = clock()
        return PayReminderService(
            scheduler: scheduler,
            now: { now },
            calendar: { calendar }
        )
    }

    private func configured() throws -> AppDatabase {
        let database = try Fixture.database()
        try database.writer.write { db in
            try Fixture.onboard(db)
        }
        return database
    }

    @Test("enabling asks for permission and fills the queue")
    func enablingSchedules() async throws {
        let database = try configured()
        let scheduler = FakePayReminderScheduler()

        let granted = try await reminders(scheduler).enable(in: database)
        #expect(granted)
        #expect(await scheduler.authorisationRequests == 1)

        let queue = await scheduler.queue
        #expect(!queue.isEmpty)
        #expect(queue.count <= PayReminderQueue.maximumPending)

        // Fortnightly from 2026-09-11, at the default 9am, in the user's own time
        // zone. Anything else and the reminder arrives at breakfast in London.
        let first = try #require(queue.first)
        let parts = melbourne.dateComponents([.year, .month, .day, .hour, .minute], from: first)
        #expect(parts.year == 2026 && parts.month == 9 && parts.day == 11)
        #expect(parts.hour == 9 && parts.minute == 0)
    }

    @Test("enabling fills in a reminder time, because the schema will not accept one without")
    func enablingFillsTheDefaultTime() async throws {
        let database = try configured()
        try await reminders(FakePayReminderScheduler()).enable(in: database)

        let settings = try await database.writer.read { db in
            try BudgetSettingsStore().load(db)
        }
        #expect(settings.payReminderEnabled)
        #expect(settings.payReminderTime == .defaultReminder)
    }

    @Test("a refused permission leaves the setting on and schedules nothing")
    func refusedPermissionDegrades() async throws {
        let database = try configured()
        let scheduler = FakePayReminderScheduler(isGranted: false)

        let granted = try await reminders(scheduler).enable(in: database)
        #expect(!granted)
        #expect(await scheduler.queue.isEmpty)

        // DEC-036: denied permission "must degrade rather than break". The setting
        // stays on, and the in-app card carries the feature — rolling it back would
        // make the switch appear to have failed and leave nothing in its place.
        let settings = try await database.writer.read { db in
            try BudgetSettingsStore().load(db)
        }
        #expect(settings.payReminderEnabled)
    }

    @Test("permission revoked in iOS Settings empties the queue on the next launch")
    func revokedPermissionClearsQueue() async throws {
        let database = try configured()
        let scheduler = FakePayReminderScheduler()
        let service = reminders(scheduler)

        try await service.enable(in: database)
        #expect(!(await scheduler.queue.isEmpty))

        // Revocation is silent in iOS. A launch-time refresh is the only place the
        // app would ever notice, which is why `refresh` re-checks rather than
        // trusting the flag it wrote when permission was granted.
        await scheduler.revokePermission()
        try await service.refresh(in: database)
        #expect(await scheduler.queue.isEmpty)
    }

    @Test("turning it off clears the queue")
    func disablingClears() async throws {
        let database = try configured()
        let scheduler = FakePayReminderScheduler()
        let service = reminders(scheduler)

        try await service.enable(in: database)
        try await service.disable(in: database)

        #expect(await scheduler.queue.isEmpty)
        let settings = try await database.writer.read { db in
            try BudgetSettingsStore().load(db)
        }
        #expect(!settings.payReminderEnabled)
    }

    @Test("a launch with the reminder off schedules nothing")
    func refreshWithReminderOffIsQuiet() async throws {
        let database = try configured()
        let scheduler = FakePayReminderScheduler()

        try await reminders(scheduler).refresh(in: database)
        #expect(await scheduler.queue.isEmpty)
    }

    @Test("remind me tomorrow adds one reminder and leaves the anchor where it was")
    func snoozeAddsOneWithoutMovingTheAnchor() async throws {
        let database = try configured()
        let scheduler = FakePayReminderScheduler()
        let service = reminders(scheduler)

        try await service.enable(in: database)
        let before = await scheduler.queue

        try await service.snoozeUntilTomorrow(in: database)
        let after = await scheduler.queue

        #expect(after.count == before.count + 1)
        let extra = try #require(after.first)
        let parts = melbourne.dateComponents([.month, .day], from: extra)
        #expect(parts.month == 9 && parts.day == 2, "tomorrow, relative to the fixed clock")

        // DEC-036: a snooze "reschedules a single one-shot; it never moves
        // `pay_anchor`". Changing the anchor stays an explicit settings action.
        let settings = try await database.writer.read { db in
            try BudgetSettingsStore().load(db)
        }
        #expect(settings.paySchedule?.anchor == CivilDate(iso: "2026-09-11"))
    }
}
