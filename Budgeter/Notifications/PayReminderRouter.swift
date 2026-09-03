//
//  PayReminderRouter.swift
//  Budgeter
//
//  What happens when the user acts on a payday reminder.
//
//  DEC-036: "tapping opens a blank income entry form; nothing is written until the
//  user saves." The app never fills in the amount, and the reason is DEC-012's,
//  restated with less excuse: pay varies, so a stored "expected amount" writes a
//  number nobody checked into account balances, and when the balance later looks
//  wrong there is no way to find the row that lied. A capture draft at least comes
//  from a real card tap; a projected salary comes from nothing at all.
//
//  So this class routes and does not decide. It opens an empty form, or it asks the
//  service to reschedule. It never writes a transaction.
//

import Foundation
import UserNotifications

@MainActor
final class PayReminderRouter: NSObject, UNUserNotificationCenterDelegate {
    /// Open a blank income form. Set by `AppModel`.
    var onLogNow: @MainActor () -> Void = {}
    /// Reschedule a single one-shot for tomorrow, without moving `pay_anchor`.
    var onRemindTomorrow: @MainActor () async -> Void = {}

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        switch response.actionIdentifier {
        case PayReminderContent.remindTomorrowAction:
            await onRemindTomorrow()
        // A plain tap on the notification body arrives as `defaultActionIdentifier`
        // and means the same thing as "Log now" — the user opened the app because
        // it asked them to log their pay.
        case PayReminderContent.logNowAction, UNNotificationResponse.defaultActionIdentifier:
            onLogNow()
        default:
            break
        }
    }

    /// Shown even with the app in the foreground. A reminder the user is looking at
    /// the app for is still the one moment it can ask, and swallowing it would make
    /// "the notification fired but nothing happened" a real diagnosis.
    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
