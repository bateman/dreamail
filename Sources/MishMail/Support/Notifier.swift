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

    static func setBadge(_ count: Int) {
        DispatchQueue.main.async {
            // Classic Dock badge: always works, no permission needed.
            // Capped so a neglected inbox doesn't swallow the whole icon.
            let label = count > 999 ? "999+" : String(count)
            NSApplication.shared.dockTile.badgeLabel = count > 0 ? label : ""
        }
        // Notification-center badge: the channel newer system UI (e.g. the
        // Cmd-Tab switcher) reads. Needs the .badge grant requested at
        // launch; harmless no-op if the user declined notifications.
        // (Numeric API, so the cap is 999 rather than "999+".)
        UNUserNotificationCenter.current().setBadgeCount(min(count, 999)) { _ in }
    }
}
