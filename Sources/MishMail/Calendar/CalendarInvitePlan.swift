import Foundation

/// What the Calendar integration needs from one invitation, read from the
/// parsed ICS (`CalendarInvite`). A separate value so the Calendar code
/// does not depend on the parser's internals.
struct CalendarInviteFacts: Equatable, Sendable {
    var uid: String
    var summary: String
    var location: String
    var organizerEmail: String
    var span: CalendarSpan?
    /// A reply to one occurrence of a series (`RECURRENCE-ID`).
    var isSingleOccurrence: Bool
    /// The ICS was produced by Google Calendar (`PRODID`), so the organizer
    /// keeps the event in Google Calendar and sees an answer written there.
    var organizerUsesGoogleCalendar: Bool

    init(uid: String, summary: String = "", location: String = "", organizerEmail: String = "",
         span: CalendarSpan?, isSingleOccurrence: Bool = false,
         organizerUsesGoogleCalendar: Bool = false) {
        self.uid = uid
        self.summary = summary
        self.location = location
        self.organizerEmail = organizerEmail
        self.span = span
        self.isSingleOccurrence = isSingleOccurrence
        self.organizerUsesGoogleCalendar = organizerUsesGoogleCalendar
    }

    init(_ invite: CalendarInvite) {
        var span: CalendarSpan?
        // A time read in the local zone because its TZID could not be
        // resolved is not the real instant: no availability, no import.
        if invite.unresolvedTZID == nil, let start = invite.start {
            let end = invite.end ?? start
            if end >= start { span = CalendarSpan(start: start, end: end, isAllDay: invite.isAllDay) }
        }
        self.init(uid: invite.uid, summary: invite.summary, location: invite.location,
                  organizerEmail: invite.organizerEmail, span: span,
                  isSingleOccurrence: invite.recurrenceIdLine != nil,
                  organizerUsesGoogleCalendar: Self.isGoogleCalendarICS(invite.sourceICS))
    }

    /// `PRODID:-//Google Inc//Google Calendar 70.9054//EN`, as Google
    /// Calendar (consumer and Workspace) writes it. Only the calendar
    /// object's own PRODID line counts.
    static func isGoogleCalendarICS(_ ics: String) -> Bool {
        for raw in ics.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.uppercased().hasPrefix("PRODID:") else { continue }
            let value = line.dropFirst("PRODID:".count).lowercased()
            return value.hasPrefix("-//google inc//google calendar")
        }
        return false
    }
}

/// Where the answer to an invitation goes (owner's decision for step 4A:
/// on the calendar for events already in Google Calendar, by e-mail for the
/// others).
enum CalendarRSVPRoute: Equatable, Sendable {
    /// The event is in the user's Google Calendar and the organizer uses
    /// Google Calendar: the answer written there reaches the organizer's
    /// event; no e-mail.
    case calendarOnly(calendarId: String, eventId: String)
    /// The event is in Google Calendar but the organizer does not use it:
    /// write the answer there (so the user's calendar is right) and send
    /// the iTIP e-mail too, because it is not verified that Google tells an
    /// outside organizer. Google is asked to send nothing (`none`), so the
    /// organizer does not get two answers.
    case calendarAndEmail(calendarId: String, eventId: String)
    /// Not in Google Calendar, Calendar not connected, or one occurrence of
    /// a series: the existing e-mail reply only.
    case emailOnly

    /// What Google is asked to e-mail when the answer is written.
    static let sendUpdates = CalendarSendUpdates.none

    static func route(for facts: CalendarInviteFacts,
                      event: CalendarInviteEventRecord?,
                      canWrite: Bool) -> CalendarRSVPRoute {
        guard canWrite, !facts.isSingleOccurrence, let event,
              event.iCalUID == facts.uid else { return .emailOnly }
        return facts.organizerUsesGoogleCalendar
            ? .calendarOnly(calendarId: event.calendarId, eventId: event.eventId)
            : .calendarAndEmail(calendarId: event.calendarId, eventId: event.eventId)
    }

    var sendsEmail: Bool {
        if case .calendarOnly = self { return false }
        return true
    }
}

enum CalendarInvitePlan {
    /// "Add to calendar" is offered for an invitation that is not in the
    /// user's Google Calendar, has a real time and is not one occurrence of
    /// a series (which needs the series first).
    static func canAddToCalendar(_ facts: CalendarInviteFacts, event: CalendarInviteEventRecord?,
                                 canWrite: Bool) -> Bool {
        canWrite && event == nil && facts.span != nil && !facts.isSingleOccurrence && !facts.uid.isEmpty
    }

    /// The `events.import` body: the invitation's UID, title, place, time
    /// and organizer. All-day dates are local days in `zone`, end exclusive.
    static func importBody(_ facts: CalendarInviteFacts, zone: TimeZone) -> [String: Any]? {
        guard let span = facts.span, !facts.uid.isEmpty else { return nil }
        var body: [String: Any] = ["iCalUID": facts.uid]
        if !facts.summary.isEmpty { body["summary"] = facts.summary }
        if !facts.location.isEmpty { body["location"] = facts.location }
        if !facts.organizerEmail.isEmpty { body["organizer"] = ["email": facts.organizerEmail] }
        if span.isAllDay {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let endDay = span.end > span.start
                ? span.end : calendar.date(byAdding: .day, value: 1, to: span.start) ?? span.start
            body["start"] = ["date": day(span.start, calendar)]
            body["end"] = ["date": day(endDay, calendar)]
        } else {
            body["start"] = ["dateTime": CalendarClient.rfc3339(span.start)]
            body["end"] = ["dateTime": CalendarClient.rfc3339(span.end)]
        }
        return body
    }

