import SwiftUI

/// Gmail-style calendar invite card: title, when, where, and
/// Accept / Decline / Maybe. Loads the `.ics` attachment, parses it, and
/// posts an iTIP METHOD:REPLY via `MailStore.rsvpToInvite`.
///
/// RSVP does not write to any local calendar — use **Open in Calendar** (or
/// Save / Quick Look) to hand the original `.ics` to Calendar.app.
///
/// With the Google Calendar build switch on (`MailStore.calendarUIEnabled`)
/// the card also says whether the user is free, offers "Add to Calendar"
/// and answers on the Google calendar that holds the event, through
/// `MailStore.answerInvite`. With it off the card is exactly as before.
struct CalendarInviteCard: View {
    @Environment(\.mailAccent) private var accent
    @Environment(MailStore.self) private var store
    let message: Message
    let attachment: AttachmentRow
    var fontScale: Double = 1.0

    /// All VEVENTs from the ICS (multi-slot / series+exception files).
    private enum InviteLoad { case loading, loaded([CalendarInvite]), failed(String) }
    @State private var load: InviteLoad = .loading
    private struct PendingResponse {
        let key: String
        let status: CalendarInvite.RSVP
    }
    @State private var sending: PendingResponse?
    @State private var localRSVPByKey: [String: CalendarInvite.RSVP] = [:]
    /// Google Calendar's view of each invite, by `rsvpKey` (step 4A, only
    /// with `MailStore.calendarUIEnabled`). In memory: nothing is stored.
    @State private var calendarChecks: [String: CalendarInviteCheck] = [:]
    @State private var addingToCalendar: String?

