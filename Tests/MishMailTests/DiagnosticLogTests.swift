import XCTest

final class DiagnosticLogTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-\(UUID().uuidString)/diagnostics.log")
    }

    private func permissions(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    // MARK: - Redaction

    func testFormatKeepsStatusPathAndReasonButNotTheAddress() {
        let body = #"{"error":{"code":403,"errors":[{"reason":"accessNotConfigured"}]}}"#
        let line = DiagnosticLog.format(account: "a@b.com", method: "GET",
                                        path: "/history", code: 403, body: body, salt: "s")
        XCTAssertFalse(line.contains("a@b.com"))
        XCTAssertFalse(line.contains("@"))
        XCTAssertTrue(line.contains("account=acct-"))
        XCTAssertTrue(line.contains("GET /history status=403"))
        XCTAssertTrue(line.contains("reason=accessNotConfigured"))
    }

    func testAccountTagIsStableSaltedAndCaseInsensitive() {
        let tag = DiagnosticLog.accountTag("Someone@Example.com", salt: "s1")
        XCTAssertEqual(tag, DiagnosticLog.accountTag("someone@example.com", salt: "s1"))
        XCTAssertNotEqual(tag, DiagnosticLog.accountTag("someone@example.com", salt: "s2"))
        XCTAssertNotEqual(tag, DiagnosticLog.accountTag("other@example.com", salt: "s1"))
        XCTAssertTrue(tag.hasPrefix("acct-"))
        XCTAssertEqual(tag.count, "acct-".count + 8)
        XCTAssertFalse(tag.lowercased().contains("someone"))
    }

    func testRawBodyTextNeverReachesTheLine() {
        // Google can echo request content (a search query, a label name, an
        // address) in `message`; only the machine-readable tokens survive.
        let body = #"""
        {"error":{"code":400,"message":"Invalid query: from:secret.person@example.com subject:Payroll",
        "status":"INVALID_ARGUMENT","errors":[{"reason":"invalidArgument","domain":"global",
        "message":"Invalid query: from:secret.person@example.com"}],
        "details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"SERVICE_DISABLED"}]}}
        """#
        let line = DiagnosticLog.format(account: "me@example.com", method: "GET",
                                        path: "/messages", code: 400, body: body, salt: "s")
        for leaked in ["secret.person", "Payroll", "Invalid query", "@", "me@example.com"] {
            XCTAssertFalse(line.contains(leaked), "leaked \(leaked): \(line)")
        }
        XCTAssertTrue(line.contains("reason=invalidArgument,SERVICE_DISABLED"))
        XCTAssertTrue(line.contains("gstatus=INVALID_ARGUMENT"))
        XCTAssertTrue(line.contains("body-bytes=\(body.utf8.count)"))
    }

    func testNonJSONAndFreeTextReasonsAreDropped() {
        let html = "<html><body>Server Error for user a@b.com\nline two</body></html>"
        let line = DiagnosticLog.categorize(body: html)
        XCTAssertEqual(line, "body-bytes=\(html.utf8.count)")

        let oauth = #"{"error":"invalid token for a@b.com","error_description":"Bad"}"#
        XCTAssertEqual(DiagnosticLog.categorize(body: oauth), "body-bytes=\(oauth.utf8.count)")

        let oauthToken = #"{"error":"invalid_grant","error_description":"Token has been expired"}"#
        let tokenLine = DiagnosticLog.categorize(body: oauthToken)
        XCTAssertTrue(tokenLine.contains("reason=invalid_grant"))
        XCTAssertFalse(tokenLine.contains("expired"))
    }

    func testRetryAfterSuffixIsKeptWithoutTheBody() {
        let body = #"{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","message":"quota for me@x.com"}}"#
            + "\nRetry-After: 30"
        let line = DiagnosticLog.format(account: "me@x.com", method: "POST", path: "/batch",
                                        code: 429, body: body, note: .batchRequest(ids: 25),
                                        salt: "s")
        XCTAssertTrue(line.contains("POST /batch status=429 batch-ids=25"))
        XCTAssertTrue(line.contains("gstatus=RESOURCE_EXHAUSTED"))
        XCTAssertTrue(line.contains("retry-after=30"))
        XCTAssertFalse(line.contains("quota"))
        XCTAssertFalse(line.contains("@"))
    }

    func testEndpointsAreParameterized() {
        XCTAssertEqual(DiagnosticLog.parameterize("/messages/18c2f0a9b7d1e3f4"), "/messages/{id}")
        XCTAssertEqual(DiagnosticLog.parameterize("/messages/abc/attachments/ANGjdJ9x_long"),
                       "/messages/{id}/attachments/{id}")
        XCTAssertEqual(DiagnosticLog.parameterize("/threads/abc/modify"), "/threads/{id}/modify")
        XCTAssertEqual(DiagnosticLog.parameterize("/labels/Label_42"), "/labels/{id}")
        XCTAssertEqual(DiagnosticLog.parameterize("/messages?q=from:a@b.com"), "/messages")
        XCTAssertEqual(DiagnosticLog.parameterize("/oauth2/v2/userinfo"), "/oauth2/v2/userinfo")
        XCTAssertEqual(DiagnosticLog.parameterize("/settings/sendAs/a@b.com"), "/settings/sendAs/{id}")
        let line = DiagnosticLog.format(account: "a@b.com", method: "GET",
                                        path: "/messages/18c2f0a9b7d1e3f4", code: 500, body: "",
                                        note: .batchPart(failing: 3, total: 25), salt: "s")
        XCTAssertFalse(line.contains("18c2f0a9b7d1e3f4"))
        XCTAssertTrue(line.contains("GET /messages/{id} status=500 batch-part=3/25"))
    }

    func testDescribeKeepsCategoryButNotTheGmailBody() {
        let body = String(repeating: "r", count: 900)
        let text = DiagnosticLog.describe(GmailError.http(403, body))
        XCTAssertTrue(text.contains("http=403"))
        XCTAssertFalse(text.contains("rrrr"))
        XCTAssertTrue(text.contains("body-bytes=900"))
    }

    func testDescribeDropsAddressesFromOtherErrors() {
        let noToken = DiagnosticLog.describe(GmailError.noRefreshToken("me@example.com"))
        XCTAssertEqual(noToken, "error=noRefreshToken")
        let keychain = DiagnosticLog.describe(GmailError.keychainUnavailable("me@example.com", -25308))
        XCTAssertEqual(keychain, "error=keychainUnavailable status=-25308")

        struct Leaky: LocalizedError {
            var errorDescription: String? { "failed for me@example.com" }
        }
        let leaky = DiagnosticLog.describe(Leaky())
        XCTAssertFalse(leaky.contains("@"))
        XCTAssertTrue(leaky.hasPrefix("error="))

        let url = DiagnosticLog.describe(URLError(.notConnectedToInternet))
        XCTAssertTrue(url.contains("domain=NSURLErrorDomain"))
        XCTAssertTrue(url.contains("code=\(URLError.Code.notConnectedToInternet.rawValue)"))
    }

    // MARK: - File sink

    func testAppendCreatesPrivateDirectoryAndFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        DiagnosticLog.append("first", to: url, now: Date())
        XCTAssertEqual(try permissions(url.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try permissions(url), 0o600)
    }

    func testAppendTightensAnExistingWideDirectory() throws {
        let url = tempURL()
        let dir = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        DiagnosticLog.append("first", to: url, now: Date())
        XCTAssertEqual(try permissions(dir), 0o700)
    }

    func testAppendCreatesDirectoryAndRotates() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        DiagnosticLog.append("first", to: url, now: Date())
        DiagnosticLog.append("second", to: url, now: Date())
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix(DiagnosticLog.headerPrefix))

        let big = DiagnosticLog.header(created: Date()) + "\n"
            + String(repeating: "y", count: DiagnosticLog.maxBytes + 10)
        try big.write(to: url, atomically: true, encoding: .utf8)
        DiagnosticLog.append("after-rotate", to: url, now: Date())
        let rotated = url.appendingPathExtension("1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path))
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("after-rotate"))
        XCTAssertEqual(try permissions(url), 0o600)
        XCTAssertEqual(try permissions(rotated), 0o600)
    }

    func testLiveFileIsRotatedOnceOlderThanMaxAge() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let now = Date()
        DiagnosticLog.append("old-line", to: url, now: now.addingTimeInterval(-DiagnosticLog.maxAge - 60))
        DiagnosticLog.append("new-line", to: url, now: now)
        let live = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(live.contains("old-line"))
        XCTAssertTrue(live.contains("new-line"))
    }

    func testRotatedFileIsDeletedOnceOlderThanMaxAge() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rotated = url.appendingPathExtension("1")
        DiagnosticLog.append("first", to: url, now: Date())
        let stalePrefix = DiagnosticLog.header(created: Date().addingTimeInterval(-2 * DiagnosticLog.maxAge))
        try Data((stalePrefix + "\nstale\n").utf8).write(to: rotated)
        let stale = Date().addingTimeInterval(-DiagnosticLog.maxAge - 60)
        try FileManager.default.setAttributes([.modificationDate: stale], ofItemAtPath: rotated.path)
        DiagnosticLog.append("second", to: url, now: Date())
        XCTAssertFalse(FileManager.default.fileExists(atPath: rotated.path))
    }

    func testLegacyUnredactedFilesArePurged() throws {
        let url = tempURL()
        let fm = FileManager.default
        defer { try? fm.removeItem(at: url.deletingLastPathComponent()) }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy = "2026-11-01T00:00:00Z GMAIL-HTTP account=me@example.com GET /history status=403 body={...}\n"
        try legacy.write(to: url, atomically: true, encoding: .utf8)
        try legacy.write(to: url.appendingPathExtension("1"), atomically: true, encoding: .utf8)

        DiagnosticLog.append("fresh", to: url, now: Date())
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("me@example.com"))
        XCTAssertTrue(text.contains("fresh"))
        XCTAssertFalse(fm.fileExists(atPath: url.appendingPathExtension("1").path))
    }

    // MARK: - Maintenance without a new error

    func testLaunchMaintenancePurgesLegacyFilesWithoutAnAppend() throws {
        let url = tempURL()
        let fm = FileManager.default
        defer { try? fm.removeItem(at: url.deletingLastPathComponent()) }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o755])
        let legacy = "2026-11-01T00:00:00Z GMAIL-HTTP account=me@example.com body={...}\n"
        try legacy.write(to: url, atomically: true, encoding: .utf8)
        try legacy.write(to: url.appendingPathExtension("1"), atomically: true, encoding: .utf8)

        XCTAssertTrue(DiagnosticLog.maintain(url: url, now: Date()))
        XCTAssertFalse(fm.fileExists(atPath: url.path))
        XCTAssertFalse(fm.fileExists(atPath: url.appendingPathExtension("1").path))
        XCTAssertEqual(try permissions(url.deletingLastPathComponent()), 0o700)
    }

    func testHeaderlessRotatedFileAloneIsPurged() throws {
        let url = tempURL()
        let fm = FileManager.default
        defer { try? fm.removeItem(at: url.deletingLastPathComponent()) }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rotated = url.appendingPathExtension("1")
        try "account=me@example.com\n".write(to: rotated, atomically: true, encoding: .utf8)

        DiagnosticLog.maintain(url: url, now: Date())
        XCTAssertFalse(fm.fileExists(atPath: rotated.path))
    }

    func testMaintenanceAgesOutTheLiveFileWithoutAnAppend() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let now = Date()
        DiagnosticLog.append("old-line", to: url, now: now.addingTimeInterval(-DiagnosticLog.maxAge - 60))
        DiagnosticLog.maintain(url: url, now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(try String(contentsOf: url.appendingPathExtension("1"), encoding: .utf8)
            .contains("old-line"))
    }

    // MARK: - Symlinks and hard links

    func testSymlinkAtTheLogPathIsNeverFollowed() throws {
        let url = tempURL()
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let elsewhere = fm.temporaryDirectory.appendingPathComponent("diag-target-\(UUID().uuidString)")
        defer {
            try? fm.removeItem(at: dir)
            try? fm.removeItem(at: elsewhere)
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try "victim\n".write(to: elsewhere, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: elsewhere.path)
        try fm.createSymbolicLink(at: url, withDestinationURL: elsewhere)

        DiagnosticLog.append("fresh", to: url, now: Date())
        XCTAssertEqual(try String(contentsOf: elsewhere, encoding: .utf8), "victim\n")
        XCTAssertEqual(try permissions(elsewhere), 0o644)
        XCTAssertThrowsError(try fm.destinationOfSymbolicLink(atPath: url.path))
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("fresh"))
    }

    func testSymlinkAtTheRotatedPathIsUnlinkedNotItsTarget() throws {
        let url = tempURL()
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let elsewhere = fm.temporaryDirectory.appendingPathComponent("diag-dir-\(UUID().uuidString)")
        defer {
            try? fm.removeItem(at: dir)
            try? fm.removeItem(at: elsewhere)
        }
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let precious = elsewhere.appendingPathComponent("keep.txt")
        try "keep".write(to: precious, atomically: true, encoding: .utf8)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: url.appendingPathExtension("1"), withDestinationURL: elsewhere)

        DiagnosticLog.append("fresh", to: url, now: Date())
        XCTAssertTrue(fm.fileExists(atPath: precious.path))
        XCTAssertThrowsError(try fm.destinationOfSymbolicLink(
            atPath: url.appendingPathExtension("1").path))
    }

    func testHardLinkedLogFileIsNotWritten() throws {
        let url = tempURL()
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let elsewhere = fm.temporaryDirectory.appendingPathComponent("diag-hard-\(UUID().uuidString)")
        defer {
            try? fm.removeItem(at: dir)
            try? fm.removeItem(at: elsewhere)
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = DiagnosticLog.header(created: Date()) + "\n"
        try original.write(to: elsewhere, atomically: true, encoding: .utf8)
        try fm.linkItem(at: elsewhere, to: url)

        DiagnosticLog.append("fresh", to: url, now: Date())
        XCTAssertEqual(try String(contentsOf: elsewhere, encoding: .utf8), original)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("fresh"))
    }

    // MARK: - Debuggability kept

    func testDecodingErrorKeepsCaseAndCodingPath() {
        struct Payload: Decodable { let messages: [Item] }
        struct Item: Decodable { let id: String; let threadId: String }
        let json = Data(#"{"messages":[{"id":"a","threadId":"b"},{"id":"secret@example.com"}]}"#.utf8)
        do {
            _ = try JSONDecoder().decode(Payload.self, from: json)
            XCTFail("expected a decoding error")
        } catch {
            let text = DiagnosticLog.describe(error)
            XCTAssertEqual(text, "error=DecodingError case=keyNotFound path=messages.1.threadId")
        }
        let mismatch = DiagnosticLog.describe(DecodingError.typeMismatch(
            Int.self, .init(codingPath: [], debugDescription: "found me@example.com")))
        XCTAssertEqual(mismatch, "error=DecodingError case=typeMismatch path=-")
    }

    func testTokensRejectLongAndHexLookingValues() {
        XCTAssertEqual(DiagnosticLog.token("rateLimitExceeded"), "rateLimitExceeded")
        XCTAssertEqual(DiagnosticLog.token("NSURLErrorDomain"), "NSURLErrorDomain")
        XCTAssertNil(DiagnosticLog.token("18c2f0a9b7d1e3f4"))
        XCTAssertNil(DiagnosticLog.token(String(repeating: "a", count: DiagnosticLog.maxTokenLength + 1)))
        XCTAssertNil(DiagnosticLog.token("has space"))
        XCTAssertNil(DiagnosticLog.token("a@b.com"))
        let body = #"{"error":{"errors":[{"reason":"18c2f0a9b7d1e3f4"},{"reason":"backendError"}]}}"#
        XCTAssertTrue(DiagnosticLog.categorize(body: body).hasPrefix("reason=backendError "))
    }
}
