import XCTest

/// Option B of step 4A: availability next to an invitation, finding its
/// event, where the answer goes, and "add to calendar". The review's
/// security findings (S1–S3) are covered by name.
final class CalendarInvitePlanTests: XCTestCase {

    private func at(_ s: String) -> Date { CalendarClient.parseDateTime(s)! }

    private let meeting = CalendarSpan(start: Date(timeIntervalSince1970: 1_767_607_200), // 2026-01-05T10:00Z
                                       end: Date(timeIntervalSince1970: 1_767_610_800), isAllDay: false)

    private func facts(single: Bool = false, recurring: Bool = false, allDay: Bool = false,
                       organizer: String = "org@y.com") -> CalendarInviteFacts {
        CalendarInviteFacts(
            uid: "uid-1@google.com", summary: "Review", location: "Room 2", organizerEmail: organizer,
            span: allDay
                ? CalendarSpan(start: at("2026-01-04T23:00:00Z"), end: at("2026-01-05T23:00:00Z"), isAllDay: true)
                : meeting,
            isSingleOccurrence: single, isRecurring: recurring)
    }

    /// As `locate` records Google's event: its organizer and its time.
    private func located(_ calendarId: String = "primary", organizer: String? = "Org@y.com",
                         span: CalendarSpan? = nil, uid: String = "uid-1@google.com") -> CalendarInviteEventRecord {
        CalendarInviteEventRecord(messageId: "a@x.com:m1", accountId: "a@x.com", calendarId: calendarId,
                                  eventId: "ev1", iCalUID: uid, organizerEmail: organizer,
                                  span: span ?? meeting, checkedAt: Date())
    }