    var body: some View {
        Group {
            switch load {
            case .loading:
                loadingRow
            case .loaded(let invites):
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(invites.enumerated()), id: \.offset) { _, invite in
                        inviteBody(invite)
                    }
                }
            case .failed(let loadError):
                Text(loadError)
                    .font(PMFont.caption(fontScale))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: PMRadius.md))
            }
        }
        .task(id: "\(message.id)|\(attachment.id ?? 0)") {
            await loadInvite()
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading calendar invite…")
                .font(PMFont.caption(fontScale))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: PMRadius.md))
    }

    @ViewBuilder
    private func inviteBody(_ invite: CalendarInvite) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: invite.isCancelled
                      ? "calendar.badge.minus" : "calendar")
                    .font(.system(size: 18 * fontScale, weight: .semibold))
                    .foregroundStyle(invite.isCancelled ? Color.secondary : accent.foreground)
                    .frame(width: 28, height: 28)
                    .background(
                        (invite.isCancelled ? Color.secondary : accent.fill)
                            .opacity(0.12),
                        in: RoundedRectangle(cornerRadius: PMRadius.sm)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(invite.summary)
                        .font(.system(size: 13.5 * fontScale, weight: .semibold))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                    Text(invite.whenDescription())
                        .font(PMFont.secondary(fontScale))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let repeats = invite.repeatDescription {
                        Label(repeats, systemImage: "repeat")
                            .font(PMFont.caption(fontScale))
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }
                    if !invite.location.isEmpty {
                        Label(invite.location, systemImage: "mappin.and.ellipse")
                            .font(PMFont.caption(fontScale))
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                            .textSelection(.enabled)
                    }
                    if !invite.organizerEmail.isEmpty {
                        let email = CalendarInvite.displaySafe(
                            invite.organizerEmail, limit: 254)
                        let who = invite.organizerName.isEmpty
                            ? email
                            : "\(invite.organizerName) <\(email)>"
                        Text("Organizer · \(who)")
                            .font(PMFont.caption(fontScale))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }

            if invite.isCancelled {
                HStack(spacing: 8) {
                    statusPill("Cancelled", color: .secondary)
                    Spacer(minLength: 0)
                    fileActions
                }
            } else if invite.isActionable {
                if store.calendarUIEnabled {
                    calendarRow(invite)
                }
                rsvpRow(for: invite)
                replyRecipientNote(invite)
            } else {
                // PUBLISH / REPLY / unknown METHOD: show the event but don't
                // offer Accept (would email an untrusted ORGANIZER). Still
                // let the user open the .ics in Calendar.app.
                HStack(spacing: 8) {
                    statusPill(statusLabel(invite), color: .secondary)
                    Spacer(minLength: 0)
                    fileActions
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: PMRadius.md))
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.md)
                .strokeBorder(
                    invite.isActionable
                        ? accent.fill.opacity(0.22)
                        : Color.primary.opacity(0.08),
                    lineWidth: 1)
        }
        .contextMenu {
            Button("Open in Calendar") {
                store.openAttachment(attachment, message: message)
            }
            Button("Quick Look") {
                store.quickLookAttachment(attachment, message: message)
            }
            Button("Save As…") {
                store.saveAttachment(attachment, message: message)
            }
        }
    }

    @ViewBuilder
    private func rsvpRow(for invite: CalendarInvite) -> some View {
        let key = rsvpKey(invite)
        HStack(spacing: 8) {
            ForEach(CalendarInvite.RSVP.allCases, id: \.rawValue) { status in
                rsvpButton(status, invite: invite)
            }
            Spacer(minLength: 0)
            if let local = localRSVPByKey[key] {
                statusPill(local.subjectPrefix, color: tint(for: local))
            }
            fileActions
        }
    }

    /// Where Accept / Decline / Maybe sends the reply: the ICS's ORGANIZER,
    /// which its author chose. Always shown; flagged when it is not the
    /// address the message came from (a forged invite would otherwise make
    /// the user answer a third party unseen).
    /// Where Accept / Decline / Maybe sends the reply, and from which
    /// address: the ICS's ORGANIZER, which its author chose. Always shown;
    /// flagged when it is not the address the message came from (a forged
    /// invite would otherwise make the user answer a third party unseen).
    ///
    /// With Google Calendar connected, the line follows the route the
    /// buttons take (`CalendarRSVPRoute`): on the calendar, by e-mail, or
    /// both. Until the calendar is checked the answer goes by e-mail, and
    /// the line says so.
    @ViewBuilder
    private func replyRecipientNote(_ invite: CalendarInvite) -> some View {
        let sender = MessageParser.emailAddress(message.fromHeader)
        let from = store.rsvpIdentity(for: message, invite: invite).email
        let route = answerRoute(invite)
        if route != .emailOnly {
            let note = CalendarAnswerNote.text(route: route, accountId: message.accountId,
                                               from: from, organizer: invite.organizerEmail)
            if invite.organizerIsSender(senderEmail: sender) {
                Text(note)
                    .font(PMFont.caption(fontScale))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            } else {
                Label("\(note) The organizer \(invite.organizerEmail) is not the sender \(CalendarInvite.displaySafe(sender, limit: 254)).",
                      systemImage: "exclamationmark.triangle")
                    .font(PMFont.caption(fontScale))
                    .foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
                    .textSelection(.enabled)
            }
        } else if invite.organizerIsSender(senderEmail: sender) {
            Text("Reply from \(from) goes to \(invite.organizerEmail)")
                .font(PMFont.caption(fontScale))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        } else {
            Label("Reply from \(from) goes to \(invite.organizerEmail), not to the sender \(CalendarInvite.displaySafe(sender, limit: 254))",
                  systemImage: "exclamationmark.triangle")
                .font(PMFont.caption(fontScale))
                .foregroundStyle(.orange)
                .labelStyle(.titleAndIcon)
                .textSelection(.enabled)
        }
    }

    private func rsvpKey(_ invite: CalendarInvite) -> String {
        CalendarInvite.rsvpDefaultsKey(
            accountId: message.accountId, uid: invite.uid,
            recurrenceIdLine: invite.recurrenceIdLine)
    }

    /// Hand the original .ics to Calendar.app / Quick Look / Save — RSVP
    /// alone never writes a local event.
    private var fileActions: some View {
        HStack(spacing: 4) {
            Button {
                store.openAttachment(attachment, message: message)
            } label: {
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 13 * fontScale))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open in Calendar")

            Button {
                store.quickLookAttachment(attachment, message: message)
            } label: {
                Image(systemName: "eye")
                    .font(.system(size: 13 * fontScale))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Quick Look")

            Button {
                store.saveAttachment(attachment, message: message)
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 13 * fontScale))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Save As…")
        }
    }

    private func rsvpButton(_ status: CalendarInvite.RSVP,
                            invite: CalendarInvite) -> some View {
        let key = rsvpKey(invite)
        let selected = localRSVPByKey[key] == status
        let busy = sending != nil
        let thisSending = sending?.key == key && sending?.status == status
        return Button {
            guard sending == nil else { return }
            sending = PendingResponse(key: key, status: status)
            Task { await respond(status, invite: invite) }
        } label: {
            HStack(spacing: 5) {
                if thisSending {
                    ProgressView().controlSize(.mini)
                }
                Text(status.buttonTitle)
                    .font(.system(size: 12.5 * fontScale, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                selected
                    ? tint(for: status).opacity(0.18)
                    : Color.secondary.opacity(0.12),
                in: Capsule()
            )
            .foregroundStyle(selected ? tint(for: status) : Color.primary)
            .overlay {
                Capsule()
                    .strokeBorder(
                        selected ? tint(for: status).opacity(0.45) : Color.clear,
                        lineWidth: 1)
            }
        }
        .buttonStyle(PressScaleButtonStyle(enabled: !busy))
        .disabled(busy)
        .help(helpText(for: status, invite: invite))
    }

    private func statusPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11 * fontScale, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func tint(for status: CalendarInvite.RSVP) -> Color {
        switch status {
        case .accepted: return .green
        case .declined: return .red
        case .tentative: return .orange
        }
    }

    /// Pill for an invite without buttons.
    private func statusLabel(_ invite: CalendarInvite) -> String {
        if invite.method == .request {
            return "Can't reply to this invite"
        }
        if let summary = invite.replySummary(
            senderEmail: MessageParser.emailAddress(message.fromHeader)) {
            return summary
        }
        return methodLabel(invite.method)
    }

    private func methodLabel(_ method: CalendarInvite.Method) -> String {
        switch method {
        case .publish: return "Published event"
        case .reply: return "RSVP reply"
        case .cancel: return "Cancelled"
        case .counter: return "Counter proposal"
        case .refresh: return "Refresh request"
        case .add: return "Added event"
        case .declineCounter: return "Counter proposal declined"
        case .unknown: return "Calendar event"
        case .request: return "Invitation"
        }
    }

    private func helpText(for status: CalendarInvite.RSVP,
                          invite: CalendarInvite) -> String {
        let org = invite.organizerEmail.isEmpty ? "the organizer" : invite.organizerEmail
        switch answerRoute(invite) {
        case .calendarOnly: return "\(status.buttonTitle) in Google Calendar"
        case .calendarAndEmail: return "\(status.buttonTitle) in Google Calendar and email \(org)"
        case .emailOnly, .notAnswerable: return "\(status.buttonTitle) and email \(org)"
        }
    }

    /// Where the buttons send the answer: the e-mail reply unless Google
    /// Calendar was checked and holds the event.
    private func answerRoute(_ invite: CalendarInvite) -> CalendarRSVPRoute {
        guard store.calendarUIEnabled,
              let findings = calendarChecks[rsvpKey(invite)]?.findings else { return .emailOnly }
        return findings.route(for: CalendarInviteFacts(invite))
    }

    // MARK: - Load / respond

    private func loadInvite() async {
        load = .loading
        // Refused before the download, not after: the row's size is known.
        guard attachment.size <= CalendarInvite.Limits.maxBytes else {
            load = .failed("This calendar invite is too large to read.")
            return
        }
        do {
            let data = try await store.downloadAttachment(attachment, message: message)
            guard !Task.isCancelled else { return }
            let parsed = CalendarInvite.parseAll(data)
            guard !parsed.isEmpty else {
                load = .failed("Couldn't read this calendar invite.")
                return
            }
            load = .loaded(parsed)
            let map = await store.storedRSVPs(for: parsed, accountId: message.accountId)
            guard !Task.isCancelled else { return }
            localRSVPByKey = map
            // After the card is on screen: the calendar line fills in on
            // its own, nothing waits for it.
            if store.calendarUIEnabled {
                for invite in parsed where invite.isActionable {
                    guard !Task.isCancelled else { return }
                    await checkCalendar(invite)
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            load = .failed(error.localizedDescription)
        }
    }

    private func respond(_ status: CalendarInvite.RSVP,
                         invite: CalendarInvite) async {
        let key = rsvpKey(invite)
        defer { sending = nil }
        await store.answerInvite(invite, status: status, message: message,
                                 check: calendarChecks[key])
        // Re-read stored state — only updates on success.
        if let stored = await store.storedRSVPs(
            for: [invite], accountId: message.accountId)[key] {
            withAnimation(PMMotion.feedback) { localRSVPByKey[key] = stored }
        }
    }

    // MARK: - Google Calendar (step 4A)

    private func checkCalendar(_ invite: CalendarInvite) async {
        let key = rsvpKey(invite)
        calendarChecks[key] = .checking
        let check = await CalendarIntegration.shared.check(
            CalendarInviteFacts(invite), messageId: message.id, accountId: message.accountId)
        guard !Task.isCancelled else { return }
        calendarChecks[key] = check
    }

    private func addToCalendar(_ invite: CalendarInvite, findings: CalendarInviteFindings) async {
        let key = rsvpKey(invite)
        guard addingToCalendar == nil else { return }
        addingToCalendar = key
        defer { addingToCalendar = nil }
        if let updated = await store.addInviteToCalendar(invite, message: message, findings: findings) {
            calendarChecks[key] = .ready(updated)
        }
    }

    private func connectCalendar(_ invite: CalendarInvite) async {
        await store.connectCalendar(accountId: message.accountId)
        if case .connected = CalendarIntegration.shared.status(for: message.accountId) {
            await checkCalendar(invite)
        }
    }

    /// Availability and where the event is, under the invite's details.
    /// Never blocks the card: a small inline state while checking.
    @ViewBuilder
    private func calendarRow(_ invite: CalendarInvite) -> some View {
        let key = rsvpKey(invite)
        switch calendarChecks[key] ?? .checking {
        case .off:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                calendarCaption("Checking your Google Calendar…")
            }
        case .notConnected:
            HStack(spacing: 6) {
                calendarCaption("Google Calendar isn't connected for \(message.accountId).")
                calendarLinkButton("Connect…") { await connectCalendar(invite) }
            }
        case .needsConsent:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(PMFont.caption(fontScale))
                    .foregroundStyle(.orange)
                calendarCaption("Google Calendar needs your permission again.")
                calendarLinkButton("Reconnect…") { await connectCalendar(invite) }
            }
        case .offline:
            HStack(spacing: 6) {
                calendarCaption("Offline — your calendar can't be checked. Answers go by e-mail.")
                calendarLinkButton("Retry") { await checkCalendar(invite) }
            }
        case .failed(let text):
            HStack(spacing: 6) {
                calendarCaption("\(text) — answers go by e-mail.")
                calendarLinkButton("Retry") { await checkCalendar(invite) }
            }
        case .ready(let findings):
            VStack(alignment: .leading, spacing: 3) {
                availabilityLine(findings.availability)
                if findings.event == nil {
                    HStack(spacing: 6) {
                        calendarCaption("Not in your Google Calendar.")
                        if findings.canAddToCalendar(CalendarInviteFacts(invite)) {
                            if addingToCalendar == key {
                                ProgressView().controlSize(.mini)
                            } else {
                                calendarLinkButton("Add to Calendar") {
                                    await addToCalendar(invite, findings: findings)
                                }
                                .disabled(addingToCalendar != nil)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func availabilityLine(_ result: CalendarAvailabilityResult?) -> some View {
        if let result {
            if result.isFree {
                Label(result.isIncomplete
                      ? "You're free on the calendars that could be checked"
                      : "You're free",
                      systemImage: "checkmark.circle")
                    .font(PMFont.caption(fontScale))
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Label(conflictText(result), systemImage: "exclamationmark.circle")
                    .font(PMFont.caption(fontScale))
                    .foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }

    /// "Conflicts with Standup (10:00–10:30)"; all-day events are named
    /// softly. Titles stay on screen, never in a log.
    private func conflictText(_ result: CalendarAvailabilityResult) -> String {
        func name(_ busy: CalendarBusy) -> String {
            switch busy.source {
            case .event(_, _, let summary):
                return (summary?.isEmpty == false ? summary : nil) ?? "Busy"
            case .freeBusy:
                return "Busy"
            }
        }
        func time(_ busy: CalendarBusy) -> String {
            let start = busy.span.start.formatted(date: .omitted, time: .shortened)
            let end = busy.span.end.formatted(date: .omitted, time: .shortened)
            return "\(start)–\(end)"
        }
        var parts: [String] = []
        let timed = result.conflicts.prefix(2).map { "\(name($0)) (\(time($0)))" }
        if !timed.isEmpty {
            var text = "Conflicts with " + timed.joined(separator: ", ")
            if result.conflicts.count > 2 { text += " and \(result.conflicts.count - 2) more" }
            parts.append(text)
        }
        if let allDay = result.allDayConflicts.first {
            parts.append("Same day as \(name(allDay)) (all day)")
        }
        return parts.joined(separator: " · ")
    }

    private func calendarCaption(_ text: String) -> some View {
        Text(text)
            .font(PMFont.caption(fontScale))
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    private func calendarLinkButton(_ title: String,
                                    action: @escaping () async -> Void) -> some View {
        Button(title) { Task { await action() } }
            .buttonStyle(.link)
            .font(PMFont.caption(fontScale))
    }
}
