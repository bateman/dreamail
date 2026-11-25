import XCTest

/// Option B of step 4A: availability next to an invitation, finding its
/// event, where the answer goes, and "add to calendar".
final class CalendarInvitePlanTests: XCTestCase {

    private func at(_ s: String) -> Date { CalendarClient.parseDateTime(s)! }

    private func facts(google: Bool = true, single: Bool = false,
                       allDay: Bool = false) -> CalendarInviteFacts {
        CalendarInviteFacts(
            uid: "uid-1@google.com", summary: "Review", location: "Room 2", organizerEmail: "org@y.com",
            span: allDay
                ? CalendarSpan(start: at("2026-01-04T23:00:00Z"), end: at("2026-01-05T23:00:00Z"), isAllDay: true)
                : CalendarSpan(start: at("2026-01-05T10:00:00Z"), end: at("2026-01-05T11:00:00Z"), isAllDay: false),
            isSingleOccurrence: single, organizerUsesGoogleCalendar: google)
    }

    private func located(_ calendarId: String = "primary") -> CalendarInviteEventRecord {
        CalendarInviteEventRecord(messageId: "a@x.com:m1", accountId: "a@x.com", calendarId: calendarId,
                                  eventId: "ev1", iCalUID: "uid-1@google.com", selfResponse: "needsAction",
                                  checkedAt: Date())
    }

    private func source(_ id: String, primary: Bool = false, role: String = "owner") -> CalendarSourceRecord {
        CalendarSourceRecord(accountId: "a@x.com", entry: GCalendarListEntry(
            id: id, summary: nil, timeZone: "UTC", primary: primary, accessRole: role, selected: true))
    }

    private func service(_ net: CalendarStubTransport,
                         scopes: [String] = CalendarScope.recommended) -> CalendarInviteService {
        let grant = CalendarGrant(scopes: Set(scopes))
        let tokens = CalendarTokenSource(accountId: "a@x.com", enabled: true,
                                         readRefreshToken: CalendarStubKeychain().reader,
                                         refresh: { _ in ("t", 3600) })
        return CalendarInviteService(client: CalendarClient(grant: grant, tokens: tokens,
                                                            transport: net.transport),
                                     grant: grant)
    }

    private func path(_ r: URLRequest) -> String { r.url?.path ?? "" }

    // MARK: - Facts from the ICS

    func testGoogleCalendarIsRecognisedByTheCalendarsOwnProdID() {
        XCTAssertTrue(CalendarInviteFacts.isGoogleCalendarICS(
            "BEGIN:VCALENDAR\r\nPRODID:-//Google Inc//Google Calendar 70.9054//EN\r\nVERSION:2.0\r\n"))
        XCTAssertFalse(CalendarInviteFacts.isGoogleCalendarICS(
            "BEGIN:VCALENDAR\r\nPRODID:Microsoft Exchange Server 2010\r\nVERSION:2.0\r\n"))
        XCTAssertFalse(CalendarInviteFacts.isGoogleCalendarICS(
            "BEGIN:VCALENDAR\r\nPRODID:-//Apple Inc.//macOS 15//EN\r\nDESCRIPTION:PRODID:-//Google Inc//Google Calendar\r\n"),
            "only the first PRODID line counts")
        XCTAssertFalse(CalendarInviteFacts.isGoogleCalendarICS("BEGIN:VCALENDAR\r\n"))
    }

    // MARK: - Where the answer goes (owner's decision)

    func testAnswerRoute() {
        let google = facts(google: true)
        XCTAssertEqual(CalendarRSVPRoute.route(for: google, event: located(), canWrite: true),
                       .calendarOnly(calendarId: "primary", eventId: "ev1"))
        XCTAssertEqual(CalendarRSVPRoute.route(for: facts(google: false), event: located(), canWrite: true),
                       .calendarAndEmail(calendarId: "primary", eventId: "ev1"),
                       "an outside organizer gets the e-mail: Google is not known to tell them")
        XCTAssertEqual(CalendarRSVPRoute.route(for: google, event: nil, canWrite: true), .emailOnly)
        XCTAssertEqual(CalendarRSVPRoute.route(for: google, event: located(), canWrite: false), .emailOnly)
        XCTAssertEqual(CalendarRSVPRoute.route(for: facts(single: true), event: located(), canWrite: true),
                       .emailOnly, "one occurrence of a series keeps the e-mail reply")
        var other = located()
        other.iCalUID = "another"
        XCTAssertEqual(CalendarRSVPRoute.route(for: google, event: other, canWrite: true), .emailOnly)
        XCTAssertEqual(CalendarRSVPRoute.sendUpdates, .none, "never a second answer from Google")
        XCTAssertFalse(CalendarRSVPRoute.calendarOnly(calendarId: "p", eventId: "e").sendsEmail)
        XCTAssertTrue(CalendarRSVPRoute.calendarAndEmail(calendarId: "p", eventId: "e").sendsEmail)
        XCTAssertTrue(CalendarRSVPRoute.emailOnly.sendsEmail)
    }

