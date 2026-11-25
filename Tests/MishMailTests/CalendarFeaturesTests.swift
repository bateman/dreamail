import XCTest

/// The build-time switch that keeps the Google Calendar integration off
/// (`CalendarFeatures`). With it off, nothing reaches the Calendar API, no
/// Calendar scope is asked for, and no Calendar token is read or refreshed.
final class CalendarFeaturesTests: XCTestCase {

    // MARK: - The value and the tracked configuration

    func testOnlyAnExplicitYesTurnsCalendarOn() {
        XCTAssertFalse(CalendarFeatures.configured(in: nil))
        XCTAssertFalse(CalendarFeatures.configured(in: [:]))
        XCTAssertFalse(CalendarFeatures.configured(in: [CalendarFeatures.infoKey: ""]))
        XCTAssertFalse(CalendarFeatures.configured(in: [CalendarFeatures.infoKey: "$(MISHMAIL_CALENDAR)"]))
        XCTAssertFalse(CalendarFeatures.configured(in: [CalendarFeatures.infoKey: 1]))
        XCTAssertTrue(CalendarFeatures.configured(in: [CalendarFeatures.infoKey: "YES"]))
        XCTAssertFalse(CalendarFeatures.isEnabled, "the test bundle is built from the tracked config")
    }

    func testTrackedConfigurationShipsWithCalendarOff() throws {
        let plistData = try Data(contentsOf: ForkIdentityTests.repoRoot
            .appendingPathComponent("Sources/MishMail/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: plistData, format: nil) as? [String: Any])
        XCTAssertEqual(plist[CalendarFeatures.infoKey] as? String, "$(MISHMAIL_CALENDAR)")

        let xcconfig = try ForkIdentityTests.repoFile("Config/Signing.xcconfig")
        let lines = xcconfig.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let assignments = lines.filter { !$0.hasPrefix("//") && $0.hasPrefix("MISHMAIL_CALENDAR") }
        XCTAssertEqual(assignments, ["MISHMAIL_CALENDAR ="])
        let assignment = try XCTUnwrap(lines.firstIndex(of: "MISHMAIL_CALENDAR ="))
        let include = try XCTUnwrap(lines.firstIndex(of: "#include? \"Local.xcconfig\""))
        XCTAssertLessThan(assignment, include, "Local.xcconfig must be able to override it")
        XCTAssertFalse(try ForkIdentityTests.repoFile("project.yml").contains("MISHMAIL_CALENDAR"))
    }

    /// Like the AI switch: install and release pass the tracked value on the
    /// command line and check the built app before shipping it.
    func testInstallAndReleaseTakeTheSwitchFromTheTrackedConfigurationOnly() throws {
        let makefile = try ForkIdentityTests.repoFile("Makefile")
        XCTAssertTrue(makefile.contains(
            "TRACKED_CALENDAR := $(shell awk -F= '/^[ \\t]*MISHMAIL_CALENDAR[ \\t]*=/"))
        XCTAssertTrue(makefile.contains("SHIP_CALENDAR_FLAGS = MISHMAIL_CALENDAR=$(TRACKED_CALENDAR)\n"))
        XCTAssertTrue(makefile.contains(
            "plutil -extract MishMailCalendar raw \"$(1)/Contents/Info.plist\""))

        func recipe(_ target: String) throws -> String {
            let start = try XCTUnwrap(makefile.range(of: "\n\(target):"), target)
            let rest = makefile[start.upperBound...]
            let end = rest.range(of: "\n\n")?.lowerBound ?? rest.endIndex
            return String(rest[..<end])
        }
        for (target, app) in [("install", "RELEASE_APP"), ("release", "SHIP_APP")] {
            let body = try recipe(target)
            let builds = body.components(separatedBy: "xcodebuild build").dropFirst()
            XCTAssertFalse(builds.isEmpty, target)
            for build in builds {
                let command = build.components(separatedBy: "\n")
                    .prefix { !$0.contains("$(call") && !$0.hasPrefix("\telse") && !$0.hasPrefix("\tfi") }
                    .joined(separator: "\n")
                XCTAssertTrue(command.contains("$(SHIP_CALENDAR_FLAGS)"), "\(target): \(command)")
            }
            let check = try XCTUnwrap(body.range(of: "$(call check_calendar_switch,$(\(app)))"),
                                      "\(target) does not check the built app")
            let ship = target == "install" ? "ditto \"$(RELEASE_APP)\" /Applications" : "gh release create"
            let shipAt = try XCTUnwrap(body.range(of: ship), target)
            XCTAssertLessThan(check.lowerBound, shipAt.lowerBound, "\(target) checks after shipping")
        }
    }

    // MARK: - No new scope in the default sign-in

    func testDefaultSignInAsksForNoCalendarScope() {
        XCTAssertFalse(OAuthConfig.scopes.contains { $0.contains("calendar") }, "\(OAuthConfig.scopes)")
    }

    /// Calendar code is reachable only through the Calendar folder, the
    /// migration that creates its tables and the account removal that
    /// deletes its token. No UI file refers to it.
    func testNothingOutsideTheCalendarFolderUsesTheCalendarAPI() throws {
        let sources = ForkIdentityTests.repoRoot.appendingPathComponent("Sources/MishMail")
        let names = ["CalendarClient", "CalendarTransport", "CalendarAuthorization",
                     "CalendarTokenSource", "CalendarStore", "googleapis.com/calendar"]
        let allowed: [String: Set<String>] = [
            "Store/Database.swift": ["CalendarStore"],
            "App/MailStore+Accounts.swift": ["CalendarAuthorization"],
            "Auth/OAuth.swift": ["CalendarAuthorization"],
            "Support/AccountLifecycle.swift": ["CalendarStore"],
        ]
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        for url in files {
            let rel = String(url.path.dropFirst(sources.path.count + 1))
            guard !rel.hasPrefix("Calendar/") else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for name in names where text.contains(name) {
                XCTAssertTrue(allowed[rel]?.contains(name) == true, "\(rel) uses \(name)")
            }
        }
    }

    /// I1: the switch is a default argument of the gated types; nothing
    /// outside the Calendar folder may pass its own value, and the raw
    /// session is private.
    func testNoCallerOutsideCalendarOverridesTheSwitch() throws {
        let sources = ForkIdentityTests.repoRoot.appendingPathComponent("Sources/MishMail")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        for url in files where !url.path.contains("/Sources/MishMail/Calendar/") {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n") where line.contains("Calendar") {
                XCTAssertFalse(line.contains("enabled:"), "\(url.lastPathComponent): \(line)")
                XCTAssertFalse(line.contains("CalendarAuthorization.request"), "\(url.lastPathComponent)")
                XCTAssertFalse(line.contains(".gated("), "\(url.lastPathComponent)")
            }
        }
        let client = try ForkIdentityTests.repoFile("Sources/MishMail/Calendar/CalendarClient.swift")
        XCTAssertTrue(client.contains("    private static let session = CalendarTransport"))
        XCTAssertTrue(client.contains("    static let live = gated(enabled: CalendarFeatures.isEnabled, session)"))
    }

    // MARK: - Zero requests with the switch off

    func testGatedTransportSendsNothingWhenOff() async {
        let net = CalendarStubTransport()
        let off = CalendarTransport.gated(enabled: false, net.transport)
        let request = URLRequest(url: URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!)
        await assertSwitchedOff { _ = try await off.data(request) }
        XCTAssertEqual(net.requests.count, 0)
        let on = CalendarTransport.gated(enabled: true, net.transport)
        _ = try? await on.data(request)
        XCTAssertEqual(net.requests.count, 1)
    }

    /// Every client call, with every scope granted, sends nothing and reads
    /// no stored token when the build has Calendar off.
    func testSwitchedOffClientSendsNothingAndReadsNoToken() async {
        let net = CalendarStubTransport()
        let keychain = CalendarStubKeychain()
        let tokens = CalendarTokenSource(accountId: "a@x.com", enabled: false,
                                         readRefreshToken: keychain.reader,
                                         refresh: { _ in XCTFail("no refresh"); return ("t", 3600) })
        let client = CalendarClient(
            grant: CalendarGrant(scopes: Set(CalendarScope.recommended)),
            tokens: tokens, transport: .gated(enabled: false, net.transport))
        let window = DateInterval(start: Date(timeIntervalSince1970: 0), duration: 3600)
        await assertSwitchedOff { _ = try await client.calendars() }
        await assertSwitchedOff { _ = try await client.events(calendarId: "primary", in: window) }
        await assertSwitchedOff { _ = try await client.events(calendarId: "primary", iCalUID: "u@x") }
        await assertSwitchedOff { _ = try await client.freeBusy(calendarIds: ["primary"], in: window) }
        await assertSwitchedOff {
            try await client.respond(calendarId: "primary", eventId: "e1", response: .accepted)
        }
        XCTAssertEqual(net.requests.count, 0)
        XCTAssertEqual(keychain.reads, [])
    }

    func testSwitchedOffAuthorizationOpensNoBrowserAndStoresNothing() async {
        let steps = CalendarStubSteps()
        await assertSwitchedOff {
            _ = try await CalendarAuthorization.request(accountId: "a@x.com", enabled: false,
                                                        steps: steps.steps)
        }
        XCTAssertEqual(steps.calls, [])
    }

    private func assertSwitchedOff(file: StaticString = #filePath, line: UInt = #line,
                                   _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected the Calendar switch to refuse", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? CalendarError, .switchedOff, file: file, line: line)
        }
    }
}

