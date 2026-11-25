import XCTest
import GRDB
import Security

/// Stub responses, outside the main-actor test class so the stub
/// transport's `@Sendable` closures can read them.
private enum Fixture {
    static func eventJSON(uid: String = "abc123@google.com", id: String = "ev1") -> String {
        """
        {"items":[{"id":"\(id)","status":"confirmed","iCalUID":"\(uid)",
          "organizer":{"email":"org@x.com"},
          "attendees":[{"email":"a@x.com","self":true,"responseStatus":"needsAction"}],
          "start":{"dateTime":"2026-12-01T10:00:00Z"},"end":{"dateTime":"2026-12-01T11:00:00Z"}}]}
        """
    }

    static let inviteEventJSON = eventJSON()
    static let empty = #"{"items":[]}"#

    static func query(_ request: URLRequest, _ name: String) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }

    static func isLookup(_ request: URLRequest) -> Bool { query(request, "iCalUID") != nil }
}

/// A flag the stub transport's `@Sendable` closures can read.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func set() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }
}

/// Records the Keychain deletes the integration asks for.
private final class DeletedTokens: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    var status: OSStatus = errSecSuccess
    var accounts: [String] {
        lock.lock(); defer { lock.unlock() }
        return ids
    }
    func add(_ id: String) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        ids.append(id)
        return status
    }
}

/// `CalendarIntegration`, the one door the UI uses into the Calendar code:
/// the account states Settings shows, the invitation card's states
/// (not connected, consent refused, offline, error, not found, ready), the
/// answer (e-mail first, then the calendar), "add to calendar", the
/// in-memory cache and what is stored. Hostless: stub network, Keychain and
/// consent.
@MainActor
final class CalendarIntegrationTests: XCTestCase {

    private var account: String { "a@x.com" }
    private var googleUID: String { "abc123@google.com" }

    // MARK: - Fixtures

    private struct Harness {
        let integration: CalendarIntegration
        let db: DatabaseQueue
        let net: CalendarStubTransport
        let keychain: CalendarStubKeychain
        let steps: CalendarStubSteps
        let deleted: DeletedTokens
    }

    private func harness(enabled: Bool = true, transport: CalendarTransport? = nil,
                         steps customSteps: CalendarAuthorization.Steps? = nil,
                         now: @escaping @MainActor () -> Date = { Date() }) throws -> Harness {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let account = self.account
        try db.write { db in
            try Account(id: account, displayName: account, historyId: nil, lastSyncAt: nil,
                        senderName: "").insert(db)
        }
        let net = CalendarStubTransport()
        let keychain = CalendarStubKeychain()
        let steps = CalendarStubSteps()
        let deleted = DeletedTokens()
        let deps = CalendarIntegration.Dependencies(
            enabled: enabled,
            database: { db },
            steps: customSteps ?? steps.steps,
            transport: transport ?? net.transport,
            readRefreshToken: keychain.reader,
            refresh: { _ in ("access-not-real", 3600) },
            deleteRefreshToken: { deleted.add($0) })
        return Harness(integration: CalendarIntegration(dependencies: deps, now: now), db: db, net: net,
                       keychain: keychain, steps: steps, deleted: deleted)
    }

    /// A connected account whose only chosen calendar is its primary one.
    private func connect(_ h: Harness, scopes: [String] = CalendarScope.recommended) throws {
        let account = self.account
        try h.db.write { db in
            try CalendarStore.saveGrant(
                db, accountId: account, scopes: scopes.joined(separator: " "),
                at: Date(), calendars: [GCalendarListEntry(
                    id: account, summary: "Me", timeZone: "Europe/Rome", primary: true,
                    accessRole: "owner")])
        }
    }

    private func facts(uid: String? = nil, hours: Double = 1) -> CalendarInviteFacts {
        let start = ISO8601DateFormatter().date(from: "2026-12-01T10:00:00Z")!
        return CalendarInviteFacts(
            uid: uid ?? googleUID, summary: "Review", location: "Room 2", organizerEmail: "org@x.com",
            span: CalendarSpan(start: start, end: start.addingTimeInterval(hours * 3600), isAllDay: false))
    }

    private func count(_ h: Harness, _ table: String) throws -> Int {
        try h.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") ?? -1 }
    }

    private func lookups(_ h: Harness) -> Int { h.net.requests.filter(Fixture.isLookup).count }