    func testRespondWritesTheAnswerWithNoGoogleNotification() async throws {
        let net = CalendarStubTransport()
        net.respond = { request, _ in
            request.httpMethod == "GET"
                ? (200, #"{"attendees":[{"email":"a@x.com","self":true,"responseStatus":"needsAction"}]}"#, [:])
                : (200, "{}", [:])
        }
        let route = try await service(net).respond(.declined, facts: facts(google: false), event: located("work@x.com"))
        XCTAssertEqual(route, .calendarAndEmail(calendarId: "work@x.com", eventId: "ev1"))
        XCTAssertEqual(net.requests.map(\.httpMethod), ["GET", "PATCH"])
        XCTAssertEqual(path(net.requests[1]), "/calendar/v3/calendars/work@x.com/events/ev1",
                       "the answer goes on the calendar the event is in")
        XCTAssertEqual(net.requests[1].url?.query, "sendUpdates=none")
    }

    func testEmailOnlyRouteSendsNothingToCalendar() async throws {
        let net = CalendarStubTransport()
        let route = try await service(net).respond(.accepted, facts: facts(), event: nil)
        XCTAssertEqual(route, .emailOnly)
        XCTAssertEqual(net.requests.count, 0)
    }

    // MARK: - Finding the invitation's event

    func testLocateLooksInPrimaryThenTheOtherChosenCalendars() async throws {
        let net = CalendarStubTransport()
        net.respond = { request, _ in
            request.url?.path.contains("/calendars/team@group/") == true
                ? (200, #"{"items":[{"id":"inst_1","recurringEventId":"series"},{"id":"series","attendees":[{"email":"a@x.com","self":true,"responseStatus":"tentative"}]}]}"#, [:])
                : (200, #"{"items":[{"id":"old","status":"cancelled"}]}"#, [:])
        }
        let record = try await service(net).locate(
            facts(), chosen: [source("a@x.com", primary: true), source("team@group"),
                              source("boss@y.com", role: "freeBusyReader")],
            messageId: "a@x.com:m1", accountId: "a@x.com")
        XCTAssertEqual(net.requests.map(path), ["/calendar/v3/calendars/primary/events",
                                                "/calendar/v3/calendars/team@group/events"])
        XCTAssertEqual(URLComponents(url: net.requests[0].url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "iCalUID" }?.value, "uid-1@google.com")
        XCTAssertEqual(record?.calendarId, "team@group")
        XCTAssertEqual(record?.eventId, "series", "a series is answered on its master event")
        XCTAssertEqual(record?.selfResponse, "tentative")
    }

    func testLocateSkipsACalendarItCannotReadAndReturnsNilWhenAbsent() async throws {
        let net = CalendarStubTransport()
        net.respond = { request, _ in
            request.url?.path.contains("/primary/") == true
                ? (404, #"{"error":{"errors":[{"reason":"notFound"}]}}"#, [:])
                : (200, #"{"items":[]}"#, [:])
        }
        let record = try await service(net).locate(facts(), chosen: [source("team@group")],
                                                   messageId: "m", accountId: "a@x.com")
        XCTAssertNil(record)
        XCTAssertEqual(net.requests.count, 2)
    }

    // MARK: - Availability

    func testAvailabilityReadsChosenCalendarsAndUsesFreeBusyForTheOthers() async throws {
        let net = CalendarStubTransport()
        net.respond = { request, _ in
            if request.url?.path == "/calendar/v3/freeBusy" {
                return (200, #"{"calendars":{"boss@y.com":{"busy":[{"start":"2026-01-05T10:30:00Z","end":"2026-01-05T12:00:00Z"}]}}}"#, [:])
            }
            return (200, #"{"timeZone":"UTC","items":[{"id":"own","iCalUID":"uid-1@google.com","start":{"dateTime":"2026-01-05T10:00:00Z"},"end":{"dateTime":"2026-01-05T11:00:00Z"}},{"id":"clash","summary":"1:1","start":{"dateTime":"2026-01-05T09:30:00Z"},"end":{"dateTime":"2026-01-05T10:15:00Z"}}]}"#, [:])
        }
        let result = try await service(net).availability(
            for: facts(), chosen: [source("a@x.com", primary: true), source("boss@y.com", role: "freeBusyReader")],
            zone: TimeZone(identifier: "UTC")!)
        let found = try XCTUnwrap(result)
        XCTAssertEqual(found.conflicts.map(\.source), [
            .event(calendarId: "a@x.com", eventId: "clash", summary: "1:1"),
            .freeBusy(calendarId: "boss@y.com"),
        ], "the invitation's own event is not a conflict")
        XCTAssertFalse(found.isIncomplete)
        let list = try XCTUnwrap(net.requests.first)
        let q = URLComponents(url: list.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(q.first { $0.name == "timeMin" }?.value, "2026-01-05T00:00:00Z")
        XCTAssertEqual(q.first { $0.name == "timeMax" }?.value, "2026-01-06T00:00:00Z")
    }

    func testAvailabilityWithAFailingCalendarIsIncompleteNotAnError() async throws {
        let net = CalendarStubTransport()
        net.respond = { _, _ in (403, #"{"error":{"errors":[{"reason":"forbidden"}]}}"#, [:]) }
        let result = try await service(net).availability(for: facts(), chosen: [source("team@group")])
        XCTAssertEqual(result?.isIncomplete, true)
        XCTAssertEqual(result?.isFree, true)
    }

    func testNoAvailabilityWithoutATimeOrACalendar() async throws {
        let net = CalendarStubTransport()
        var noTime = facts()
        noTime.span = nil
        let s = service(net)
        let a = try await s.availability(for: noTime, chosen: [source("p", primary: true)])
        let b = try await s.availability(for: facts(), chosen: [])
        XCTAssertNil(a)
        XCTAssertNil(b)
        XCTAssertEqual(net.requests.count, 0)
    }

    // MARK: - Add to calendar

    func testImportBodyKeepsTheUIDAndTimes() throws {
        let rome = TimeZone(identifier: "Europe/Rome")!
        let timed = try XCTUnwrap(CalendarInvitePlan.importBody(facts(), zone: rome))
        XCTAssertEqual(timed["iCalUID"] as? String, "uid-1@google.com")
        XCTAssertEqual(timed["summary"] as? String, "Review")
        XCTAssertEqual(timed["location"] as? String, "Room 2")
        XCTAssertEqual((timed["organizer"] as? [String: String])?["email"], "org@y.com")
        XCTAssertEqual((timed["start"] as? [String: String])?["dateTime"], "2026-01-05T10:00:00Z")
        XCTAssertEqual((timed["end"] as? [String: String])?["dateTime"], "2026-01-05T11:00:00Z")

        let allDay = try XCTUnwrap(CalendarInvitePlan.importBody(facts(allDay: true), zone: rome))
        XCTAssertEqual((allDay["start"] as? [String: String])?["date"], "2026-01-05")
        XCTAssertEqual((allDay["end"] as? [String: String])?["date"], "2026-01-06")

        var noTime = facts()
        noTime.span = nil
        XCTAssertNil(CalendarInvitePlan.importBody(noTime, zone: rome))
    }

    func testAddToCalendarIsOfferedOnlyWhenItMakesSense() {
        XCTAssertTrue(CalendarInvitePlan.canAddToCalendar(facts(), event: nil, canWrite: true))
        XCTAssertFalse(CalendarInvitePlan.canAddToCalendar(facts(), event: located(), canWrite: true))
        XCTAssertFalse(CalendarInvitePlan.canAddToCalendar(facts(), event: nil, canWrite: false))
        XCTAssertFalse(CalendarInvitePlan.canAddToCalendar(facts(single: true), event: nil, canWrite: true))
        var noTime = facts()
        noTime.span = nil
        XCTAssertFalse(CalendarInvitePlan.canAddToCalendar(noTime, event: nil, canWrite: true))
    }

    func testAddToCalendarImportsIntoThePrimaryCalendar() async throws {
        let net = CalendarStubTransport()
        net.respond = { _, _ in (200, #"{"id":"new1","iCalUID":"uid-1@google.com"}"#, [:]) }
        let record = try await service(net).addToCalendar(facts(), messageId: "a@x.com:m1", accountId: "a@x.com")
        XCTAssertEqual(net.requests.first?.httpMethod, "POST")
        XCTAssertEqual(net.requests.first.map(path), "/calendar/v3/calendars/primary/events/import")
        XCTAssertEqual(record.eventId, "new1")
        XCTAssertEqual(record.calendarId, "primary")
    }

    func testAddToCalendarNeedsTheWriteScope() async {
        let net = CalendarStubTransport()
        do {
            _ = try await service(net, scopes: [CalendarScope.eventsFreeBusy])
                .addToCalendar(facts(), messageId: "m", accountId: "a@x.com")
            XCTFail("needs calendar.events")
        } catch {
            XCTAssertEqual(error as? CalendarError, .notGranted(.writeEvents))
        }
        XCTAssertEqual(net.requests.count, 0)
    }
}
