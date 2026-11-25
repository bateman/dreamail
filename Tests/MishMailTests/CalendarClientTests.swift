import XCTest

/// `CalendarClient` against a stubbed transport: paging, sync tokens,
/// free/busy, answering an invitation, and the scope, quota and token errors.
final class CalendarClientTests: XCTestCase {

    private let window = DateInterval(start: Date(timeIntervalSince1970: 1_767_225_600), // 2026-01-01Z
                                      duration: 86_400)

    private func client(_ net: CalendarStubTransport,
                        scopes: [String] = CalendarScope.recommended,
                        keychain: CalendarStubKeychain = CalendarStubKeychain(),
                        refreshes: CalendarCounter = CalendarCounter()) -> CalendarClient {
        let tokens = CalendarTokenSource(
            accountId: "a@x.com", enabled: true, readRefreshToken: keychain.reader,
            refresh: { _ in ("access-\(refreshes.increment())", 3600) })
        return CalendarClient(grant: CalendarGrant(scopes: Set(scopes)), tokens: tokens,
                              transport: net.transport)
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - Calendars and paging

    func testCalendarListFollowsPageTokens() async throws {
        let net = CalendarStubTransport()
        net.respond = { _, index in
            index == 0
                ? (200, #"{"items":[{"id":"a@x.com","primary":true,"accessRole":"owner"}],"nextPageToken":"p2"}"#, [:])
                : (200, #"{"items":[{"id":"it.italian#holiday@group.v.calendar.google.com"}]}"#, [:])
        }
        let calendars = try await client(net).calendars()
        XCTAssertEqual(calendars.map(\.id), ["a@x.com", "it.italian#holiday@group.v.calendar.google.com"])
        XCTAssertEqual(net.requests.count, 2)
        XCTAssertNil(query(net.requests[0])["pageToken"])
        XCTAssertEqual(query(net.requests[1])["pageToken"], "p2")
        for request in net.requests {
            XCTAssertEqual(request.url?.host, "www.googleapis.com")
            XCTAssertEqual(request.url?.path, "/calendar/v3/users/me/calendarList")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-1")
        }
    }

    func testCalendarIdIsEncodedAsOnePathSegment() throws {
        let id = "it.italian#holiday@group.v.calendar.google.com"
        let url = try CalendarClient.url(path: "/calendars/\(CalendarClient.pathSegment(id))/events",
                                         query: ["syncToken": "a+b"])
        XCTAssertEqual(url.absoluteString,
                       "https://www.googleapis.com/calendar/v3/calendars/it.italian%23holiday@group.v.calendar.google.com/events?syncToken=a%2Bb")
        XCTAssertEqual(CalendarClient.pathSegment("../x?y"), "..%2Fx%3Fy")
    }

    // MARK: - Events

    func testEventsInAWindowExpandRecurrencesAndPage() async throws {
        let net = CalendarStubTransport()
        net.respond = { _, index in
            index == 0
                ? (200, #"{"timeZone":"Europe/Rome","items":[{"id":"e1_20260101","recurringEventId":"e1","start":{"dateTime":"2026-01-01T10:00:00+01:00"},"end":{"dateTime":"2026-01-01T11:00:00+01:00"}}],"nextPageToken":"n"}"#, [:])
                : (200, #"{"items":[{"id":"e2","start":{"date":"2026-01-01"},"end":{"date":"2026-01-02"}}],"nextSyncToken":"s1"}"#, [:])
        }
        let result = try await client(net).events(calendarId: "primary", in: window)
        XCTAssertEqual(result.events.map(\.id), ["e1_20260101", "e2"])
        XCTAssertEqual(result.calendarTimeZone, "Europe/Rome")
        XCTAssertEqual(result.nextSyncToken, "s1")
        let first = query(net.requests[0])
        XCTAssertEqual(first["singleEvents"], "true")
        XCTAssertEqual(first["timeMin"], "2026-01-01T00:00:00Z")
        XCTAssertEqual(first["timeMax"], "2026-01-02T00:00:00Z")
        XCTAssertEqual(first["maxResults"], "250")
        XCTAssertEqual(query(net.requests[1])["pageToken"], "n")
    }

    func testIncrementalSyncSendsOnlyTheTokenAndExpiredTokenIs410() async throws {
        let net = CalendarStubTransport()
        net.respond = { _, _ in (200, #"{"items":[{"id":"e1","status":"cancelled"}],"nextSyncToken":"s2"}"#, [:]) }
        let c = client(net)
        let result = try await c.sync(calendarId: "primary", syncToken: "s1", from: window.start)
        XCTAssertEqual(result.nextSyncToken, "s2")
        XCTAssertEqual(result.events.first?.status, "cancelled")
        let q = query(net.requests[0])
        XCTAssertEqual(q["syncToken"], "s1")
        XCTAssertNil(q["timeMin"], "timeMin cannot be combined with a sync token")
        XCTAssertNil(q["timeMax"])

        _ = try await c.sync(calendarId: "primary", syncToken: nil, from: window.start)
        XCTAssertEqual(query(net.requests[1])["timeMin"], "2026-01-01T00:00:00Z")
        XCTAssertNil(query(net.requests[1])["syncToken"])

        net.respond = { _, _ in (410, #"{"error":{"errors":[{"reason":"fullSyncRequired"}]}}"#, [:]) }
        do {
            _ = try await c.sync(calendarId: "primary", syncToken: "s2", from: window.start)
            XCTFail("410 must surface")
        } catch {
            XCTAssertEqual(error as? CalendarError, .syncTokenExpired)
        }
    }

    // MARK: - Free/busy

    func testFreeBusyPostsTheWindowAndReadsBusyPeriods() async throws {
        let net = CalendarStubTransport()
        net.respond = { _, _ in
            (200, #"{"calendars":{"primary":{"busy":[{"start":"2026-01-01T09:00:00Z","end":"2026-01-01T10:00:00.000Z"}]},"x@y.com":{"errors":[{"reason":"notFound"}]}}}"#, [:])
        }
        let result = try await client(net).freeBusy(calendarIds: ["primary", "x@y.com", "missing"], in: window)
        XCTAssertEqual(result.map(\.calendarId), ["primary", "x@y.com", "missing"])
        XCTAssertEqual(result[0].busy, [DateInterval(start: window.start.addingTimeInterval(9 * 3600),
                                                     duration: 3600)])
        XCTAssertFalse(result[0].failed)
        XCTAssertTrue(result[1].failed)
        XCTAssertTrue(result[2].failed)

        let request = net.requests[0]
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/calendar/v3/freeBusy")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(body["timeMin"] as? String, "2026-01-01T00:00:00Z")
        XCTAssertEqual(body["timeMax"] as? String, "2026-01-02T00:00:00Z")
        XCTAssertEqual((body["items"] as? [[String: String]])?.map { $0["id"] ?? "" },
                       ["primary", "x@y.com", "missing"])
    }

    // MARK: - Answering an invitation

    func testRespondChangesOnlyTheUsersOwnAnswerAndKeepsTheOtherFields() async throws {
        let net = CalendarStubTransport()
        net.respond = { request, _ in
            request.httpMethod == "GET"
                ? (200, #"{"attendees":[{"email":"org@y.com","organizer":true,"responseStatus":"accepted"},{"email":"a@x.com","self":true,"responseStatus":"needsAction","comment":"keep","additionalGuests":1}]}"#, [:])
                : (200, "{}", [:])
        }
        try await client(net).respond(calendarId: "primary", eventId: "ev/1", response: .accepted,
                                      sendUpdates: .none)
        XCTAssertEqual(net.requests.map(\.httpMethod), ["GET", "PATCH"])
        XCTAssertEqual(query(net.requests[0])["fields"], "attendees")
        let patch = net.requests[1]
        XCTAssertEqual(patch.url?.absoluteString,
                       "https://www.googleapis.com/calendar/v3/calendars/primary/events/ev%2F1?sendUpdates=none")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: patch.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(Array(body.keys), ["attendees"], "a patch touches nothing else")
        let attendees = try XCTUnwrap(body["attendees"] as? [[String: Any]])
        XCTAssertEqual(attendees.count, 2)
        XCTAssertEqual(attendees[0]["responseStatus"] as? String, "accepted")
        XCTAssertEqual(attendees[0]["organizer"] as? Bool, true)
        XCTAssertEqual(attendees[1]["responseStatus"] as? String, "accepted")
        XCTAssertEqual(attendees[1]["comment"] as? String, "keep")
        XCTAssertEqual(attendees[1]["additionalGuests"] as? Int, 1)
    }

    func testRespondWithoutBeingAGuestSendsNoPatch() async {
        let net = CalendarStubTransport()
        net.respond = { _, _ in (200, #"{"attendees":[{"email":"org@y.com"}]}"#, [:]) }
        do {
            try await client(net).respond(calendarId: "primary", eventId: "e", response: .declined,
                                          sendUpdates: .all)
            XCTFail("not a guest")
        } catch {
            XCTAssertEqual(error as? CalendarError, .notAnAttendee)
        }
        XCTAssertEqual(net.requests.map(\.httpMethod), ["GET"])
    }

    // MARK: - Scopes: "not granted" before any request

    func testMissingScopeFailsBeforeAnyRequest() async {
        let net = CalendarStubTransport()
        let keychain = CalendarStubKeychain()
        let c = client(net, scopes: [CalendarScope.eventsFreeBusy], keychain: keychain)
        await assertError(.notGranted(.calendarList)) { _ = try await c.calendars() }
        await assertError(.notGranted(.events)) { _ = try await c.events(calendarId: "p", in: self.window) }
        await assertError(.notGranted(.respond)) {
            try await c.respond(calendarId: "p", eventId: "e", response: .accepted, sendUpdates: .none)
        }
        XCTAssertEqual(net.requests.count, 0)
        XCTAssertEqual(keychain.reads, [])
        _ = try? await c.freeBusy(calendarIds: ["p"], in: window)
        XCTAssertEqual(net.requests.count, 1, "free/busy is what this grant allows")
    }

    func testGrantReadsWhatGoogleGrantedNotWhatWasAsked() {
        let partial = CalendarGrant(grantedScopeField:
            "https://www.googleapis.com/auth/userinfo.email \(CalendarScope.eventsFreeBusy)")
        XCTAssertEqual(partial.scopes, [CalendarScope.eventsFreeBusy], "non-Calendar scopes are ignored")
        XCTAssertTrue(partial.canReadAvailability)
        XCTAssertFalse(partial.canReadEvents)
        XCTAssertFalse(partial.canRespond)
        XCTAssertFalse(partial.canListCalendars)
        XCTAssertTrue(CalendarGrant(grantedScopeField: nil).isEmpty)
        XCTAssertTrue(CalendarGrant(grantedScopeField: "").isEmpty)
        XCTAssertFalse(CalendarGrant(scopes: [CalendarScope.events]).canReadAvailability,
                       "freebusy.query does not accept calendar.events")
        XCTAssertTrue(CalendarGrant(scopes: [CalendarScope.readOnly]).canListCalendars)
        XCTAssertFalse(CalendarGrant(scopes: [CalendarScope.readOnly]).canRespond)
    }

    func testAccessStateTreatsEveryMissingPieceAsNotGranted() {
        let grant = CalendarGrant(scopes: [CalendarScope.events])
        XCTAssertEqual(CalendarAccessState.resolve(enabled: false, hasToken: true, grant: grant), .switchedOff)
        XCTAssertEqual(CalendarAccessState.resolve(enabled: true, hasToken: false, grant: grant), .notGranted)
        XCTAssertEqual(CalendarAccessState.resolve(enabled: true, hasToken: true, grant: nil), .notGranted)
        XCTAssertEqual(CalendarAccessState.resolve(enabled: true, hasToken: true,
                                                   grant: CalendarGrant(scopes: [])), .notGranted)
        XCTAssertEqual(CalendarAccessState.resolve(enabled: true, hasToken: true, grant: grant), .granted(grant))
    }

    func testInsufficientScopeFromGoogleIsNotGranted() async {
        let net = CalendarStubTransport()
        net.respond = { _, _ in
            (403, #"{"error":{"code":403,"message":"Request had insufficient authentication scopes. Meeting: Secret plan","errors":[{"reason":"insufficientPermissions"}],"status":"PERMISSION_DENIED"}}"#, [:])
        }
        await assertError(.notGranted(nil)) { _ = try await self.client(net).calendars() }
    }

    // MARK: - Tokens, quota, errors

    func testRejectedTokenIsRefreshedOnceThenNotGranted() async throws {
        let net = CalendarStubTransport()
        let refreshes = CalendarCounter()
        net.respond = { _, index in index == 0 ? (401, "{}", [:]) : (200, #"{"items":[]}"#, [:]) }
        let c = client(net, refreshes: refreshes)
        _ = try await c.calendars()
        XCTAssertEqual(net.requests.map { $0.value(forHTTPHeaderField: "Authorization") },
                       ["Bearer access-1", "Bearer access-2"])

        net.respond = { _, _ in (401, "{}", [:]) }
        await assertError(.notGranted(nil)) { _ = try await c.calendars() }
    }

    func testRevokedGrantAndMissingTokenAreNotGranted() async {
        let keychain = CalendarStubKeychain()
        keychain.value = .notFound
        let missing = CalendarTokenSource(accountId: "a@x.com", enabled: true,
                                          readRefreshToken: keychain.reader,
                                          refresh: { _ in ("t", 3600) })
        await assertError(.notGranted(nil)) { _ = try await missing.token() }
        XCTAssertEqual(keychain.reads, ["calendarRefreshToken.a@x.com"])

        let revoked = CalendarTokenSource(accountId: "a@x.com", enabled: true,
                                          readRefreshToken: CalendarStubKeychain().reader,
                                          refresh: { _ in throw OAuthError.invalidGrant })
        await assertError(.notGranted(nil)) { _ = try await revoked.token() }

        keychain.value = .unavailable(-25308)
        await assertError(.keychainUnavailable(-25308)) { _ = try await missing.token() }
    }

    func testAccessTokenIsReusedUntilItExpires() async throws {
        let refreshes = CalendarCounter()
        let clock = CalendarClock(Date(timeIntervalSince1970: 0))
        let source = CalendarTokenSource(accountId: "a@x.com", enabled: true,
                                         readRefreshToken: CalendarStubKeychain().reader,
                                         refresh: { _ in ("t\(refreshes.increment())", 3600) },
                                         now: { clock.now })
        let first = try await source.token()
        let second = try await source.token()
        XCTAssertEqual(first, "t1")
        XCTAssertEqual(second, "t1")
        clock.now = Date(timeIntervalSince1970: 3600)
        let third = try await source.token()
        XCTAssertEqual(third, "t2")
    }

    func testQuotaAndOtherErrorsCarryNoBodyText() {
        func body(_ reason: String) -> Data {
            Data(#"{"error":{"message":"Team offsite with alice@y.com","errors":[{"reason":"\#(reason)"}]}}"#.utf8)
        }
        XCTAssertEqual(CalendarError.classify(status: 429, body: Data(), retryAfterHeader: "7"),
                       .rateLimited(retryAfter: 7))
        XCTAssertEqual(CalendarError.classify(status: 403, body: body("rateLimitExceeded"), retryAfterHeader: nil),
                       .rateLimited(retryAfter: nil))
        XCTAssertEqual(CalendarError.classify(status: 403, body: body("userRateLimitExceeded"), retryAfterHeader: nil),
                       .rateLimited(retryAfter: nil))
        XCTAssertEqual(CalendarError.classify(status: 403, body: body("quotaExceeded"), retryAfterHeader: nil),
                       .rateLimited(retryAfter: nil))
        XCTAssertEqual(CalendarError.classify(status: 403, body: body("forbiddenForNonOrganizer"), retryAfterHeader: nil),
                       .http(403, reason: "forbiddenForNonOrganizer"))
        XCTAssertEqual(CalendarError.classify(status: 410, body: Data(), retryAfterHeader: nil), .syncTokenExpired)
        let server = CalendarError.classify(status: 503, body: body("backendError"), retryAfterHeader: nil)
        XCTAssertEqual(server, .http(503, reason: "backendError"))
        let text = server.errorDescription ?? ""
        XCTAssertFalse(text.contains("offsite"), text)
        XCTAssertFalse(text.contains("alice"), text)
        XCTAssertEqual(CalendarError.classify(status: 400, body: Data("not json".utf8), retryAfterHeader: nil),
                       .http(400, reason: nil))
    }

    func testUnreadableResponseIsBadResponse() async {
        let net = CalendarStubTransport()
        net.respond = { _, _ in (200, "<html>", [:]) }
        await assertError(.badResponse) { _ = try await self.client(net).calendars() }
    }

    func testEndlessPagingStops() async {
        let net = CalendarStubTransport()
        net.respond = { _, index in (200, #"{"items":[],"nextPageToken":"p\#(index)"}"#, [:]) }
        await assertError(.badResponse) { _ = try await self.client(net).calendars() }
        XCTAssertEqual(net.requests.count, CalendarClient.maxPages)
    }

    // MARK: - Separate consent

    func testAuthorizationAsksOnlyForCalendarAndChecksTheAccount() async throws {
        let steps = CalendarStubSteps()
        let grant = try await CalendarAuthorization.request(accountId: "A@x.com", enabled: true,
                                                            steps: steps.steps)
        XCTAssertEqual(grant.scopes, Set(CalendarScope.recommended))
        XCTAssertEqual(steps.calls, ["authorize:A@x.com", "userinfo", "save:A@x.com"])
        XCTAssertEqual(steps.askedScopes, CalendarScope.recommended + [CalendarScope.identity])
        XCTAssertFalse(steps.askedScopes.contains { $0.contains("gmail") })
    }

    func testAuthorizationForAnotherAccountStoresNothing() async {
        let steps = CalendarStubSteps()
        steps.email = "other@x.com"
        await assertError(.wrongAccount) {
            _ = try await CalendarAuthorization.request(accountId: "a@x.com", enabled: true, steps: steps.steps)
        }
        XCTAssertEqual(steps.savedFor, [])
    }

    func testAuthorizationWithEveryCalendarScopeUntickedStoresNothing() async {
        let steps = CalendarStubSteps()
        steps.grantedScopes = CalendarScope.identity
        await assertError(.notGranted(nil)) {
            _ = try await CalendarAuthorization.request(accountId: "a@x.com", enabled: true, steps: steps.steps)
        }
        XCTAssertEqual(steps.savedFor, [])
    }

    func testTokenResponseDecodesTheGrantedScopes() throws {
        let token = try JSONDecoder().decode(TokenResponse.self, from: Data(
            #"{"access_token":"a","expires_in":3599,"refresh_token":"r","scope":"x y"}"#.utf8))
        XCTAssertEqual(token.scope, "x y")
        let old = try JSONDecoder().decode(TokenResponse.self, from: Data(
            #"{"access_token":"a","expires_in":3599}"#.utf8))
        XCTAssertNil(old.scope)
    }

    // MARK: - Helpers

    private func assertError(_ expected: CalendarError,
                             file: StaticString = #filePath, line: UInt = #line,
                             _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? CalendarError, expected, "\(error)", file: file, line: line)
        }
    }
}

final class CalendarCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}

final class CalendarClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date) { current = date }

    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
}
