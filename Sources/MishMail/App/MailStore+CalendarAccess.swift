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

    /// Accept / Decline / Maybe on an invitation card. The e-mail reply
    /// always goes (#51's path, DEC-049). With Calendar on and checked, the
    /// answer is first written on the calendar that holds this very event
    /// (`CalendarRSVPRoute`); a failed calendar write never holds back the
    /// e-mail. Returns the calendar outcome, nil when Calendar took no part.
    @discardableResult
    func answerInvite(_ invite: CalendarInvite, status: CalendarInvite.RSVP,
                      message: Message, check: CalendarInviteCheck?) async -> CalendarRSVPOutcome? {
        guard calendarUIEnabled, invite.isActionable, let findings = check?.findings,
              let response = CalendarResponse(rawValue: status.rawValue.lowercased()) else {
            await rsvpToInvite(invite, status: status, message: message)
            return nil
        }
        let outcome = await CalendarIntegration.shared.respond(
            response, facts: CalendarInviteFacts(invite), findings: findings,
            messageId: message.id, accountId: message.accountId)
        guard outcome.route.sendsEmail else {
            lastError = "This invite can't be answered."
            return outcome
        }
        let before = presentedError
        await rsvpToInvite(invite, status: status, message: message)
        // Only when the e-mail itself raised nothing: its error matters more.
        if let error = outcome.calendarError, !outcome.eventGone, presentedError == before {
            lastError = "The reply was e-mailed, but Google Calendar was not updated: "
                + Self.calendarErrorMessage(error)
        }
        return outcome
    }

    /// "Add to calendar" on the invitation card. Returns the new findings,
    /// or nil when it failed (the error is shown).
    func addInviteToCalendar(_ invite: CalendarInvite, message: Message,
                             findings: CalendarInviteFindings) async -> CalendarInviteFindings? {
        guard calendarUIEnabled else { return nil }
        do {
            // The guest is the address the answer will go from.
            let updated = try await CalendarIntegration.shared.addToCalendar(
                CalendarInviteFacts(invite), findings: findings,
                attendeeEmail: rsvpIdentity(for: message, invite: invite).email,
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
