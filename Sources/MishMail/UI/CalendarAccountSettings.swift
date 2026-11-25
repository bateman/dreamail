import SwiftUI

/// Settings → Accounts, one account: connect or disconnect Google Calendar,
/// and choose which calendars count for availability and conflicts (the
/// primary one by default). Shown only when `MailStore.calendarUIEnabled`.
struct CalendarAccountSettings: View {
    @Environment(MailStore.self) private var store
    let accountId: String
    @State private var choosing = false
    @State private var confirmingDisconnect = false

    private var calendar: CalendarIntegration { .shared }

    var body: some View {
        let status = calendar.status(for: accountId)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Google Calendar", systemImage: "calendar")
                statusBadge(status)
                Spacer()
                buttons(status)
            }
            if status.grant?.canListCalendars == true {
                HStack(alignment: .firstTextBaseline) {
                    Text(chosenSummary)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button("Choose Calendars…") { choosing = true }
                        .accessibilityIdentifier("settings.calendar.choose")
                }
            }
        }
        .task(id: accountId) { await calendar.load(accountId: accountId) }
        .sheet(isPresented: $choosing) {
            CalendarChoiceSheet(accountId: accountId)
        }
        .confirmationDialog("Disconnect Google Calendar?", isPresented: $confirmingDisconnect) {
            Button("Disconnect \(accountId)", role: .destructive) {
                Task { await store.disconnectCalendar(accountId: accountId) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("MishMail forgets the Calendar sign-in and the calendars you chose for this account. Mail is not affected.")
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: CalendarAccountStatus) -> some View {
        switch status {
        case .off:
            EmptyView()
        case .notConnected:
            Text("Not connected").font(.caption).foregroundStyle(.secondary)
        case .connected:
            Text("Connected").font(.caption).foregroundStyle(.secondary)
        case .needsConsent:
            Label("Needs permission again", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(.orange)
                .help("Google no longer accepts this account's Calendar access (revoked or expired). Reconnect to use it again.")
                .accessibilityLabel("Google Calendar needs your permission again")
        }
    }

    @ViewBuilder
    private func buttons(_ status: CalendarAccountStatus) -> some View {
        let busy = calendar.connecting.contains(accountId)
        switch status {
        case .off:
            EmptyView()
        case .notConnected:
            Button(busy ? "Connecting…" : "Connect…") {
                Task { await store.connectCalendar(accountId: accountId) }
            }
            .disabled(busy)
            .accessibilityIdentifier("settings.calendar.connect")
        case .connected:
            Button("Disconnect", role: .destructive) { confirmingDisconnect = true }
                .disabled(busy)
        case .needsConsent:
            Button(busy ? "Connecting…" : "Reconnect…") {
                Task { await store.connectCalendar(accountId: accountId) }
            }
            .disabled(busy)
            .accessibilityIdentifier("settings.calendar.reconnect")
            Button("Disconnect", role: .destructive) { confirmingDisconnect = true }
                .disabled(busy)
        }
    }

    private var chosenSummary: String {
        let names = (calendar.chosen[accountId] ?? []).map { source in
            source.isPrimary ? "Primary" : Self.safeName(source.summary ?? source.calendarId)
        }
        return names.isEmpty
            ? "No calendar counts for availability."
            : "Counts for availability: " + names.joined(separator: ", ")
    }

    /// Calendar names come from Google, set by whoever shares the calendar.
    static func safeName(_ name: String) -> String {
        CalendarInvite.displaySafe(name, limit: 80)
    }
}

/// The calendars Google lists for the account, each with a checkbox. Read
/// from Google when the sheet opens; only the ticked ones are stored.
private struct CalendarChoiceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let accountId: String

    private enum Load: Equatable {
        case loading
        case loaded([GCalendarListEntry])
        case failed(String)
    }
    @State private var load: Load = .loading
    @State private var ticked: Set<String> = []
    @State private var saving = false
    @State private var saveError: String?

    private var calendar: CalendarIntegration { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Calendars for availability")
                .font(.headline)
            Text("Invitations are checked against these calendars for conflicts. Only your choice is stored on this Mac, never the events.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content
                .frame(minHeight: 160, maxHeight: 320)
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || ticked.isEmpty || !isLoaded)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task(id: accountId) { await fetch() }
    }

    private var isLoaded: Bool {
        if case .loaded = load { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch load {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading your calendars…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 8) {
                Text(message).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") { Task { await fetch() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let entries):
            List(entries, id: \.id) { entry in
                Toggle(isOn: binding(entry.id)) {
                    VStack(alignment: .leading, spacing: 1) {
                        let name = CalendarAccountSettings.safeName(entry.summary ?? entry.id)
                        Text(entry.primary == true ? "\(name) (primary)" : name)
                        if entry.accessRole == "freeBusyReader" {
                            Text("Busy times only")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { ticked.contains(id) },
                set: { on in if on { ticked.insert(id) } else { ticked.remove(id) } })
    }

    private func fetch() async {
        load = .loading
        do {
            let entries = try await calendar.calendarList(accountId: accountId)
            let chosen = Set((calendar.chosen[accountId] ?? []).map(\.calendarId))
            // "primary" is the API's alias for the user's own calendar.
            ticked = Set(entries.filter {
                chosen.contains($0.id) || ($0.primary == true && chosen.contains("primary"))
            }.map(\.id))
            load = .loaded(entries)
        } catch {
            load = .failed(Self.message(for: CalendarIntegration.check(for: error)))
        }
    }

    private func save() async {
        guard case .loaded(let entries) = load else { return }
        saving = true
        defer { saving = false }
        do {
            try await calendar.choose(entries.filter { ticked.contains($0.id) }, accountId: accountId)
            dismiss()
        } catch {
            saveError = MailStore.calendarErrorMessage(error)
        }
    }

    private static func message(for check: CalendarInviteCheck) -> String {
        switch check {
        case .offline: return "You're offline. Connect to the internet to choose calendars."
        case .needsConsent:
            return "Google no longer accepts this account's Calendar access. Close this and choose Reconnect…"
        case .failed(let message): return message
        default: return "Google Calendar could not be read."
        }
    }
}
