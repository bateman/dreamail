import Foundation
import AppKit
import UserNotifications

/// Native notifications for new mail and due reminders, plus the dock badge.
enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
    }

    /// Posts what `NotificationContent` decided; callers never build the
    /// text themselves, so the privacy default cannot be bypassed.
    static func notify(_ request: NotificationContent.Request) {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        let request = UNNotificationRequest(identifier: request.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Withdraws the delivered and pending notifications of a removed
    /// account, plus any from earlier builds whose identifiers name no
    /// account (see `NotificationContent.belongs`).
    static func removeNotifications(forAccount accountId: String) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let ids = delivered.map(\.request.identifier)
                .filter { NotificationContent.belongs($0, toAccount: accountId) }
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
        center.getPendingNotificationRequests { pending in
            let ids = pending.map(\.identifier)
                .filter { NotificationContent.belongs($0, toAccount: accountId) }
            if !ids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ids) }
        }
    }

    /// Withdraws the notifications of threads whose mail was deleted.
    static func removeNotifications(withIdentifiers ids: [String]) {
        guard !ids.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// Newest `setBadge` call; an older call's late callback must not
    /// repaint over it.
    @MainActor private static var badgeRequest = 0

    /// Paints `count` on the Dock. Call through `MailStore.publishDockBadge`.
    @MainActor
    static func setBadge(_ count: Int) {
        badgeRequest += 1
        let request = badgeRequest
        let label = DockBadge.label(for: count)
        // Classic Dock badge: works without the notification grant. Capped
        // so a neglected inbox doesn't swallow the whole icon.
        NSApplication.shared.dockTile.badgeLabel = label
        // Notification-center badge: the channel newer system UI (e.g. the
        // Cmd-Tab switcher) reads. Needs the .badge grant requested at
        // launch; harmless no-op if the user declined notifications. It
        // takes a number, so above the cap it would repaint the tile as
        // "999": once it is done, the label goes back on, unless a newer
        // count has been painted meanwhile.
        UNUserNotificationCenter.current().setBadgeCount(
            DockBadge.systemCount(for: count)
        ) { _ in
            Task { @MainActor in
                guard request == badgeRequest else { return }
                NSApplication.shared.dockTile.badgeLabel = label
            }
        }
    }
}
