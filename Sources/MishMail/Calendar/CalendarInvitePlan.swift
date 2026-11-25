import Foundation

/// What the Calendar integration needs from one invitation, read from the
/// parsed ICS (`CalendarInvite`). Everything here is written by the sender.
struct CalendarInviteFacts: Equatable, Sendable {
    var uid: String
    var summary: String
    var location: String
    var organizerEmail: String
    var span: CalendarSpan?
    /// A reply to one occurrence of a series (`RECURRENCE-ID`).
    var isSingleOccurrence: Bool
    /// The invitation repeats (`RRULE` or `RDATE`).
    var isRecurring: Bool
    /// The parser offers an answer at all (`CalendarInvite.isActionable`:
    /// a request, not cancelled, a valid organizer, a safe reply).
    var isAnswerable: Bool

    init(uid: String, summary: String = "", location: String = "", organizerEmail: String = "",
         span: CalendarSpan?, isSingleOccurrence: Bool = false, isRecurring: Bool = false,
         isAnswerable: Bool = true) {
        self.uid = uid
        self.summary = summary
        self.location = location
        self.organizerEmail = organizerEmail
        self.span = span
        self.isSingleOccurrence = isSingleOccurrence
        self.isRecurring = isRecurring
        self.isAnswerable = isAnswerable
    }

    init(_ invite: CalendarInvite) {
        var span: CalendarSpan?
        // A time read in the local zone because its TZID could not be
        // resolved is not the real instant: no availability, no import, no
        // match with Google's event.
        if invite.unresolvedTZID == nil, let start = invite.start {
            let end = invite.end ?? start
            if end >= start { span = CalendarSpan(start: start, end: end, isAllDay: invite.isAllDay) }
        }
        self.init(uid: invite.uid, summary: invite.summary, location: invite.location,
                  organizerEmail: invite.organizerEmail, span: span,
                  isSingleOccurrence: invite.recurrenceIdLine != nil,
                  isRecurring: invite.isRecurring, isAnswerable: invite.isActionable)
    }

    var identity: CalendarInviteIdentity? {
        span.map { CalendarInviteIdentity(uid: uid, span: $0) }
    }
}

/// Where the answer to an invitation goes. The iTIP e-mail is always sent
/// (#51's path): every field that could tell "the organizer already sees it
/// in Google Calendar" (PRODID, the UID, the organizer Google copies from the
/// ICS) is written by the sender, so none of them may drop the e-mail. The
/// answer is also written on the user's calendar, with Google asked to
/// notify nobody, when Google holds the very event the invitation describes.
enum CalendarRSVPRoute: Equatable, Sendable {
    /// The invitation offers no answer (`CalendarInvite.isActionable`).
    case notAnswerable
    /// Write the answer on this event, then send the e-mail.
    case calendarAndEmail(calendarId: String, eventId: String)
    /// The e-mail only: Calendar not connected or read-only, the event is not
    /// in Google Calendar or is not the one the invitation describes, or one
    /// occurrence of a series.
    case emailOnly

    /// Google's event is the invitation's when UID, organizer and time all
    /// agree. A UID is enough for a sender to point at a real event on the
    /// user's calendar; organizer and time must match too, or the answer to
    /// a forged invitation would change a real event.
    static func matches(_ facts: CalendarInviteFacts, _ event: CalendarInviteEventRecord) -> Bool {
        guard !facts.uid.isEmpty, event.iCalUID == facts.uid,
              let organizer = event.organizerEmail, !organizer.isEmpty,
              organizer.caseInsensitiveCompare(facts.organizerEmail) == .orderedSame,
              let mine = facts.span, let theirs = event.span else { return false }
        return mine.sameTime(as: theirs)
    }

    static func route(for facts: CalendarInviteFacts,
                      event: CalendarInviteEventRecord?,
                      canWrite: Bool) -> CalendarRSVPRoute {
        guard facts.isAnswerable else { return .notAnswerable }
        guard canWrite, !facts.isSingleOccurrence, let event, matches(facts, event) else {
            return .emailOnly
        }
        return .calendarAndEmail(calendarId: event.calendarId, eventId: event.eventId)
    }

    var sendsEmail: Bool { self != .notAnswerable }
}

/// What writing the answer on the calendar did. Never an error: a failed
/// calendar write must not hold back the e-mail.
struct CalendarRSVPOutcome: Equatable, Sendable {
    var route: CalendarRSVPRoute
    /// The answer is now on the calendar.
    var calendarWritten: Bool
    /// Google no longer has the event (404/410): forget where it was.
    var eventGone: Bool
    /// Why the calendar write failed, for the notice; nil on success or
    /// when nothing was to be written.
    var calendarError: CalendarError?
}

enum CalendarInvitePlan {
    /// "Add to calendar" is offered for an answerable invitation that is not
    /// in the user's Google Calendar and has a real time. Not for a series
    /// (importing it without its rule would create a single event under the
    /// series' UID) nor for one occurrence of a series.
    static func canAddToCalendar(_ facts: CalendarInviteFacts, event: CalendarInviteEventRecord?,
                                 canWrite: Bool) -> Bool {
        canWrite && facts.isAnswerable && event == nil && facts.span != nil
            && !facts.isSingleOccurrence && !facts.isRecurring && !facts.uid.isEmpty
            && facts.uid.utf8.count <= CalendarClient.maxUIDBytes
    }