    /// Records the e-mail reply and what the integration had done before it.
    private final class EmailProbe {
        var sent = 0
        var requestsBefore: [Int] = []
    }

    // MARK: - Switch off

    func testSwitchedOffShowsNothingAndTouchesNothing() async throws {
        let h = try harness(enabled: false)
        try connect(h)
        XCTAssertEqual(h.integration.status(for: account), .off)
        let check = await h.integration.check(facts(), messageId: "m1", accountId: account)
        XCTAssertEqual(check, .off)
        do {
            try await h.integration.connect(accountId: account)
            XCTFail("connect must refuse with the switch off")
        } catch {
            XCTAssertEqual(error as? CalendarError, .switchedOff)
        }
        do {
            _ = try await h.integration.calendarList(accountId: account)
            XCTFail("the calendar list must refuse with the switch off")
        } catch {
            XCTAssertEqual(error as? CalendarError, .switchedOff)
        }
        var sent = 0
        let result = await h.integration.answer(.accepted, facts: facts(), findings: nil,
                                                accountId: account) { sent += 1; return true }
        XCTAssertEqual(sent, 1, "the e-mail reply still goes, as before")
        XCTAssertFalse(result.calendarWritten)
        XCTAssertEqual(h.steps.calls, [], "no browser, no consent")
        XCTAssertEqual(h.net.requests.count, 0)
        XCTAssertEqual(h.keychain.reads, [])
    }

    // MARK: - Settings: connect, choose, disconnect, removal

    func testConnectChoosesThePrimaryCalendarAndDisconnectForgetsEverything() async throws {
        let h = try harness()
        h.net.respond = { request, _ in
            if request.url!.path.hasSuffix("/users/me/calendarList") {
                return (200, """
                    {"items":[{"id":"a@x.com","summary":"Me","primary":true,"accessRole":"owner"},
                              {"id":"team@group.calendar.google.com","summary":"Team","accessRole":"reader"}]}
                    """, [:])
            }
            return (200, Fixture.empty, [:])
        }
        XCTAssertEqual(h.integration.status(for: account), .notConnected)

        let connected = try await h.integration.connect(accountId: account)
        XCTAssertTrue(connected)
        XCTAssertEqual(h.steps.savedFor, [account])
        XCTAssertTrue(h.integration.status(for: account).isConnected)
        XCTAssertEqual(h.integration.chosen[account]?.map(\.calendarId), [account])

        let list = try await h.integration.calendarList(accountId: account)
        XCTAssertEqual(list.map(\.id), [account, "team@group.calendar.google.com"])
        try await h.integration.choose(list, accountId: account)
        XCTAssertEqual(h.integration.chosen[account]?.count, 2)

        // A reconnect keeps the user's choice.
        try await h.integration.connect(accountId: account)
        XCTAssertEqual(h.integration.chosen[account]?.count, 2)

        _ = await h.integration.check(facts(), messageId: "m1", accountId: account)
        XCTAssertEqual(h.integration.locatedCount, 1)
        try await h.integration.disconnect(accountId: account)
        XCTAssertEqual(h.integration.status(for: account), .notConnected)
        XCTAssertEqual(h.deleted.accounts, [account])
        XCTAssertEqual(h.integration.locatedCount, 0, "the memory goes too")
        XCTAssertEqual(try count(h, "calendarGrant"), 0)
        XCTAssertEqual(try count(h, "calendarSource"), 0)
    }

    /// The Keychain token goes first; if it cannot be deleted, nothing else
    /// is, and the user is told.
    func testDisconnectStopsWhenTheTokenCannotBeDeleted() async throws {
        let h = try harness()
        try connect(h)
        await h.integration.load(accountId: account)
        h.deleted.status = errSecInteractionNotAllowed
        do {
            try await h.integration.disconnect(accountId: account)
            XCTFail("a Keychain failure must not be ignored")
        } catch {
            XCTAssertEqual(error as? CalendarError, .keychainUnavailable(errSecInteractionNotAllowed))
        }
        XCTAssertEqual(try count(h, "calendarGrant"), 1)
        XCTAssertTrue(h.integration.status(for: account).isConnected)
    }