// MARK: - Test doubles

/// Stands in for the network under `CalendarClient` and records every
/// request. `respond` answers each request; by default an empty 200.
final class CalendarStubTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    var respond: @Sendable (URLRequest, Int) -> (Int, String, [String: String]) = { _, _ in (200, "{}", [:]) }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    /// Synchronous: NSLock is not available from async contexts.
    private func record(_ request: URLRequest) -> Int {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
        return recorded.count - 1
    }

    var transport: CalendarTransport {
        CalendarTransport { [self] request in
            let index = record(request)
            let (status, body, headers) = respond(request, index)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: nil, headerFields: headers)!
            return (Data(body.utf8), response)
        }
    }
}

/// A Keychain stand-in that records which keys were read.
final class CalendarStubKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var readKeys: [String] = []
    var value: KeychainReadResult = .value("refresh-not-real")

    var reads: [String] {
        lock.lock(); defer { lock.unlock() }
        return readKeys
    }

    var reader: CalendarTokenSource.ReadRefreshToken {
        { [self] key in
            lock.lock(); defer { lock.unlock() }
            readKeys.append(key)
            return value
        }
    }
}

/// The Calendar sign-in steps, recorded.
final class CalendarStubSteps: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var email = "a@x.com"
    var grantedScopes: String? = CalendarScope.recommended.joined(separator: " ")
    var askedScopes: [String] = []
    var savedFor: [String] = []

    var calls: [String] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    private func note(_ s: String, asked: [String]? = nil) {
        lock.lock(); defer { lock.unlock() }
        log.append(s)
        if let asked { askedScopes = asked }
    }

    var steps: CalendarAuthorization.Steps {
        CalendarAuthorization.Steps(
            authorize: { [self] scopes, hint in
                note("authorize:\(hint)", asked: scopes)
                return .init(refreshToken: "r", accessToken: "a", grantedScopes: grantedScopes)
            },
            signedInEmail: { [self] _ in
                note("userinfo")
                return email
            },
            saveRefreshToken: { [self] _, account in
                note("save:\(account)")
                lock.lock(); savedFor.append(account); lock.unlock()
            })
    }
}
