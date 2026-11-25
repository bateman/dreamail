import SwiftUI

/// How far back mail is downloaded, per account. Changing it triggers a sync
/// right away: widening backfills older mail, narrowing removes local copies
/// outside the window (Gmail is untouched), and "Nothing" removes all of the
/// account's mail from this Mac. SyncEngine reads the same key.
struct SyncWindowPicker: View {
    @Environment(MailStore.self) var store
    let accountId: String
    @State private var days: Int

    init(accountId: String) {
        self.accountId = accountId
        _days = State(initialValue: SyncEngine.syncWindowDays(for: accountId))
    }

    var body: some View {
        Picker("Keep mail from", selection: $days) {
            Text("Last 30 days").tag(30)
            Text("Last 90 days").tag(90)
            Text("Last year").tag(365)
            Text("Last 3 years").tag(1095)
            Text("Everything").tag(0)
            Divider()
            Text("Nothing (remove from this Mac)").tag(SyncEngine.windowNothing)
        }
        .onChange(of: days) {
            // A picker still on screen for an account just removed writes
            // nothing for it (DEC-019).
            guard store.isKnownAccount(accountId) else { return }
            UserDefaults.standard.set(days, forKey: "syncWindowDays.\(accountId)")
            // Older mail now downloaded is not new mail.
            store.quietNewMailBacklog(accountId: accountId, restart: true)
            Task { await store.sync(accountId: accountId) }
        }
    }
}