    func testAConsentAlreadyOpenIsNotReportedAsConnected() async throws {
        let slow = CalendarAuthorization.Steps(
            authorize: { _, _ in
                try await Task.sleep(nanoseconds: 200_000_000)
                return .init(refreshToken: "r", accessToken: "a",
                             grantedScopes: CalendarScope.recommended.joined(separator: " "))
            },
            signedInEmail: { _ in "a@x.com" },
            saveRefreshToken: { _, _ in })
        let h = try harness(steps: slow)
        async let first = h.integration.connect(accountId: account)
        try await Task.sleep(nanoseconds: 50_000_000)
        let second = try await h.integration.connect(accountId: account)
        XCTAssertFalse(second, "the second request did nothing")
        let firstResult = try await first
        XCTAssertTrue(firstResult)
    }

    /// Account removal: the memory goes (grant, choice, cache, token
    /// source), and an account added again in the same run starts from
    /// what the database says.
    func testRemovedAccountLeavesNothingInMemory() async throws {
        let h = try harness()
        try connect(h)
        h.net.respond = { _, _ in (200, Fixture.empty, [:]) }
        _ = await h.integration.check(facts(), messageId: "m1", accountId: account)
        XCTAssertEqual(h.integration.locatedCount, 1)

        // The purge deletes the rows; the store forgets the memory.
        let account = self.account
        try await h.db.write { try CalendarStore.forget($0, accountId: account) }
        await h.integration.forget(accountId: account)
        XCTAssertEqual(h.integration.locatedCount, 0)
        XCTAssertNil(h.integration.grants[account])

        let sent = h.net.requests.count
        let check = await h.integration.check(facts(), messageId: "m1", accountId: account)
        XCTAssertEqual(check, .notConnected)
        XCTAssertEqual(h.net.requests.count, sent, "no request for a removed account")
    }

    /// A check still running when the account is disconnected does not
    /// write its result back, and the card drops what it held.
    func testACheckFinishingAfterDisconnectWritesNothingBack() async throws {
        let gate = CalendarStubGate()
        let net = CalendarStubTransport()
        net.respond = { _, _ in (200, Fixture.empty, [:]) }
        let h = try harness(transport: CalendarTransport { request in
            await gate.wait()
            return try await net.transport.data(request)
        })
        try connect(h)
        await h.integration.load(accountId: account)
        async let late = h.integration.check(facts(), messageId: "m1", accountId: account)
        try await Task.sleep(nanoseconds: 50_000_000)
        try await h.integration.disconnect(accountId: account)
        await gate.open()
        let result = await late
        XCTAssertEqual(result, .notConnected)
        XCTAssertEqual(h.integration.locatedCount, 0)

        let held = CalendarInviteCheck.ready(CalendarInviteFindings(grant: CalendarGrant(
            scopes: Set(CalendarScope.recommended))))
        XCTAssertEqual(held.current(.notConnected), .notConnected)
        XCTAssertEqual(held.current(.needsConsent), .needsConsent)
        XCTAssertEqual(held.current(.connected(CalendarGrant(scopes: []))), held)
    }

    // MARK: - Invitation card

    func testCheckFindsTheEventAndAvailabilityAndStoresNothing() async throws {
        let h = try harness()
        try connect(h)
        h.net.respond = { _, _ in (200, Fixture.inviteEventJSON, [:]) }
        let check = await h.integration.check(facts(), messageId: "m1", accountId: account)
        let findings = try XCTUnwrap(check.findings, "\(check)")
        XCTAssertEqual(findings.event?.eventId, "ev1")
        XCTAssertEqual(findings.event?.calendarId, "primary")
        XCTAssertEqual(findings.availability?.isFree, true, "the invitation is not its own conflict")
        XCTAssertEqual(findings.route(for: facts()),
                       .calendarAndEmail(calendarId: "primary", eventId: "ev1"))
        XCTAssertFalse(findings.canAddToCalendar(facts(), organizerIsSender: true))
        let tableExists = try await h.db.read { try $0.tableExists("calendarInviteEvent") }
        XCTAssertFalse(tableExists)
    }