    /// The `events.import` body: the invitation's UID, title, place, time,
    /// organizer, and the user as a guest who has not answered yet, so the
    /// answer can be written on the imported event. All-day dates are local
    /// days in `zone`, end exclusive.
    static func importBody(_ facts: CalendarInviteFacts, attendeeEmail: String,
                           zone: TimeZone) -> [String: Any]? {
        guard let span = facts.span, !facts.uid.isEmpty, !attendeeEmail.isEmpty else { return nil }
        var body: [String: Any] = ["iCalUID": facts.uid]
        if !facts.summary.isEmpty { body["summary"] = facts.summary }
        if !facts.location.isEmpty { body["location"] = facts.location }
        if !facts.organizerEmail.isEmpty { body["organizer"] = ["email": facts.organizerEmail] }
        body["attendees"] = [["email": attendeeEmail, "responseStatus": "needsAction"]]
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
/// an invitation, finding the invitation's event, answering on the calendar,
/// adding to the calendar. Results stay in memory except where the
/// invitation's event is (`CalendarStore.saveInviteEvent`), which the
/// caller stores.
struct CalendarInviteService: Sendable {
    let client: CalendarClient
    let grant: CalendarGrant

    /// Conflicts on the chosen calendars. Calendars whose events can be read
    /// are read, so the invitation's own event is recognised by UID and
    /// time; free/busy-only ones give busy periods, which cannot tell the
    /// invitation from another event, so the result is then marked
    /// incomplete. A calendar that fails makes the result incomplete rather
    /// than failing it.
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
                    excluding: facts.identity, fallback: zone)
            } catch let error as CalendarError where Self.isPerCalendar(error) {
                incomplete = true
            }
        }
        if !freeBusyOnly.isEmpty {
            incomplete = true
            if grant.canReadAvailability {
                let periods = try await client.freeBusy(calendarIds: freeBusyOnly, in: window)
                busy += CalendarAvailability.busy(freeBusy: periods, invite: span)
            }
        }
        return CalendarAvailability.check(invite: span, against: busy, incomplete: incomplete)
    }

    /// The invitation's event in the user's calendars: the primary first,
    /// then the other chosen ones. Nil when Google has not put it on any.
    /// The record keeps Google's organizer and time, which decide whether
    /// the answer may be written there (`CalendarRSVPRoute.matches`).
    func locate(_ facts: CalendarInviteFacts, chosen: [CalendarSourceRecord],
                messageId: String, accountId: String,
                zone: TimeZone = .current, now: Date = Date()) async throws -> CalendarInviteEventRecord? {
        guard !facts.uid.isEmpty, facts.uid.utf8.count <= CalendarClient.maxUIDBytes else { return nil }
        var calendars = [("primary", String?.none)]
        calendars += chosen.filter { !$0.isPrimary && $0.canReadEvents && $0.calendarId != "primary" }
            .map { ($0.calendarId, $0.timeZone) }
        for (id, timeZone) in calendars {
            let found: [GCalendarEvent]
            do {
                found = try await client.events(calendarId: id, iCalUID: facts.uid)
            } catch let error as CalendarError where Self.isPerCalendar(error) {
                continue
            }
            // A series comes back as its master event; a single event as itself.
            if let event = found.first(where: { $0.recurringEventId == nil }) ?? found.first {
                return CalendarInviteEventRecord(
                    messageId: messageId, accountId: accountId, calendarId: id, event: event,
                    iCalUID: facts.uid, calendarTimeZone: event.start?.timeZone ?? timeZone,
                    fallback: zone, checkedAt: now)
            }
        }
        return nil
    }

    /// Writes the answer on the calendar when the route says so. Never
    /// throws: whatever happens here, the caller sends the e-mail when
    /// `route.sendsEmail`.
    func respond(_ response: CalendarResponse, facts: CalendarInviteFacts,
                 event: CalendarInviteEventRecord?) async -> CalendarRSVPOutcome {
        let route = CalendarRSVPRoute.route(for: facts, event: event, canWrite: grant.canWriteEvents)
        guard case .calendarAndEmail(let calendarId, let eventId) = route else {
            return CalendarRSVPOutcome(route: route, calendarWritten: false, eventGone: false,
                                       calendarError: nil)
        }
        do {
            try await client.respond(calendarId: calendarId, eventId: eventId, response: response)
            return CalendarRSVPOutcome(route: route, calendarWritten: true, eventGone: false,
                                       calendarError: nil)
        } catch let error as CalendarError {
            var gone = false
            if case .http(let code, _) = error { gone = code == 404 || code == 410 }
            return CalendarRSVPOutcome(route: route, calendarWritten: false, eventGone: gone,
                                       calendarError: error)
        } catch {
            return CalendarRSVPOutcome(route: route, calendarWritten: false, eventGone: false,
                                       calendarError: .badResponse)
        }
    }

    /// "Add to calendar" on the primary calendar, with the user (the
    /// address the answer goes from) as a guest.
    func addToCalendar(_ facts: CalendarInviteFacts, attendeeEmail: String, messageId: String,
                       accountId: String, zone: TimeZone = .current,
                       now: Date = Date()) async throws -> CalendarInviteEventRecord {
        let event = try await client.importEvent(calendarId: "primary", facts: facts,
                                                 attendeeEmail: attendeeEmail, zone: zone)
        return CalendarInviteEventRecord(messageId: messageId, accountId: accountId,
                                         calendarId: "primary", event: event, iCalUID: facts.uid,
                                         calendarTimeZone: event.start?.timeZone, fallback: zone,
                                         checkedAt: now)
    }

    /// Errors that concern one calendar (gone, no access to its events), not
    /// the account: the other calendars are still checked.
    static func isPerCalendar(_ error: CalendarError) -> Bool {
        if case .http(let code, _) = error { return code == 404 || code == 403 }
        return false
    }
}
