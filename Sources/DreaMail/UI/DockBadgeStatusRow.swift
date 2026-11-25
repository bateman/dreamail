import SwiftUI
import AppKit

/// Settings ▸ Dock badge: whether macOS lets the badge show, read from the
/// app's notification settings, with a way to the System Settings pane when
/// it does not. Codes and states only, never mail content.
struct DockBadgeStatusRow: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        let summary = DockBadge.summary(store.dockBadgeSystemStatus)
        LabeledContent("Shown by macOS") {
            VStack(alignment: .trailing, spacing: 4) {
                Text(summary.text)
                    .foregroundStyle(summary.problem ? Color.orange : Color.secondary)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("settings.dockBadgeStatus")
                if summary.problem {
                    Button("Open Notification Settings…") {
                        Notifier.openNotificationSettings()
                    }
                }
            }
        }
        .onAppear { store.refreshDockBadgeSystemStatus() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshDockBadgeSystemStatus()
        }
    }
}