    func testAConflictOnAChosenCalendarIsReported() async throws {
        let h = try harness()
        try connect(h)
        h.net.respond = { request, _ in
            if Fixture.isLookup(request) { return (200, Fixture.empty, [:]) }
            return (200, """
                {"items":[{"id":"busy1","summary":"Standup","iCalUID":"other@x",
                  "start":{"dateTime":"2026-12-01T10:30:00Z"},"end":{"dateTime":"2026-12-01T11:30:00Z"}}]}
                """, [:])
        }
        let check = await h.integration.check(facts(), messageId: "m1", accountId: account)
        let findings = try XCTUnwrap(check.findings, "\(check)")
        XCTAssertNil(findings.event, "not on any calendar")
        XCTAssertEqual(findings.availability?.conflicts.count, 1)
        XCTAssertEqual(findings.route(for: facts()), .emailOnly)
        XCTAssertTrue(findings.canAddToCalendar(facts(), organizerIsSender: true))
        XCTAssertFalse(findings.canAddToCalendar(facts(), organizerIsSender: false),
                       "a forwarded or forged invitation is never imported")
    }

    func testAnInvitationLongerThanAMonthIsNotCheckedForConflicts() async throws {
        let h = try harness()
        try connect(h)
        h.net.respond = { _, _ in (200, Fixture.empty, [:]) }
        let long = facts(hours: 24 * 40)
        let findingsCheck = await h.integration.check(long, messageId: "m1", accountId: account)
        let findings = try XCTUnwrap(findingsCheck.findings)
        XCTAssertTrue(findings.availabilitySkipped)
        XCTAssertNil(findings.availability)
        XCTAssertEqual(h.net.requests.filter { !Fixture.isLookup($0) }.count, 0,
                       "no events read for the window")
    }

