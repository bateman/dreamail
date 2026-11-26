import Foundation
import AppKit
import UserNotifications

/// Native notifications for new mail and due reminders, plus the dock badge.
enum Notifier {
    /// `resolved` runs once the user has answered (or had answered before).
    static func requestPermission(resolved: @escaping @Sendable () -> Void = {}) {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge, .sound]
        ) { _, _ in resolved() }
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

    /// Error code of the last notification-center badge call; nil when it
    /// succeeded. Shown in Settings (`DockBadge.summary`), never logged.
    @MainActor private(set) static var lastBadgeErrorCode: Int?

    /// Paints `count` on the Dock. Call through `MailStore`, which owns the
    /// count (`DockBadge.Counter`).
    @MainActor
    static func setBadge(_ count: Int) {
        badgeRequest += 1
        let request = badgeRequest
        let label = DockBadge.label(for: count)
        // Classic Dock badge, the documented AppKit API. Whether macOS
        // shows it when the app's notification badges are off in System
        // Settings is not established here; Settings reports that state.
        NSApplication.shared.dockTile.badgeLabel = label
        // Notification-center badge, which other system UI may read. It
        // needs the .badge grant and takes a number. In case it repaints
        // the tile itself (as "999", or cleared when not allowed), the
        // label goes back on once it is done, unless a newer count has been
        // painted meanwhile.
        UNUserNotificationCenter.current().setBadgeCount(
            DockBadge.systemCount(for: count)
        ) { error in
            let code = (error as NSError?)?.code
            Task { @MainActor in
                lastBadgeErrorCode = code
                guard request == badgeRequest else { return }
                NSApplication.shared.dockTile.badgeLabel = label
            }
        }
    }

    /// Removes the badge at quit: the label (gone with the process anyway)
    /// and the notification-center count, which the system keeps after the
    /// process exits. Waits for the system, but never longer than
    /// `timeout`, so quitting cannot hang on it. Delivered notifications
    /// stay.
    @MainActor
    static func clearBadge(timeout: Duration = .seconds(1)) async {
        badgeRequest += 1 // a late `setBadge` callback must not repaint
        NSApplication.shared.dockTile.badgeLabel = ""
        await BoundedWait.run(timeout: timeout) { done in
            UNUserNotificationCenter.current().setBadgeCount(0) { _ in done() }
        }
    }

    /// Reads what the notification settings allow for the badge.
    @MainActor
    static func readBadgeStatus(
        _ done: @escaping @MainActor @Sendable (DockBadge.SystemStatus) -> Void
    ) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let authorization: DockBadge.Authorization
            switch settings.authorizationStatus {
            case .notDetermined: authorization = .notDetermined
            case .denied: authorization = .denied
            default: authorization = .allowed
            }
            let badgeEnabled = settings.badgeSetting == .enabled
            Task { @MainActor in
                done(DockBadge.status(authorization: authorization,
                                      badgeEnabled: badgeEnabled,
                                      lastErrorCode: lastBadgeErrorCode))
            }
        }
    }

    /// System Settings ▸ Notifications.
    static func openNotificationSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