    private static func day(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// The step 4A flows for one account, over the client: availability next to
/// an invitation, finding the invitation's event, answering on the
/// calendar, adding to the calendar. Results stay in memory except the
/// invitation's event location (`CalendarStore.saveInviteEvent`), which the
/// caller stores.
struct CalendarInviteService: Sendable {
    let client: CalendarClient
    let grant: CalendarGrant

    /// Conflicts on the chosen calendars. Calendars whose events can be read
    /// are read (so the invitation's own event is recognised by UID);
    /// free/busy-only ones give busy periods. A calendar that fails makes
    /// the result incomplete rather than failing it.
    func availability(for facts: CalendarInviteFacts, chosen: [CalendarSourceRecord],
                      zone: TimeZone = .current) async throws -> CalendarAvailabilityResult? {
        guard let span = facts.span, !chosen.isEmpty else { return nil }
        let window = CalendarAvailability.queryWindow(for: span, in: zone)
        var busy: [CalendarBusy] = []
        var incomplete = false
        var freeBusyOnly: [String] = []
        for calendar in chosen {
            guard calendar.canReadEvents, grant.canReadEvents else {
                freeBusyOnly.append(calendar.calendarId)
                continue
            }
            do {
                let result = try await client.events(calendarId: calendar.calendarId, in: window)
                busy += CalendarAvailability.busy(
                    events: result.events, calendarId: calendar.calendarId,
                    calendarTimeZone: result.calendarTimeZone ?? calendar.timeZone,
                    excludingUID: facts.uid, fallback: zone)
            } catch let error as CalendarError where Self.isPerCalendar(error) {
                incomplete = true
            }
        }
        if !freeBusyOnly.isEmpty {
            if grant.canReadAvailability {
                let periods = try await client.freeBusy(calendarIds: freeBusyOnly, in: window)
                incomplete = incomplete || periods.contains { $0.failed }
                busy += CalendarAvailability.busy(freeBusy: periods)
            } else {
                incomplete = true
            }
        }
        return CalendarAvailability.check(invite: span, against: busy, incomplete: incomplete)
    }

    /// The invitation's event in the user's calendars: the primary first,
    /// then the other chosen ones. Nil when Google has not put it on any.
    func locate(_ facts: CalendarInviteFacts, chosen: [CalendarSourceRecord],
                messageId: String, accountId: String,
                now: Date = Date()) async throws -> CalendarInviteEventRecord? {
        guard !facts.uid.isEmpty else { return nil }
        var ids = ["primary"]
        ids += chosen.filter { !$0.isPrimary && $0.canReadEvents && $0.calendarId != "primary" }
            .map(\.calendarId)
        for id in ids {
            let found: [GCalendarEvent]
            do {
                found = try await client.events(calendarId: id, iCalUID: facts.uid)
            } catch let error as CalendarError where Self.isPerCalendar(error) {
                continue
            }
            // A series comes back as its master event; a single event as itself.
            if let event = found.first(where: { $0.recurringEventId == nil }) ?? found.first {
                return CalendarInviteEventRecord(
                    messageId: messageId, accountId: accountId, calendarId: id, eventId: event.id,
                    iCalUID: facts.uid, selfResponse: event.selfResponse, checkedAt: now)
            }
        }
        return nil
    }

    /// Writes the answer on the calendar when the route says so. Returns the
    /// route, so the caller sends the iTIP e-mail when `sendsEmail`.
    func respond(_ response: CalendarResponse, facts: CalendarInviteFacts,
                 event: CalendarInviteEventRecord?) async throws -> CalendarRSVPRoute {
        let route = CalendarRSVPRoute.route(for: facts, event: event, canWrite: grant.canWriteEvents)
        switch route {
        case .calendarOnly(let calendarId, let eventId), .calendarAndEmail(let calendarId, let eventId):
            try await client.respond(calendarId: calendarId, eventId: eventId, response: response,
                                     sendUpdates: CalendarRSVPRoute.sendUpdates)
        case .emailOnly:
            break
        }
        return route
    }

    /// "Add to calendar" on the primary calendar.
    func addToCalendar(_ facts: CalendarInviteFacts, messageId: String, accountId: String,
                       zone: TimeZone = .current, now: Date = Date()) async throws -> CalendarInviteEventRecord {
        let event = try await client.importEvent(calendarId: "primary", facts: facts, zone: zone)
        return CalendarInviteEventRecord(messageId: messageId, accountId: accountId,
                                         calendarId: "primary", eventId: event.id, iCalUID: facts.uid,
                                         selfResponse: event.selfResponse, checkedAt: now)
    }

    /// Errors that concern one calendar (gone, no access to its events), not
    /// the account: the other calendars are still checked.
    static func isPerCalendar(_ error: CalendarError) -> Bool {
        if case .http(let code, _) = error { return code == 404 || code == 403 }
        return false
    }
}