    func testACalendarReadOnlyInPartIsIncomplete() async throws {
        let h = try harness()
        try connect(h)
        h.net.respond = { request, _ in
            if Fixture.isLookup(request) { return (200, Fixture.empty, [:]) }
            return (200, #"{"items":[],"nextPageToken":"more"}"#, [:])
        }
        let findingsCheck = await h.integration.check(facts(), messageId: "m1", accountId: account)
        let findings = try XCTUnwrap(findingsCheck.findings)
        XCTAssertEqual(findings.availability?.isIncomplete, true)
        XCTAssertEqual(h.net.requests.filter { !Fixture.isLookup($0) }.count,
                       CalendarClient.availabilityMaxPages)
    }

    func testARefusedGrantAsksToReconnect() async throws {
        let h = try harness()
        try connect(h)
        h.keychain.value = .notFound
        let check = await h.integration.check(facts(), messageId: "m1", accountId: account)
        XCTAssertEqual(check, .needsConsent)
        XCTAssertEqual(h.integration.status(for: account), .needsConsent)
        XCTAssertEqual(h.net.requests.count, 0)
    }

    /// A scope the user unticked is an error of that call, not a refused
    /// grant: the account is not marked as needing consent.
    func testAMissingScopeDoesNotMarkTheAccount() async throws {
        let h = try harness()
        try connect(h, scopes: [CalendarScope.events])
        await h.integration.load(accountId: account)
        do {
            _ = try await h.integration.calendarList(accountId: account)
            XCTFail("the list needs calendarlist.readonly")
        } catch {
            XCTAssertEqual(error as? CalendarError, .notGranted(.calendarList))
        }
        XCTAssertTrue(h.integration.status(for: account).isConnected)
        XCTAssertEqual(CalendarIntegration.check(for: CalendarError.notGranted(.events)),
                       .failed(CalendarIntegration.missingScopeMessage))
        XCTAssertEqual(h.net.requests.count, 0)
    }

    func testOfflineIsItsOwnState() async throws {
        let h = try harness(transport: CalendarTransport { _ in
            throw URLError(.notConnectedToInternet)
        })
        try connect(h)
        let check = await h.integration.check(facts(), messageId: "m1", accountId: account)
        XCTAssertEqual(check, .offline)
        XCTAssertTrue(h.integration.status(for: account).isConnected, "offline is not a refusal")
    }

    func testAnAPIErrorCarriesNoResponseBody() async throws {
        let h = try harness()
        try connect(h)
        h.net.respond = { _, _ in
            (500, #"{"error":{"status":"INTERNAL","message":"Review with org@x.com"}}"#, [:])
        }
        let check = await h.integration.check(facts(), messageId: "m1", accountId: account)
        guard case .failed(let text) = check else { return XCTFail("\(check)") }
        XCTAssertTrue(text.contains("500"), text)
        XCTAssertFalse(text.contains("org@x.com"), text)
        XCTAssertFalse(text.contains("Review"), text)
    }

    func testNotConnectedSendsNothing() async throws {
        let h = try harness()
        let check = await h.integration.check(facts(), messageId: "m1", accountId: account)
        XCTAssertEqual(check, .notConnected)
        XCTAssertEqual(h.net.requests.count, 0)
        XCTAssertEqual(h.keychain.reads, [])
    }

    // MARK: - Answering: e-mail first, then the calendar

    func testTheEmailGoesFirstThenTheCalendarWithGoogleToldToEmailNobody() async throws {
        let h = try harness()
        try connect(h)
        h.net.respond = { request, _ in
            if request.httpMethod == "GET", Fixture.query(request, "fields") == "attendees" {
                return (200, #"{"attendees":[{"email":"a@x.com","self":true,"responseStatus":"needsAction"}]}"#, [:])
            }
            if request.httpMethod == "GET" { return (200, Fixture.inviteEventJSON, [:]) }
            return (200, "{}", [:])
        }
        let findings = await h.integration.check(facts(), messageId: "m1", accountId: account).findings
        let before = h.net.requests.count
        let probe = EmailProbe()
        let result = await h.integration.answer(.accepted, facts: facts(), findings: findings,
                                                accountId: account) {
            probe.sent += 1
            probe.requestsBefore.append(h.net.requests.count)
            return true
        }
        XCTAssertEqual(probe.sent, 1, "the e-mail goes exactly once")
        XCTAssertEqual(probe.requestsBefore, [before], "and before any calendar request")
        XCTAssertTrue(result.emailSent)
        XCTAssertTrue(result.calendarWritten)
        XCTAssertNil(result.calendarFailure)
        let patch = try XCTUnwrap(h.net.requests.first { $0.httpMethod == "PATCH" })
        XCTAssertEqual(Fixture.query(patch, "sendUpdates"), "none")
    }

    func testAFailedEmailWritesNothingOnTheCalendar() async throws {
        let h = try harness()
        try connect(h)
        h.net.respond = { _, _ in (200, Fixture.inviteEventJSON, [:]) }
        let findings = await h.integration.check(facts(), messageId: "m1", accountId: account).findings
        let before = h.net.requests.count
        var sent = 0
        let result = await h.integration.answer(.accepted, facts: facts(), findings: findings,
                                                accountId: account) { sent += 1; return false }
        XCTAssertEqual(sent, 1)
        XCTAssertEqual(result, .notSent)
        XCTAssertEqual(h.net.requests.count, before, "no calendar request after a failed e-mail")
    }

    func testAFailedCalendarWriteIsOnlyReported() async throws {
        let h = try harness()
        try connect(h)
        h.net.respond = { request, _ in
            if Fixture.query(request, "fields") == "attendees" { return (500, "{}", [:]) }
            return (200, Fixture.inviteEventJSON, [:])
        }
        let findings = await h.integration.check(facts(), messageId: "m1", accountId: account).findings
        var sent = 0
        let result = await h.integration.answer(.declined, facts: facts(), findings: findings,
                                                accountId: account) { sent += 1; return true }
        XCTAssertEqual(sent, 1)
        XCTAssertTrue(result.emailSent)
        XCTAssertFalse(result.calendarWritten)
        let failure = try XCTUnwrap(result.calendarFailure)
        XCTAssertTrue(failure.contains("500"), failure)
        XCTAssertNil(h.net.requests.first { $0.httpMethod == "PATCH" })
    }

    func testAGoneEventIsLookedUpAgain() async throws {
        let h = try harness()
        try connect(h)
        h.net.respond = { request, _ in
            if Fixture.query(request, "fields") == "attendees" { return (404, "{}", [:]) }
            return (200, Fixture.inviteEventJSON, [:])
        }
        let findings = await h.integration.check(facts(), messageId: "m1", accountId: account).findings
        let result = await h.integration.answer(.accepted, facts: facts(), findings: findings,
                                                accountId: account) { true }
        XCTAssertTrue(result.eventGone)
        XCTAssertNil(result.calendarFailure, "nothing to report: the card looks again")
        let before = lookups(h)
        _ = await h.integration.check(facts(), messageId: "m1", accountId: account)
        XCTAssertEqual(lookups(h), before + 1, "the cached location was dropped")
    }

    func testWithoutACheckTheAnswerGoesByEmailOnly() async throws {
        let h = try harness()
        try connect(h)
        var sent = 0
        let result = await h.integration.answer(.accepted, facts: facts(), findings: nil,
                                                accountId: account) { sent += 1; return true }
        XCTAssertEqual(sent, 1)
        XCTAssertFalse(result.calendarWritten)
        var unanswerable = facts()
        unanswerable.isAnswerable = false
        let none = await h.integration.answer(.accepted, facts: unanswerable, findings: nil,
                                              accountId: account) { sent += 1; return true }
        XCTAssertEqual(none, .notSent)
        XCTAssertEqual(sent, 1, "what #51 refuses to answer is not e-mailed")
        XCTAssertEqual(h.net.requests.count, 0)
    }

    // MARK: - Add to calendar

    func testAddToCalendarLooksAgainThenImportsSafeTextOnThePrimaryCalendar() async throws {
        let h = try harness()
        try connect(h)
        h.net.respond = { request, _ in
            if request.httpMethod == "POST" {
                return (200, #"{"id":"new1","iCalUID":"abc123@google.com"}"#, [:])
            }
            return (200, Fixture.empty, [:])
        }
        let check = await h.integration.check(facts(), messageId: "m1", accountId: account)
        let findings = try XCTUnwrap(check.findings)
        var sender = facts()
        sender.summary = "Review\u{202E}" + String(repeating: "x", count: 500)
        let lookupsBefore = lookups(h)
        let updated = try await h.integration.addToCalendar(
            sender, findings: findings, organizerIsSender: true, attendeeEmail: "me@alias.com",
            messageId: "m1", accountId: account)
        XCTAssertEqual(updated.event?.eventId, "new1")
        XCTAssertEqual(lookups(h), lookupsBefore + 1, "looked up again, without the cache")
        let post = try XCTUnwrap(h.net.requests.first { $0.httpMethod == "POST" })
        XCTAssertTrue(post.url!.path.hasSuffix("/calendars/primary/events/import"), post.url!.path)
        let body = try XCTUnwrap(post.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(body.contains("me@alias.com"), "the guest is the answering address")
        XCTAssertFalse(body.contains("\u{202E}"), "the sender's title is made display-safe")
        XCTAssertLessThanOrEqual(CalendarIntegration.importable(sender).summary.count,
                                 CalendarIntegration.importTextLimit + 1)
    }

    func testAddToCalendarDoesNotImportAnEventAlreadyThere() async throws {
        let h = try harness()
        try connect(h)
        let onCalendar = Flag()
        h.net.respond = { request, _ in
            if Fixture.isLookup(request), onCalendar.isSet { return (200, Fixture.inviteEventJSON, [:]) }
            if request.httpMethod == "POST" { return (500, "{}", [:]) }
            return (200, Fixture.empty, [:])
        }
        let findingsCheck = await h.integration.check(facts(), messageId: "m1", accountId: account)
        let findings = try XCTUnwrap(findingsCheck.findings)
        onCalendar.set()
        let updated = try await h.integration.addToCalendar(
            facts(), findings: findings, organizerIsSender: true, attendeeEmail: "a@x.com",
            messageId: "m1", accountId: account)
        XCTAssertEqual(updated.event?.eventId, "ev1")
        XCTAssertNil(h.net.requests.first { $0.httpMethod == "POST" }, "no second copy")
    }

    func testAddToCalendarRefusesAForwardedInvitation() async throws {
        let h = try harness()
        try connect(h)
        h.net.respond = { _, _ in (200, Fixture.empty, [:]) }
        let findingsCheck = await h.integration.check(facts(), messageId: "m1", accountId: account)
        let findings = try XCTUnwrap(findingsCheck.findings)
        do {
            _ = try await h.integration.addToCalendar(
                facts(), findings: findings, organizerIsSender: false, attendeeEmail: "a@x.com",
                messageId: "m1", accountId: account)
            XCTFail("the organizer is not the sender")
        } catch {}
        XCTAssertNil(h.net.requests.first { $0.httpMethod == "POST" })
    }

    // MARK: - The cache

    /// One message with two invitations: what is found for one is not used
    /// for the other.
    func testTwoInvitationsInOneMessageAreLookedUpSeparately() async throws {
        let h = try harness()
        try connect(h)
        h.net.respond = { request, _ in
            if Fixture.query(request, "iCalUID") == "abc123@google.com" {
                return (200, Fixture.inviteEventJSON, [:])
            }
            return (200, Fixture.empty, [:])
        }
        let first = await h.integration.check(facts(uid: "other@x.com"), messageId: "m1",
                                              accountId: account)
        let second = await h.integration.check(facts(), messageId: "m1", accountId: account)
        XCTAssertNil(first.findings?.event)
        XCTAssertEqual(second.findings?.event?.eventId, "ev1", "not the first one's miss")
    }

    /// Two messages for one event: after "Add to Calendar" on one, the other
    /// does not offer it again.
    func testTwoMessagesForOneEventShareWhatWasFound() async throws {
        let h = try harness()
        try connect(h)
        h.net.respond = { request, _ in
            if request.httpMethod == "POST" {
                return (200, #"{"id":"new1","iCalUID":"abc123@google.com"}"#, [:])
            }
            return (200, Fixture.empty, [:])
        }
        let findingsCheck = await h.integration.check(facts(), messageId: "m1", accountId: account)
        let findings = try XCTUnwrap(findingsCheck.findings)
        _ = try await h.integration.addToCalendar(
            facts(), findings: findings, organizerIsSender: true, attendeeEmail: "a@x.com",
            messageId: "m1", accountId: account)
        let otherCheck = await h.integration.check(facts(), messageId: "m2", accountId: account)
        let other = try XCTUnwrap(otherCheck.findings)
        XCTAssertEqual(other.event?.eventId, "new1")
        XCTAssertFalse(other.canAddToCalendar(facts(), organizerIsSender: true))
    }

    func testWhereTheEventIsIsCachedInMemoryForAWhile() async throws {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let h = try harness(now: { clock })
        try connect(h)
        h.net.respond = { _, _ in (200, Fixture.empty, [:]) }

        _ = await h.integration.check(facts(), messageId: "m1", accountId: account)
        XCTAssertEqual(lookups(h), 1)
        _ = await h.integration.check(facts(), messageId: "m1", accountId: account)
        XCTAssertEqual(lookups(h), 1, "a miss is remembered")
        clock = clock.addingTimeInterval(CalendarIntegration.locateCacheLifetime + 1)
        _ = await h.integration.check(facts(), messageId: "m1", accountId: account)
        XCTAssertEqual(lookups(h), 2, "and forgotten after its lifetime")
    }

    func testTheCacheIsClearedByANewChoiceAndBounded() async throws {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let h = try harness(now: { clock })
        try connect(h)
        await h.integration.load(accountId: account)
        h.net.respond = { _, _ in (200, Fixture.empty, [:]) }
        _ = await h.integration.check(facts(), messageId: "m1", accountId: account)
        XCTAssertEqual(h.integration.locatedCount, 1)
        try await h.integration.choose([GCalendarListEntry(id: account, summary: "Me", timeZone: nil,
                                                           primary: true, accessRole: "owner")],
                                       accountId: account)
        XCTAssertEqual(h.integration.locatedCount, 0)

        for index in 0..<(CalendarIntegration.locateCacheLimit + 20) {
            clock = clock.addingTimeInterval(0.001)
            _ = await h.integration.check(facts(uid: "uid-\(index)"), messageId: "m\(index)",
                                          accountId: account)
        }
        XCTAssertEqual(h.integration.locatedCount, CalendarIntegration.locateCacheLimit)
    }

    func testARateLimitPausesTheAccountsRequests() async throws {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let h = try harness(now: { clock })
        try connect(h)
        h.net.respond = { _, _ in (429, "{}", ["Retry-After": "30"]) }
        let first = await h.integration.check(facts(), messageId: "m1", accountId: account)
        guard case .failed = first else { return XCTFail("\(first)") }
        let sent = h.net.requests.count
        let paused = await h.integration.check(facts(), messageId: "m2", accountId: account)
        guard case .failed = paused else { return XCTFail("\(paused)") }
        do {
            _ = try await h.integration.calendarList(accountId: account)
            XCTFail("the list waits too")
        } catch {
            XCTAssertEqual(error as? CalendarError, .rateLimited(retryAfter: nil))
        }
        XCTAssertEqual(h.net.requests.count, sent, "nothing is sent while paused")
        clock = clock.addingTimeInterval(31)
        _ = await h.integration.check(facts(), messageId: "m2", accountId: account)
        XCTAssertGreaterThan(h.net.requests.count, sent)
    }

    // MARK: - Pure pieces

    func testAnswerNoteSaysWhereTheAnswerGoes() {
        XCTAssertEqual(CalendarAnswerNote.text(route: .emailOnly, accountId: account,
                                               from: "me@alias.com", organizer: "org@x.com"),
                       "Reply from me@alias.com goes to org@x.com")
        let both = CalendarAnswerNote.text(
            route: .calendarAndEmail(calendarId: "primary", eventId: "e"), accountId: account,
            from: "me@alias.com", organizer: "org@x.com")
        XCTAssertTrue(both.hasPrefix("Reply from me@alias.com goes to org@x.com"), both)
        XCTAssertTrue(both.contains("will also be saved in Google Calendar (a@x.com)"), both)
    }

    func testErrorsMapToTheCardStates() {
        var refused = false
        XCTAssertEqual(CalendarIntegration.check(for: CalendarError.notGranted(nil),
                                                 onRefusedGrant: { refused = true }), .needsConsent)
        XCTAssertTrue(refused)
        XCTAssertEqual(CalendarIntegration.check(for: URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(CalendarIntegration.check(for: CalendarError.switchedOff), .off)
        XCTAssertEqual(CalendarIntegration.check(for: CocoaError(.fileReadNoPermission)),
                       .failed("Google Calendar could not be checked."))
        guard case .failed = CalendarIntegration.check(for: CalendarError.rateLimited(retryAfter: nil))
        else { return XCTFail("rate limit is an error state") }
    }

    // MARK: - The UI only reaches Calendar behind the switch

    /// Outside the Calendar folder only the store's Calendar actions and two
    /// UI files use `CalendarIntegration`, and the UI's entry points sit
    /// behind `calendarUIEnabled`, which requires the build switch.
    func testCalendarUIIsBehindTheSwitch() throws {
        let sources = ForkIdentityTests.repoRoot.appendingPathComponent("Sources/MishMail")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        var users: Set<String> = []
        for url in files {
            let rel = String(url.path.dropFirst(sources.path.count + 1))
            guard !rel.hasPrefix("Calendar/") else { continue }
            if try String(contentsOf: url, encoding: .utf8).contains("CalendarIntegration") {
                users.insert(rel)
            }
        }
        XCTAssertEqual(users, ["App/MailStore+CalendarAccess.swift", "UI/CalendarInviteCard.swift",
                               "UI/CalendarAccountSettings.swift"])

        let access = try ForkIdentityTests.repoFile("Sources/MishMail/App/MailStore+CalendarAccess.swift")
        XCTAssertTrue(access.contains("CalendarFeatures.isEnabled && !demoMode"))
        let accounts = try ForkIdentityTests.repoFile("Sources/MishMail/App/MailStore+Accounts.swift")
        XCTAssertTrue(accounts.contains("forgetCalendar(accountId: id)"),
                      "account removal clears the integration's memory")

        func assertGated(_ path: String, _ call: String, file: StaticString = #filePath,
                         line: UInt = #line) throws {
            let lines = try ForkIdentityTests.repoFile(path).components(separatedBy: "\n")
            let uses = lines.indices.filter {
                lines[$0].contains(call) && !lines[$0].contains("func ")
            }
            XCTAssertFalse(uses.isEmpty, "\(path): \(call) not found", file: file, line: line)
            for index in uses {
                let before = lines[max(0, index - 3)..<index].joined(separator: "\n")
                XCTAssertTrue(before.contains("calendarUIEnabled"),
                              "\(path):\(index + 1) \(call) is not behind calendarUIEnabled",
                              file: file, line: line)
            }
        }
        try assertGated("Sources/MishMail/UI/SettingsView.swift", "CalendarAccountSettings(")
        try assertGated("Sources/MishMail/UI/CalendarInviteCard.swift", "calendarRow(invite)")
        try assertGated("Sources/MishMail/UI/CalendarInviteCard.swift",
                        "for invite in parsed.filter(\\.isActionable).prefix(Self.maxCheckedInvites)")
    }
}

/// Holds requests until `open`.
actor CalendarStubGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
