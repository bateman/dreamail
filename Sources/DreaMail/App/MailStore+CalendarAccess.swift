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
            if try await CalendarIntegration.shared.connect(accountId: accountId) {
                showNotice("Google Calendar connected for \(accountId)")
            }
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

    /// Account removal: the integration's memory of the account goes with
    /// it (DEC-019). The rows and the Keychain token go with the purge.
    func forgetCalendar(accountId: String) {
        guard CalendarFeatures.isEnabled else { return }
        Task { await CalendarIntegration.shared.forget(accountId: accountId) }
    }

    /// Accept / Decline / Maybe on an invitation card. The e-mail reply goes
    /// first and always (#51's path, DEC-049); only then, and only for the
    /// calendar that holds this very event, is the answer also written in
    /// Google Calendar. A failed calendar write is only reported. Returns
    /// what happened, nil when Calendar took no part.
    @discardableResult
    func answerInvite(_ invite: CalendarInvite, status: CalendarInvite.RSVP,
                      message: Message, check: CalendarInviteCheck?) async -> CalendarAnswerResult? {
        guard calendarUIEnabled, invite.isActionable,
              let response = CalendarResponse(rawValue: status.rawValue.lowercased()) else {
            await rsvpToInvite(invite, status: status, message: message)
            return nil
        }
        let result = await CalendarIntegration.shared.answer(
            response, facts: CalendarInviteFacts(invite), occurrence: invite.recurrenceIdLine,
            findings: check?.findings, accountId: message.accountId) {
                await rsvpToInvite(invite, status: status, message: message)
            }
        if let failure = result.calendarFailure {
            lastError = Self.calendarNotUpdatedMessage(failure)
        }
        return result
    }

    static func calendarNotUpdatedMessage(_ failure: String) -> String {
        "The reply was e-mailed, but Google Calendar was not updated: " + failure
    }

    /// "Add to calendar" on the invitation card. Returns the new findings,
    /// or nil when it failed (the error is shown).
    func addInviteToCalendar(_ invite: CalendarInvite, message: Message,
                             findings: CalendarInviteFindings) async -> CalendarInviteFindings? {
        guard calendarUIEnabled else { return nil }
        let sender = MessageParser.emailAddress(message.fromHeader)
        do {
            // The guest is the address the answer will go from.
            let updated = try await CalendarIntegration.shared.addToCalendar(
                CalendarInviteFacts(invite), occurrence: invite.recurrenceIdLine,
                findings: findings, organizerIsSender: invite.organizerIsSender(senderEmail: sender),
                attendeeEmail: rsvpIdentity(for: message, invite: invite).email,
                messageId: message.id, accountId: message.accountId)
            // Added, or found already there by the fresh lookup.
            showNotice("The event is in Google Calendar")
            return updated
        } catch {
            lastError = Self.calendarErrorMessage(error)
            return nil
        }
    }

    /// An error as the banner shows it: never a server body.
    static func calendarErrorMessage(_ error: Error) -> String {
        if let oauth = error as? OAuthError {
            switch oauth {
            case .tokenExchangeFailed, .authorizationDenied:
                return "Google did not complete the Calendar sign-in. Try again."
            default:
                return oauth.localizedDescription
            }
        }
        return CalendarIntegration.message(for: error)
    }
}
