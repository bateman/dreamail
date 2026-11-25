import XCTest
import GRDB

/// Stub responses, outside the main-actor test class so the stub
/// transport's `@Sendable` closures can read them.
private enum Fixture {
    static let inviteEventJSON = """
        {"items":[{"id":"ev1","status":"confirmed","iCalUID":"abc123@google.com",
          "organizer":{"email":"org@x.com"},
          "attendees":[{"email":"a@x.com","self":true,"responseStatus":"needsAction"}],
          "start":{"dateTime":"2026-12-01T10:00:00Z"},"end":{"dateTime":"2026-12-01T11:00:00Z"}}]}
        """

    static func query(_ request: URLRequest, _ name: String) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }
}

private final class DeletedTokens: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    var accounts: [String] {
        lock.lock(); defer { lock.unlock() }
        return ids
    }
    func add(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        ids.append(id)
    }
}

/// `CalendarIntegration`, the one door the UI uses into the Calendar code:
/// the account states Settings shows, the invitation card's states
/// (not connected, consent refused, offline, error, not found, ready), the
/// answer's route and what is stored. Hostless: stub network, Keychain and
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

    private func harness(enabled: Bool = true,
                         transport: CalendarTransport? = nil) throws -> Harness {
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
            steps: steps.steps,
            transport: transport ?? net.transport,
            readRefreshToken: keychain.reader,
            refresh: { _ in ("access-not-real", 3600) },
            deleteRefreshToken: { deleted.add($0) })
        return Harness(integration: CalendarIntegration(dependencies: deps), db: db, net: net,
                       keychain: keychain, steps: steps, deleted: deleted)
    }

    /// A connected account whose only chosen calendar is its primary one.
    private func connect(_ h: Harness) throws {
        let account = self.account
        try h.db.write { db in
            try CalendarStore.saveGrant(
                db, accountId: account, scopes: CalendarScope.recommended.joined(separator: " "),
                at: Date(), calendars: [GCalendarListEntry(
                    id: account, summary: "Me", timeZone: "Europe/Rome", primary: true,
                    accessRole: "owner", selected: true)])
        }
    }

    private func facts(googleCalendarICS: Bool = true) -> CalendarInviteFacts {
        let start = ISO8601DateFormatter().date(from: "2026-12-01T10:00:00Z")!
        return CalendarInviteFacts(
            uid: googleUID, summary: "Review", organizerEmail: "org@x.com",
            span: CalendarSpan(start: start, end: start.addingTimeInterval(3600), isAllDay: false),
            organizerUsesGoogleCalendar: googleCalendarICS)
    }

    private func count(_ h: Harness, _ table: String) throws -> Int {
        try h.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") ?? -1 }
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
        let route = try await h.integration.respond(.accepted, facts: facts(), findings: nil,
                                                    accountId: account)
        XCTAssertEqual(route, .emailOnly)
        XCTAssertEqual(h.steps.calls, [], "no browser, no consent")
        XCTAssertEqual(h.net.requests.count, 0)
        XCTAssertEqual(h.keychain.reads, [])
    }

    // MARK: - Settings: connect, choose, disconnect

    func testConnectChoosesThePrimaryCalendarAndDisconnectForgetsEverything() async throws {
        let h = try harness()
        h.net.respond = { request, _ in
            request.url!.path.hasSuffix("/users/me/calendarList")
                ? (200, """
                    {"items":[{"id":"a@x.com","summary":"Me","primary":true,"accessRole":"owner"},
                              {"id":"team@group.calendar.google.com","summary":"Team","accessRole":"reader"}]}
                    """, [:])
                : (404, "{}", [:])
        }
        XCTAssertEqual(h.integration.status(for: account), .notConnected)

        try await h.integration.connect(accountId: account)
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

        try await h.integration.disconnect(accountId: account)
        XCTAssertEqual(h.integration.status(for: account), .notConnected)
        XCTAssertEqual(h.deleted.accounts, [account])
        XCTAssertEqual(try count(h, "calendarGrant"), 0)
        XCTAssertEqual(try count(h, "calendarSource"), 0)
        XCTAssertEqual(try count(h, "calendarInviteEvent"), 0)
    }

    // MARK: - Invitation card

    func testCheckFindsTheEventAndAvailabilityAndStoresNothing() async throws {
        let h = try harness()
        try connect(h)
        h.net.respond = { request, _ in
            if Fixture.query(request, "iCalUID") != nil { return (200, Fixture.inviteEventJSON, [:]) }
            // The window around the invitation: only the invitation itself.
            return (200, Fixture.inviteEventJSON, [:])
        }
        let check = await h.integration.check(facts(), messageId: "m1", accountId: account)
        let findings = try XCTUnwrap(check.findings, "\(check)")
        XCTAssertEqual(findings.event?.eventId, "ev1")
        XCTAssertEqual(findings.event?.calendarId, "primary")
        XCTAssertEqual(findings.availability?.isFree, true, "the invitation is not its own conflict")
        XCTAssertEqual(findings.route(for: facts()),
                       .calendarOnly(calendarId: "primary", eventId: "ev1"))
        XCTAssertFalse(findings.canAddToCalendar(facts()))
        XCTAssertEqual(try count(h, "calendarInviteEvent"), 0, "the card keeps it in memory only")
    }

    func testAConflictOnAChosenCalendarIsReported() async throws {
        let h = try harness()
        try connect(h)
        h.net.respond = { request, _ in
            if Fixture.query(request, "iCalUID") != nil { return (200, #"{"items":[]}"#, [:]) }
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
        XCTAssertTrue(findings.canAddToCalendar(facts()))
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

    // MARK: - Answering

    func testAnswerOnTheCalendarSendsNoEmailAndAsksGoogleForNone() async throws {
        let h = try harness()
        try connect(h)
        h.net.respond = { request, _ in
            if request.httpMethod == "GET", Fixture.query(request, "fields") == "attendees" {
                return (200, #"{"attendees":[{"email":"a@x.com","self":true,"responseStatus":"needsAction"}]}"#, [:])
            }
            if Fixture.query(request, "iCalUID") != nil || request.httpMethod == "GET" {
                return (200, Fixture.inviteEventJSON, [:])
            }
            return (200, "{}", [:])
        }
        let findings = await h.integration.check(facts(), messageId: "m1", accountId: account).findings
        let route = try await h.integration.respond(.accepted, facts: facts(), findings: findings,
                                                    accountId: account)
        XCTAssertEqual(route, .calendarOnly(calendarId: "primary", eventId: "ev1"))
        XCTAssertFalse(route.sendsEmail)
        let patch = try XCTUnwrap(h.net.requests.first { $0.httpMethod == "PATCH" })
        XCTAssertEqual(Fixture.query(patch, "sendUpdates"), "none")
    }

    func testAnswerGoesByEmailWhenTheUserIsNotAGuestOfTheCalendarEvent() async throws {
        let h = try harness()
        try connect(h)
        h.net.respond = { request, _ in
            if Fixture.query(request, "fields") == "attendees" {
                return (200, #"{"attendees":[{"email":"someone@x.com"}]}"#, [:])
            }
            return (200, Fixture.inviteEventJSON, [:])
        }
        let findings = await h.integration.check(facts(), messageId: "m1", accountId: account).findings
        let route = try await h.integration.respond(.declined, facts: facts(), findings: findings,
                                                    accountId: account)
        XCTAssertEqual(route, .emailOnly)
        XCTAssertNil(h.net.requests.first { $0.httpMethod == "PATCH" })
    }

    func testWithoutACheckTheAnswerGoesByEmailAsBefore() async throws {
        let h = try harness()
        try connect(h)
        let route = try await h.integration.respond(.accepted, facts: facts(), findings: nil,
                                                    accountId: account)
        XCTAssertEqual(route, .emailOnly)
        var unanswerable = facts()
        unanswerable.isAnswerable = false
        let none = try await h.integration.respond(.accepted, facts: unanswerable, findings: nil,
                                                   accountId: account)
        XCTAssertEqual(none, .notAnswerable)
        XCTAssertEqual(h.net.requests.count, 0)
    }

    func testAddToCalendarImportsOnThePrimaryCalendar() async throws {
        let h = try harness()
        try connect(h)
        h.net.respond = { request, _ in
            if request.httpMethod == "POST" {
                return (200, #"{"id":"new1","iCalUID":"abc123@google.com"}"#, [:])
            }
            return (200, #"{"items":[]}"#, [:])
        }
        let check = await h.integration.check(facts(), messageId: "m1", accountId: account)
        let findings = try XCTUnwrap(check.findings, "\(check)")
        let updated = try await h.integration.addToCalendar(facts(), findings: findings,
                                                            messageId: "m1", accountId: account)
        XCTAssertEqual(updated.event?.eventId, "new1")
        let post = try XCTUnwrap(h.net.requests.first { $0.httpMethod == "POST" })
        XCTAssertTrue(post.url!.path.hasSuffix("/calendars/primary/events/import"), post.url!.path)
        XCTAssertEqual(try count(h, "calendarInviteEvent"), 0)
    }

    // MARK: - Pure pieces

    func testAnswerNoteSaysWhereTheAnswerGoes() {
        XCTAssertEqual(CalendarAnswerNote.text(route: .emailOnly, accountId: account,
                                               from: "me@alias.com", organizer: "org@x.com"),
                       "Reply from me@alias.com goes to org@x.com")
        let calendarOnly = CalendarAnswerNote.text(
            route: .calendarOnly(calendarId: "primary", eventId: "e"), accountId: account,
            from: "me@alias.com", organizer: "org@x.com")
        XCTAssertTrue(calendarOnly.contains("Google Calendar (a@x.com)"), calendarOnly)
        XCTAssertTrue(calendarOnly.contains("No e-mail is sent"), calendarOnly)
        XCTAssertFalse(calendarOnly.contains("me@alias.com"), "no e-mail goes from the alias")
        let both = CalendarAnswerNote.text(
            route: .calendarAndEmail(calendarId: "primary", eventId: "e"), accountId: account,
            from: "me@alias.com", organizer: "org@x.com")
        XCTAssertTrue(both.contains("Google Calendar"), both)
        XCTAssertTrue(both.contains("reply from me@alias.com goes to org@x.com"), both)
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
                        "for invite in parsed where invite.isActionable")
    }
}