    private func source(_ id: String, primary: Bool = false, role: String = "owner") -> CalendarSourceRecord {
        CalendarSourceRecord(accountId: "a@x.com", entry: GCalendarListEntry(
            id: id, summary: nil, timeZone: "UTC", primary: primary, accessRole: role))
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

    private static let selfAttendee =
        #"{"attendees":[{"email":"a@x.com","self":true,"responseStatus":"needsAction"}]}"#

    // MARK: - Where the answer goes

    /// R1/S2: the e-mail always goes; the calendar is written too only when
    /// Google's event is the invitation's.
    func testTheEmailAlwaysGoesAndTheCalendarOnlyForTheSameEvent() {
        XCTAssertEqual(CalendarRSVPRoute.route(for: facts(), event: located(), canWrite: true),
                       .calendarAndEmail(calendarId: "primary", eventId: "ev1"))
        XCTAssertEqual(CalendarRSVPRoute.route(for: facts(), event: nil, canWrite: true), .emailOnly)
        XCTAssertEqual(CalendarRSVPRoute.route(for: facts(), event: located(), canWrite: false), .emailOnly)
        XCTAssertEqual(CalendarRSVPRoute.route(for: facts(single: true), event: located(), canWrite: true),
                       .emailOnly, "one occurrence of a series keeps the e-mail reply only")
        var cancelled = facts()
        cancelled.isAnswerable = false
        XCTAssertEqual(CalendarRSVPRoute.route(for: cancelled, event: located(), canWrite: true),
                       .notAnswerable, "what #51 refuses to answer stays unanswered")
        XCTAssertTrue(CalendarRSVPRoute.calendarAndEmail(calendarId: "p", eventId: "e").sendsEmail)
        XCTAssertTrue(CalendarRSVPRoute.emailOnly.sendsEmail)
        XCTAssertFalse(CalendarRSVPRoute.notAnswerable.sendsEmail)
    }

    /// S1 variant A: a forged REQUEST reuses the UID of a real event on the
    /// user's calendar, with another time (or another organizer). Answering
    /// it must not touch the real event.
    func testAForgedInviteWithARealUIDDoesNotWriteOnTheRealEvent() {
        let real = located(span: CalendarSpan(start: at("2026-01-07T15:00:00Z"),
                                              end: at("2026-01-07T16:00:00Z"), isAllDay: false))
        XCTAssertEqual(CalendarRSVPRoute.route(for: facts(), event: real, canWrite: true), .emailOnly,
                       "another time: e-mail only (to the forged organizer, as #51 shows on the card)")
        XCTAssertEqual(CalendarRSVPRoute.route(for: facts(organizer: "attacker@evil.example"),
                                               event: located(), canWrite: true), .emailOnly,
                       "another organizer: e-mail only")
        XCTAssertEqual(CalendarRSVPRoute.route(for: facts(), event: located(organizer: nil), canWrite: true),
                       .emailOnly, "Google gave no organizer: no match")
        XCTAssertEqual(CalendarRSVPRoute.route(for: facts(), event: located(span: nil), canWrite: true),
                       .emailOnly)
        XCTAssertEqual(CalendarRSVPRoute.route(for: facts(), event: located(uid: "other"), canWrite: true),
                       .emailOnly)
        var noTime = facts()
        noTime.span = nil
        XCTAssertEqual(CalendarRSVPRoute.route(for: noTime, event: located(), canWrite: true), .emailOnly)
    }

    /// S1 variant B: the forged invite is answered through the service; the
    /// real event receives no PATCH at all.
    func testAForgedInviteSendsNothingToCalendar() async {
        let net = CalendarStubTransport()
        let real = located(span: CalendarSpan(start: at("2026-01-07T15:00:00Z"),
                                              end: at("2026-01-07T16:00:00Z"), isAllDay: false))
        let outcome = await service(net).respond(.declined, facts: facts(), event: real)
        XCTAssertEqual(outcome.route, .emailOnly)
        XCTAssertFalse(outcome.calendarWritten)
        XCTAssertEqual(net.requests.count, 0)
    }

    func testMatchingIgnoresCaseAndSubSecondDifferences() {
        let close = CalendarSpan(start: meeting.start.addingTimeInterval(0.4),
                                 end: meeting.end.addingTimeInterval(-0.4), isAllDay: false)
        XCTAssertTrue(CalendarRSVPRoute.matches(facts(organizer: "ORG@Y.COM"), located(span: close)))
        let off = CalendarSpan(start: meeting.start.addingTimeInterval(60), end: meeting.end, isAllDay: false)
        XCTAssertFalse(CalendarRSVPRoute.matches(facts(), located(span: off)))
    }

    func testRespondWritesTheAnswerWithNoGoogleNotification() async {
        let net = CalendarStubTransport()
        net.respond = { request, _ in
            request.httpMethod == "GET" ? (200, Self.selfAttendee, [:]) : (200, "{}", [:])
        }
        let outcome = await service(net).respond(.declined, facts: facts(), event: located("work@x.com"))
        XCTAssertEqual(outcome, CalendarRSVPOutcome(
            route: .calendarAndEmail(calendarId: "work@x.com", eventId: "ev1"),
            calendarWritten: true, eventGone: false, calendarError: nil))
        XCTAssertEqual(net.requests.map(\.httpMethod), ["GET", "PATCH"])
        XCTAssertEqual(path(net.requests[1]), "/calendar/v3/calendars/work@x.com/events/ev1",
                       "the answer goes on the calendar the event is in")
        XCTAssertEqual(net.requests[1].url?.query, "sendUpdates=none")
    }

    /// R3: a failed calendar write never holds back the e-mail.
    func testAFailedCalendarWriteStillLeavesTheEmailToSend() async {
        for (status, body, gone) in [(404, "{}", true), (500, "{}", false), (403, "{}", false)] {
            let net = CalendarStubTransport()
            net.respond = { request, _ in
                request.httpMethod == "GET" ? (200, Self.selfAttendee, [:]) : (status, body, [:])
            }
            let outcome = await service(net).respond(.accepted, facts: facts(), event: located())
            XCTAssertTrue(outcome.route.sendsEmail, "\(status)")
            XCTAssertFalse(outcome.calendarWritten, "\(status)")
            XCTAssertEqual(outcome.eventGone, gone, "\(status): forget the event only when it is gone")
            XCTAssertNotNil(outcome.calendarError)
        }
    }

    func testNotAGuestMeansEmailOnly() async {
        let net = CalendarStubTransport()
        net.respond = { _, _ in (200, #"{"attendees":[{"email":"org@y.com"}]}"#, [:]) }
        let outcome = await service(net).respond(.accepted, facts: facts(), event: located())
        XCTAssertTrue(outcome.route.sendsEmail)
        XCTAssertFalse(outcome.calendarWritten)
        XCTAssertEqual(outcome.calendarError, .notAnAttendee)
        XCTAssertEqual(net.requests.map(\.httpMethod), ["GET"], "no PATCH")
    }

    func testEmailOnlyRouteSendsNothingToCalendar() async {
        let net = CalendarStubTransport()
        let outcome = await service(net).respond(.accepted, facts: facts(), event: nil)
        XCTAssertEqual(outcome.route, .emailOnly)
        XCTAssertEqual(net.requests.count, 0)
    }

    // MARK: - Finding the invitation's event

    func testLocateLooksInPrimaryThenTheOtherChosenCalendarsAndKeepsGooglesData() async throws {
        let net = CalendarStubTransport()
        net.respond = { request, _ in
            request.url?.path.contains("/calendars/team@group/") == true
                ? (200, #"{"items":[{"id":"inst_1","recurringEventId":"series"},{"id":"series","organizer":{"email":"org@y.com"},"start":{"dateTime":"2026-01-05T10:00:00Z"},"end":{"dateTime":"2026-01-05T11:00:00Z"}}]}"#, [:])
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
        let found = try XCTUnwrap(record)
        XCTAssertEqual(found.calendarId, "team@group")
        XCTAssertEqual(found.eventId, "series", "a series is answered on its master event")
        XCTAssertEqual(found.organizerEmail, "org@y.com")
        XCTAssertEqual(found.span, meeting)
        XCTAssertEqual(CalendarRSVPRoute.route(for: facts(), event: found, canWrite: true),
                       .calendarAndEmail(calendarId: "team@group", eventId: "series"))
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
        XCTAssertTrue(found.isIncomplete, "free/busy cannot tell the invitation apart")
        let list = try XCTUnwrap(net.requests.first)
        let q = URLComponents(url: list.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(q.first { $0.name == "timeMin" }?.value, "2026-01-05T00:00:00Z")
        XCTAssertEqual(q.first { $0.name == "timeMax" }?.value, "2026-01-06T00:00:00Z")
    }

    /// R6: with only free/busy access, the invitation already on the primary
    /// calendar does not conflict with itself.
    func testFreeBusyOnlyGrantDoesNotMakeTheInviteConflictWithItself() async throws {
        let net = CalendarStubTransport()
        net.respond = { _, _ in
            (200, #"{"calendars":{"a@x.com":{"busy":[{"start":"2026-01-05T10:00:00Z","end":"2026-01-05T11:00:00Z"}]}}}"#, [:])
        }
        let result = try await service(net, scopes: [CalendarScope.eventsFreeBusy]).availability(
            for: facts(), chosen: [source("a@x.com", primary: true)], zone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(result?.conflicts, [])
        XCTAssertEqual(result?.isIncomplete, true)
        XCTAssertEqual(net.requests.map(path), ["/calendar/v3/freeBusy"])
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

    func testImportBodyKeepsTheUIDAndTimesAndListsTheUserAsGuest() throws {
        let rome = TimeZone(identifier: "Europe/Rome")!
        let timed = try XCTUnwrap(CalendarInvitePlan.importBody(facts(), attendeeEmail: "a@x.com", zone: rome))
        XCTAssertEqual(timed["iCalUID"] as? String, "uid-1@google.com")
        XCTAssertEqual(timed["summary"] as? String, "Review")
        XCTAssertEqual(timed["location"] as? String, "Room 2")
        XCTAssertEqual((timed["organizer"] as? [String: String])?["email"], "org@y.com")
        XCTAssertEqual((timed["start"] as? [String: String])?["dateTime"], "2026-01-05T10:00:00Z")
        XCTAssertEqual((timed["end"] as? [String: String])?["dateTime"], "2026-01-05T11:00:00Z")
        XCTAssertEqual(timed["attendees"] as? [[String: String]],
                       [["email": "a@x.com", "responseStatus": "needsAction"]])

        let allDay = try XCTUnwrap(CalendarInvitePlan.importBody(facts(allDay: true), attendeeEmail: "a@x.com",
                                                                 zone: rome))
        XCTAssertEqual((allDay["start"] as? [String: String])?["date"], "2026-01-05")
        XCTAssertEqual((allDay["end"] as? [String: String])?["date"], "2026-01-06")

        var noTime = facts()
        noTime.span = nil
        XCTAssertNil(CalendarInvitePlan.importBody(noTime, attendeeEmail: "a@x.com", zone: rome))
        XCTAssertNil(CalendarInvitePlan.importBody(facts(), attendeeEmail: "", zone: rome))
    }

    func testAddToCalendarIsOfferedOnlyWhenItMakesSense() {
        XCTAssertTrue(CalendarInvitePlan.canAddToCalendar(facts(), event: nil, canWrite: true))
        XCTAssertFalse(CalendarInvitePlan.canAddToCalendar(facts(), event: located(), canWrite: true))
        XCTAssertFalse(CalendarInvitePlan.canAddToCalendar(facts(), event: nil, canWrite: false))
        XCTAssertFalse(CalendarInvitePlan.canAddToCalendar(facts(single: true), event: nil, canWrite: true))
        XCTAssertFalse(CalendarInvitePlan.canAddToCalendar(facts(recurring: true), event: nil, canWrite: true),
                       "R4: a series would be imported as one event")
        var noTime = facts()
        noTime.span = nil
        XCTAssertFalse(CalendarInvitePlan.canAddToCalendar(noTime, event: nil, canWrite: true))
        var cancelled = facts()
        cancelled.isAnswerable = false
        XCTAssertFalse(CalendarInvitePlan.canAddToCalendar(cancelled, event: nil, canWrite: true))
        var longUID = facts()
        longUID.uid = String(repeating: "u", count: CalendarClient.maxUIDBytes + 1)
        XCTAssertFalse(CalendarInvitePlan.canAddToCalendar(longUID, event: nil, canWrite: true))
    }

    /// R2: after "Add to calendar", Accept writes on the imported event.
    func testAddThenRespondWritesTheAnswerOnTheImportedEvent() async throws {
        let net = CalendarStubTransport()
        net.respond = { request, _ in
            switch (request.httpMethod ?? "", request.url?.path ?? "") {
            case ("POST", "/calendar/v3/calendars/primary/events/import"):
                return (200, #"{"id":"new1","iCalUID":"uid-1@google.com","organizer":{"email":"org@y.com"},"start":{"dateTime":"2026-01-05T10:00:00Z"},"end":{"dateTime":"2026-01-05T11:00:00Z"},"attendees":[{"email":"a@x.com","self":true,"responseStatus":"needsAction"}]}"#, [:])
            case ("GET", _):
                return (200, Self.selfAttendee, [:])
            default:
                return (200, "{}", [:])
            }
        }
        let s = service(net)
        let record = try await s.addToCalendar(facts(), attendeeEmail: "a@x.com",
                                               messageId: "a@x.com:m1", accountId: "a@x.com")
        XCTAssertEqual(record.eventId, "new1")
        XCTAssertEqual(record.calendarId, "primary")
        let imported = try XCTUnwrap(JSONSerialization.jsonObject(with: net.requests[0].httpBody ?? Data())
                                     as? [String: Any])
        XCTAssertEqual((imported["attendees"] as? [[String: String]])?.first?["email"], "a@x.com")

        let outcome = await s.respond(.accepted, facts: facts(), event: record)
        XCTAssertTrue(outcome.calendarWritten)
        XCTAssertEqual(net.requests.map(\.httpMethod), ["POST", "GET", "PATCH"])
        XCTAssertEqual(path(net.requests[2]), "/calendar/v3/calendars/primary/events/new1")
    }

    func testAddToCalendarNeedsTheWriteScope() async {
        let net = CalendarStubTransport()
        do {
            _ = try await service(net, scopes: [CalendarScope.eventsFreeBusy])
                .addToCalendar(facts(), attendeeEmail: "a@x.com", messageId: "m", accountId: "a@x.com")
            XCTFail("needs calendar.events")
        } catch {
            XCTAssertEqual(error as? CalendarError, .notGranted(.writeEvents))
        }
        XCTAssertEqual(net.requests.count, 0)
    }
}
