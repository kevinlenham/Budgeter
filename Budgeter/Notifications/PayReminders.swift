//
//  PayReminders.swift
//  Budgeter
//
//  DEC-036's binding to `UNUserNotificationCenter`, and nothing else.
//
//  Everything decidable without iOS in the room already lives elsewhere and is
//  tested there: which dates the queue should hold is `PayReminderQueue`, and
//  whether to nag about unlogged pay is `PayStatus`. What is left here is the part
//  DEC-036 says "the simulator proves nothing useful" about — so it is kept as thin
//  as it can be made, and put behind a protocol so the service that drives it can
//  be tested against a fake.
//
//  Notes that are easy to lose and expensive to rediscover:
//
//  - This needs **no paid Apple Developer Program membership and no entitlement**.
//    DEC-034 lists Push Notifications among the paid-team features; that is APNs.
//    Local scheduling is unrelated. DEC-036 records this explicitly because the two
//    are conflated constantly.
//  - iOS caps an app at **64 pending notifications** and silently drops the rest.
//    `PayReminderQueue.maximumPending` keeps well inside that.
//  - Under DEC-034's free provisioning the profile expires after 7 days: the
//    notification still fires, but tapping it cannot launch the app until it is
//    re-signed. Expected, not a bug.
//

import Foundation
import UserNotifications

/// What the app needs from the notification system, so the service above it can be
/// driven by a fake in tests.
nonisolated protocol PayReminderScheduling: Sendable {
    /// DEC-024's consent precedent: asked at the moment the user enables the
    /// reminder, never at first launch. Returns whether it was granted.
    func requestAuthorisation() async throws -> Bool
    /// Whether permission currently stands. Checked on launch because it can be
    /// revoked in Settings long after it was granted, and DEC-036 requires that to
    /// degrade rather than break.
    func isAuthorised() async -> Bool
    /// Replaces the whole pay-reminder queue with reminders at these instants.
    /// Every scheduling decision is a full replacement — the queue is small, and
    /// reconciling it incrementally is a second source of truth for no gain.
    func replaceQueue(with dates: [Date]) async throws
    /// Removes every pay reminder and leaves anything else pending alone.
    func clearQueue() async
}

nonisolated enum PayReminderContent {
    /// DEC-025's concern is what is legible before unlock. The reminder carries no
    /// amount by construction — it exists to ask for one — but it does disclose pay
    /// timing, so it names no employer, no account and no figure. Whether previews
    /// show on a locked screen is an iOS-level setting the app cannot control,
    /// which is exactly why the content is safe unconditionally.
    static let title = "Payday"
    static let body = "Log what you were paid"

    static let categoryIdentifier = "payday"
    static let logNowAction = "payday.log-now"
    static let remindTomorrowAction = "payday.remind-tomorrow"

    /// Every pending reminder this app owns is prefixed, so clearing the queue
    /// cannot remove a notification some later sprint scheduled for another reason
    /// (DEC-011's draft digest is the one already in the design).
    static let identifierPrefix = "payday."

    static func identifier(for date: Date) -> String {
        "\(identifierPrefix)\(Int(date.timeIntervalSince1970))"
    }

    /// The two actions DEC-036 asks for. "Remind me tomorrow" reschedules a single
    /// one-shot and **never moves `pay_anchor`** — changing the anchor stays an
    /// explicit settings action, forward-dated, per DEC-007's governing principle.
    static var category: UNNotificationCategory {
        UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [
                UNNotificationAction(
                    identifier: logNowAction,
                    title: "Log now",
                    options: [.foreground]
                ),
                UNNotificationAction(
                    identifier: remindTomorrowAction,
                    title: "Remind me tomorrow",
                    options: []
                ),
            ],
            intentIdentifiers: [],
            options: []
        )
    }
}

nonisolated struct SystemPayReminderScheduler: PayReminderScheduling {
    private var centre: UNUserNotificationCenter {
        .current()
    }

    func requestAuthorisation() async throws -> Bool {
        // Sound and badge are deliberately not requested. One alert a fortnight
        // asking a question does not need a badge, and DEC-011's rationing
        // principle applies to how loud a notification is as much as to how many.
        try await centre.requestAuthorization(options: [.alert])
    }

    func isAuthorised() async -> Bool {
        let settings = await centre.notificationSettings()
        return settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
    }

    func replaceQueue(with dates: [Date]) async throws {
        await clearQueue()
        centre.setNotificationCategories([PayReminderContent.category])

        for date in dates {
            let content = UNMutableNotificationContent()
            content.title = PayReminderContent.title
            content.body = PayReminderContent.body
            content.categoryIdentifier = PayReminderContent.categoryIdentifier

            // Calendar components rather than a time interval: a reminder is "9am
            // on the 14th", and an interval computed today would drift by an hour
            // across a DST transition — the same mistake `CivilDate` exists to make
            // unrepresentable in the storage layer.
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            try await centre.add(
                UNNotificationRequest(
                    identifier: PayReminderContent.identifier(for: date),
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
                )
            )
        }
    }

    func clearQueue() async {
        let pending = await centre.pendingNotificationRequests()
        let ours = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(PayReminderContent.identifierPrefix) }
        centre.removePendingNotificationRequests(withIdentifiers: ours)
    }
}
