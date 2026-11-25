import Foundation

/// The Google Calendar actions the UI triggers (step 4A, behind
/// `CalendarFeatures`). Each one goes through `CalendarIntegration`, the
/// Calendar folder's only door; here they get the app's notices and errors.
/// Nothing is logged: calendar names, times and addresses stay on screen.
extension MailStore {
    /// Whether any Calendar UI is shown: the build switch on, and a real
    /// account (the demo inbox has no Google account behind it).
    var calendarUIEnabled: Bool {
        CalendarFeatures.isEnabled && !demoMode
    }

    /// The separate Calendar consent for one account (Settings → Accounts,
    /// or the invitation card's Connect / Reconnect).
    func connectCalendar(accountId: String) async {
        guard calendarUIEnabled else { return }
        do {
            try await CalendarIntegration.shared.connect(accountId: accountId)
            showNotice("Google Calendar connected for \(accountId)")
        } catch {
            lastError = Self.calendarErrorMessage(error)
        }
    }

    func disconnectCalendar(accountId: String) async {
        guard calendarUIEnabled else { return }
        do {
            try await CalendarIntegration.shared.disconnect(accountId: accountId)
            showNotice("Google Calendar disconnected for \(accountId)")
        } catch {
            lastError = Self.calendarErrorMessage(error)
        }
    }

    /// Accept / Decline / Maybe on an invitation card. With Calendar on and
    /// checked, the answer is written on the calendar that holds the event,
    /// and the e-mail reply goes only where the route says so
    /// (`CalendarRSVPRoute`). Otherwise it is the e-mail reply, as before.
    func answerInvite(_ invite: CalendarInvite, status: CalendarInvite.RSVP,
                      message: Message, check: CalendarInviteCheck?) async {
        guard calendarUIEnabled, invite.isActionable, let findings = check?.findings,
              let response = CalendarResponse(rawValue: status.rawValue.lowercased()) else {
            await rsvpToInvite(invite, status: status, message: message)
            return
        }
        let route: CalendarRSVPRoute
        do {
            route = try await CalendarIntegration.shared.respond(
                response, facts: CalendarInviteFacts(invite), findings: findings,
                accountId: message.accountId)
        } catch {
            // Nothing was sent: the user can try again.
            lastError = Self.calendarErrorMessage(error)
            return
        }
        switch route {
        case .notAnswerable:
            lastError = "This invite can't be answered."
        case .emailOnly, .calendarAndEmail:
            await rsvpToInvite(invite, status: status, message: message)
        case .calendarOnly:
            let accountId = message.accountId, messageId = message.id
            _ = try? await db.write { db in
                try CalendarRSVPStore.record(
                    db, status: status, invite: invite,
                    accountId: accountId, messageId: messageId)
            }
            showNotice("\(status.subjectPrefix) — saved in Google Calendar")
        }
    }

    /// "Add to calendar" on the invitation card. Returns the new findings,
    /// or nil when it failed (the error is shown).
    func addInviteToCalendar(_ invite: CalendarInvite, message: Message,
                             findings: CalendarInviteFindings) async -> CalendarInviteFindings? {
        guard calendarUIEnabled else { return nil }
        do {
            let updated = try await CalendarIntegration.shared.addToCalendar(
                CalendarInviteFacts(invite), findings: findings,
                messageId: message.id, accountId: message.accountId)
            showNotice("Added to Google Calendar")
            return updated
        } catch {
            lastError = Self.calendarErrorMessage(error)
            return nil
        }
    }

    /// An error as the banner shows it: Calendar errors carry no response
    /// body; anything else gets a fixed sentence.
    static func calendarErrorMessage(_ error: Error) -> String {
        if let calendarError = error as? CalendarError {
            return calendarError.errorDescription ?? "Google Calendar failed."
        }
        if TransientNetworkError.isTransient(error) {
            return "You're offline — Google Calendar can't be reached."
        }
        if error is OAuthError { return error.localizedDescription }
        return "Google Calendar failed."
    }
}
