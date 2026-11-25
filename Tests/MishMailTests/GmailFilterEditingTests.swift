import XCTest
import GRDB

/// Step 3A: Gmail filters created, edited and deleted from Settings. The
/// client runs over a stub URLProtocol; the editor model, cache and local
/// preview are pure.
final class GmailFilterEditingTests: XCTestCase {

    // MARK: - Client over a stub transport

    private var client: GmailClient!
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        FilterStubProtocol.state.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FilterStubProtocol.self]
        session = URLSession(configuration: config)
        client = GmailClient(accountEmail: "ada@example.com",
                             testSession: session, testAccessToken: "test-token")
    }

    override func tearDown() {
        session.invalidateAndCancel()
        FilterStubProtocol.state.reset()
        super.tearDown()
    }

    private let filtersURL = "https://gmail.googleapis.com/gmail/v1/users/me/settings/filters"

    private let createdJSON = """
    {"id":"NEW1","criteria":{"from":"news@example.com"},"action":{"removeLabelIds":["INBOX"]}}
    """

    private let original = GFilter(
        id: "OLD1",
        criteria: .init(from: "news@example.com", to: nil, subject: nil, query: nil,
                        negatedQuery: nil, hasAttachment: nil, size: nil, sizeComparison: nil),
        action: .init(addLabelIds: ["STARRED"], removeLabelIds: nil, forward: nil))

    private var newBody: GFilter.Body {
        var draft = GmailFilterDraft(original)
        draft.star = false
        draft.skipInbox = true
        return draft.body
    }

    func testListSendsTheBearerTokenAndDecodesFilters() async throws {
        FilterStubProtocol.state.replies = [
            .init(method: "GET", url: filtersURL, status: 200, body: """
            {"filter":[{"id":"F1","criteria":{"from":"a@b.com","size":1048576,\
            "sizeComparison":"larger","excludeChats":true},"action":{"addLabelIds":["Label_7"]}}]}
            """),
        ]
        let filters = try await client.listFilters()
        XCTAssertEqual(filters.map(\.id), ["F1"])
        XCTAssertEqual(filters.first?.criteria?.excludeChats, true)
        XCTAssertEqual(filters.first?.criteria?.size, 1_048_576)
        let request = try XCTUnwrap(FilterStubProtocol.state.seen.first)
        XCTAssertEqual(request.headers["Authorization"], "Bearer test-token")
    }

    func testCreatePostsOnlyCriteriaAndAction() async throws {
        FilterStubProtocol.state.replies = [
            .init(method: "POST", url: filtersURL, status: 200, body: createdJSON),
        ]
        let created = try await client.createFilter(newBody)
        XCTAssertEqual(created.id, "NEW1")

        let request = try XCTUnwrap(FilterStubProtocol.state.seen.first)
        XCTAssertEqual(request.method, "POST")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["criteria", "action"])
        XCTAssertEqual(json["criteria"] as? [String: String], ["from": "news@example.com"])
        XCTAssertEqual((json["action"] as? [String: [String]])?["removeLabelIds"], ["INBOX"])
        XCTAssertNil((json["action"] as? [String: Any])?["addLabelIds"],
                     "nil fields are left out, not sent as null")
    }

    func testDeleteTargetsTheFilterAndTreatsAMissingOneAsDeleted() async throws {
        FilterStubProtocol.state.replies = [
            .init(method: "DELETE", url: filtersURL + "/OLD1", status: 204, body: ""),
            .init(method: "DELETE", url: filtersURL + "/GONE", status: 404,
                  body: #"{"error":{"code":404,"message":"Filter not found"}}"#),
        ]
        try await client.deleteFilter(id: "OLD1")
        try await client.deleteFilter(id: "GONE")
        XCTAssertEqual(FilterStubProtocol.state.seen.map(\.method), ["DELETE", "DELETE"])
    }

    func testReplaceCreatesFirstThenDeletesTheOriginal() async throws {
        FilterStubProtocol.state.replies = [
            .init(method: "POST", url: filtersURL, status: 200, body: createdJSON),
            .init(method: "DELETE", url: filtersURL + "/OLD1", status: 204, body: ""),
        ]
        let created = try await client.replaceFilter(id: original.id, with: newBody)
        XCTAssertEqual(created.id, "NEW1")
        XCTAssertEqual(FilterStubProtocol.state.seen.map(\.method), ["POST", "DELETE"])
    }

    /// The regression the step is about: a failed edit must not lose the
    /// filter. A delete-first edit would have removed it before the create
    /// failed.
    func testReplaceWithAFailedCreateNeverDeletesTheOriginal() async {
        FilterStubProtocol.state.replies = [
            .init(method: "POST", url: filtersURL, status: 400, body: """
            {"error":{"code":400,"message":"Invalid label: Label_404","status":"INVALID_ARGUMENT"}}
            """),
        ]
        do {
            _ = try await client.replaceFilter(id: original.id, with: newBody)
            XCTFail("create failure swallowed")
        } catch {
            XCTAssertEqual(GmailFilterError(error), .invalid("Invalid label: Label_404"))
        }
        XCTAssertEqual(FilterStubProtocol.state.seen.map(\.method), ["POST"],
                       "no DELETE after a failed create")
    }

    func testReplaceWithAFailedDeleteReportsBothFilters() async {
        FilterStubProtocol.state.replies = [
            .init(method: "POST", url: filtersURL, status: 200, body: createdJSON),
            .init(method: "DELETE", url: filtersURL + "/OLD1", status: 500,
                  body: #"{"error":{"code":500,"message":"Backend Error"}}"#),
        ]
        do {
            _ = try await client.replaceFilter(id: original.id, with: newBody)
            XCTFail("delete failure swallowed")
        } catch {
            guard case GmailFilterError.oldFilterKept(let created, _) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(created.id, "NEW1")
            XCTAssertTrue(error.localizedDescription.contains("Both are in place"))
        }
    }

    func testScopeAndQuotaErrorsAreNamed() async {
        let cases: [(Int, String, GmailFilterError)] = [
            (403, """
            {"error":{"code":403,"message":"Request had insufficient authentication scopes.",\
            "errors":[{"reason":"insufficientPermissions"}],"status":"PERMISSION_DENIED"}}
            """, .missingScope),
            (429, #"{"error":{"code":429,"message":"Too many requests"}}"#, .quota),
            (403, """
            {"error":{"code":403,"message":"User-rate limit exceeded.",\
            "errors":[{"domain":"usageLimits","reason":"userRateLimitExceeded"}]}}
            """, .quota),
        ]
        for (status, body, expected) in cases {
            FilterStubProtocol.state.reset()
            FilterStubProtocol.state.replies = [
                .init(method: "POST", url: filtersURL, status: status, body: body),
            ]
            do {
                _ = try await client.createFilter(newBody)
                XCTFail("\(status) swallowed")
            } catch {
                XCTAssertEqual(GmailFilterError(error), expected, body)
            }
        }
        XCTAssertTrue(GmailFilterError.missingScope.localizedDescription.contains("Sign in to it again"))
        XCTAssertTrue(GmailFilterError.quota.localizedDescription.contains("try again"))
    }

    // MARK: - Criteria and actions

    func testADialogFilterRoundTripsUnchanged() {
        let filter = GFilter(
            id: "F",
            criteria: .init(from: "boss@example.com", to: "me@example.com", subject: "Report",
                            query: "quarterly", negatedQuery: "draft", hasAttachment: true,
                            size: 5 * 1_048_576, sizeComparison: "smaller"),
            action: .init(addLabelIds: ["STARRED", "Label_3", "TRASH", "IMPORTANT", "CATEGORY_UPDATES"],
                          removeLabelIds: ["INBOX", "UNREAD", "SPAM"], forward: nil))
        let draft = GmailFilterDraft(filter)
        XCTAssertEqual(draft.sizeValue, "5")
        XCTAssertEqual(draft.sizeUnit, .mb)
        XCTAssertEqual(draft.sizeComparison, .smaller)
        XCTAssertTrue(draft.skipInbox && draft.markRead && draft.star && draft.delete && draft.neverSpam)
        XCTAssertEqual(draft.labelId, "Label_3")
        XCTAssertEqual(draft.importance, .always)
        XCTAssertEqual(draft.category, "CATEGORY_UPDATES")
        XCTAssertNil(draft.problem)
        XCTAssertEqual(Set(draft.body.action.addLabelIds ?? []), Set(filter.action?.addLabelIds ?? []))
        XCTAssertEqual(Set(draft.body.action.removeLabelIds ?? []), Set(filter.action?.removeLabelIds ?? []))
        XCTAssertEqual(draft.body.criteria, filter.criteria)
    }

    /// Gmail's label order differs from the editor's encoding: an untouched
    /// filter must still count as unchanged, or Save would create + delete.
    func testAnUntouchedFilterIsUnchangedWhateverItsLabelOrder() {
        let filter = GFilter(
            id: "F",
            criteria: .init(from: "a@b.com", to: nil, subject: nil, query: nil,
                            negatedQuery: nil, hasAttachment: false, size: nil, sizeComparison: nil),
            action: .init(addLabelIds: ["Label_3", "STARRED"], removeLabelIds: ["UNREAD", "INBOX"],
                          forward: nil))
        let draft = GmailFilterDraft(filter)
        XCTAssertNotEqual(draft.body, filter.body, "the bodies differ in order and in hasAttachment")
        XCTAssertEqual(draft, GmailFilterDraft(filter))
        var edited = draft
        edited.star = false
        XCTAssertNotEqual(edited, GmailFilterDraft(filter))
    }

    /// R2: actions the dialog has no control for are visible and droppable.
    func testHiddenActionsAreListedAndCanBeDropped() {
        let filter = GFilter(
            id: "F",
            criteria: .init(from: "a@b.com", to: nil, subject: nil, query: nil,
                            negatedQuery: nil, hasAttachment: nil, size: nil, sizeComparison: nil),
            action: .init(addLabelIds: ["Label_1", "Label_2", "SPAM", "CATEGORY_SOCIAL", "CATEGORY_FORUMS"],
                          removeLabelIds: ["Label_9"], forward: nil))
        var draft = GmailFilterDraft(filter)
        XCTAssertTrue(draft.hasHiddenActions)
        XCTAssertEqual(draft.keptAddLabelIds, ["Label_2", "SPAM", "CATEGORY_FORUMS"])
        draft.labelId = nil
        XCTAssertTrue(draft.hasHiddenActions, "clearing the label still shows the second one")
        draft.dropHiddenActions()
        XCTAssertFalse(draft.hasHiddenActions)
        XCTAssertEqual(draft.body.action.addLabelIds, ["CATEGORY_SOCIAL"])
        XCTAssertNil(draft.body.action.removeLabelIds)
    }

    /// R3: filters that delete mail, or archive it as read, ask first.
    func testDestructiveFiltersNeedConfirmation() {
        var draft = GmailFilterDraft()
        draft.from = "a@b.com"
        draft.skipInbox = true
        XCTAssertFalse(draft.needsConfirmation)
        draft.markRead = true
        XCTAssertTrue(draft.needsConfirmation)
        draft = GmailFilterDraft()
        draft.delete = true
        XCTAssertTrue(draft.needsConfirmation)
    }

    func testOverlongCriteriaAreRefused() {
        var draft = GmailFilterDraft()
        draft.star = true
        draft.hasWords = String(repeating: "a", count: GmailFilterDraft.maxFieldLength + 1)
        XCTAssertEqual(draft.problem, "Each criterion can be at most 1500 characters.")
        draft.hasWords = String(repeating: "a", count: GmailFilterDraft.maxFieldLength)
        XCTAssertNil(draft.problem)
    }

    /// R6: only a failure that may have been applied re-reads the list.
    func testOutcomeIsUnknownOnlyForTransportAnd5xx() {
        XCTAssertTrue(GmailFilterError.outcomeUnknown(URLError(.timedOut)))
        XCTAssertTrue(GmailFilterError.outcomeUnknown(GmailError.http(503, "")))
        XCTAssertTrue(GmailFilterError.outcomeUnknown(
            GmailFilterError.oldFilterKept(created: original, cause: .other("x"))))
        XCTAssertFalse(GmailFilterError.outcomeUnknown(GmailError.http(400, "")))
        XCTAssertFalse(GmailFilterError.outcomeUnknown(GmailError.http(403, "")))
        XCTAssertFalse(GmailFilterError.outcomeUnknown(GmailError.http(429, "")))
        XCTAssertFalse(GmailFilterError.outcomeUnknown(GmailFilterError.forwardingNotSupported))
        XCTAssertFalse(GmailFilterError.outcomeUnknown(CancellationError()))
    }

    /// What the dialog does not show survives an edit of what it does.
    func testAnEditKeepsWhatTheDialogDoesNotShow() {
        let filter = GFilter(
            id: "F",
            criteria: .init(from: "a@b.com", to: nil, subject: nil, query: nil,
                            negatedQuery: nil, hasAttachment: nil, size: nil,
                            sizeComparison: nil, excludeChats: true),
            action: .init(addLabelIds: ["Label_1", "Label_2"], removeLabelIds: ["Label_9"],
                          forward: nil))
        var draft = GmailFilterDraft(filter)
        draft.star = true
        let action = draft.body.action
        XCTAssertEqual(Set(action.addLabelIds ?? []), ["Label_1", "Label_2", "STARRED"])
        XCTAssertEqual(action.removeLabelIds, ["Label_9"])
        XCTAssertEqual(draft.body.criteria.excludeChats, true)
    }

    func testNeverImportantAndUnevenSizes() {
        let filter = GFilter(
            id: "F",
            criteria: .init(from: nil, to: nil, subject: nil, query: nil, negatedQuery: nil,
                            hasAttachment: nil, size: 1_500, sizeComparison: "larger"),
            action: .init(addLabelIds: nil, removeLabelIds: ["IMPORTANT"], forward: nil))
        let draft = GmailFilterDraft(filter)
        XCTAssertEqual(draft.importance, .never)
        XCTAssertEqual(draft.sizeUnit, .bytes)
        XCTAssertEqual(draft.sizeValue, "1500")
        XCTAssertEqual(draft.body.criteria.size, 1_500)
        XCTAssertEqual(draft.body.action.removeLabelIds, ["IMPORTANT"])
    }

    func testProblemsMirrorGmailWeb() {
        var draft = GmailFilterDraft()
        draft.skipInbox = true
        XCTAssertEqual(draft.problem, "Specify at least one search criterion.")
        draft.from = "   "
        XCTAssertEqual(draft.problem, "Specify at least one search criterion.",
                       "whitespace is not a criterion")
        draft.from = "a@b.com"
        XCTAssertNil(draft.problem)
        draft.skipInbox = false
        XCTAssertEqual(draft.problem, "Choose at least one action.")
        draft.star = true
        draft.sizeValue = "-3"
        XCTAssertEqual(draft.problem, "Size must be a whole number greater than zero.")
        draft.sizeValue = "99999999999"
        XCTAssertNotNil(draft.problem, "overflowing size refused")
        draft.sizeValue = "2"
        XCTAssertNil(draft.problem)
        XCTAssertEqual(draft.body.criteria.size, 2 * 1_048_576)
        XCTAssertEqual(draft.body.criteria.sizeComparison, "larger")
    }

    /// Creating a forwarding filter needs gmail.settings.sharing, which the
    /// app does not request: such filters are read-only in the editor.
    func testForwardingFiltersAreNotEditable() {
        let filter = GFilter(
            id: "F",
            criteria: .init(from: "a@b.com", to: nil, subject: nil, query: nil,
                            negatedQuery: nil, hasAttachment: nil, size: nil, sizeComparison: nil),
            action: .init(addLabelIds: nil, removeLabelIds: nil, forward: "me@elsewhere.com"))
        let draft = GmailFilterDraft(filter)
        XCTAssertTrue(draft.isForwarding)
        XCTAssertNotNil(draft.problem)
        XCTAssertNil(draft.body.action.forward, "a forwarding address is never encoded")
        XCTAssertFalse(GmailFilterDraft().isForwarding)
    }

    /// The client refuses forwarding itself, whatever the caller sends.
    func testClientNeverSendsAForwardingFilter() async {
        FilterStubProtocol.state.replies = [
            .init(method: "POST", url: filtersURL, status: 200, body: createdJSON),
        ]
        let body = GFilter.Body(
            criteria: original.body.criteria,
            action: .init(addLabelIds: nil, removeLabelIds: nil, forward: "me@elsewhere.com"))
        do {
            _ = try await client.createFilter(body)
            XCTFail("forwarding filter sent")
        } catch {
            XCTAssertEqual(error as? GmailFilterError, .forwardingNotSupported)
        }
        do {
            _ = try await client.replaceFilter(id: original.id, with: body)
            XCTFail("forwarding filter sent")
        } catch {
            XCTAssertEqual(error as? GmailFilterError, .forwardingNotSupported)
        }
        XCTAssertTrue(FilterStubProtocol.state.seen.isEmpty, "nothing reached the transport")
    }

    func testGmailMessageIsFlattenedAndCapped() {
        XCTAssertEqual(GmailFilterError.gmailMessage(#"{"error":{"message":"Filter\n  already exists"}}"#),
                       "Filter already exists")
        XCTAssertNil(GmailFilterError.gmailMessage("not json"))
        let long = String(repeating: "x", count: 500)
        XCTAssertEqual(GmailFilterError.gmailMessage(#"{"error":{"message":"\#(long)"}}"#)?.count, 201)
    }

    /// No criterion reaches the diagnostic log: the filter id leaves the
    /// path and the error body is reduced to its category.
    func testDiagnosticLineCarriesNoCriteriaOrId() {
        let body = #"{"error":{"code":400,"message":"Invalid criteria from:secret.sender@example.com"}}"#
        let line = DiagnosticLog.format(account: "ada@example.com", method: "DELETE",
                                        path: "/settings/filters/ANe1BmjSecretId", code: 400,
                                        body: body, salt: "s")
        for leak in ["secret", "ANe1Bmj", "ada@example.com"] {
            XCTAssertFalse(line.contains(leak), "\(leak) in \(line)")
        }
        XCTAssertTrue(line.contains("/settings/filters/{id}"), line)
    }

    // MARK: - Cache

    private func filter(_ id: String) -> GFilter { GFilter(id: id, criteria: nil, action: nil) }

    func testCacheEditsFollowWhatGmailConfirmed() {
        var cache = GmailFilterCache()
        cache.loaded([filter("1"), filter("2"), filter("3")], account: "a", revision: 0)
        cache.apply(.replaced(oldId: "2", with: filter("9")), account: "a")
        XCTAssertEqual(cache.filters["a"]?.map(\.id), ["1", "9", "3"], "an edit keeps its place")
        cache.apply(.created(filter("4")), account: "a")
        cache.apply(.deleted(id: "1"), account: "a")
        XCTAssertEqual(cache.filters["a"]?.map(\.id), ["9", "3", "4"])
        cache.apply(.replaced(oldId: "missing", with: filter("5")), account: "a")
        XCTAssertEqual(cache.filters["a"]?.map(\.id), ["9", "3", "4", "5"])
    }

    /// R8: a failed delete after a good create lists both filters.
    func testAFailedDeleteAfterCreateListsBoth() {
        var cache = GmailFilterCache()
        cache.loaded([filter("OLD")], account: "a", revision: 0)
        cache.apply(failure: .oldFilterKept(created: filter("NEW"), cause: .other("x")), account: "a")
        XCTAssertEqual(cache.filters["a"]?.map(\.id), ["OLD", "NEW"])
        cache.apply(failure: .quota, account: "a")
        XCTAssertEqual(cache.filters["a"]?.map(\.id), ["OLD", "NEW"], "other failures change nothing")
    }

    /// R8: an edit finishing after its account was removed brings nothing back.
    func testEditsAfterForgetDoNothing() {
        var cache = GmailFilterCache()
        cache.loaded([filter("1")], account: "a", revision: 0)
        cache.forget(account: "a")
        cache.apply(.created(filter("2")), account: "a")
        cache.apply(failure: .oldFilterKept(created: filter("3"), cause: .quota), account: "a")
        XCTAssertNil(cache.filters["a"])
    }

    /// R6: a list read that started before an edit cannot overwrite it.
    func testAListReadOlderThanAnEditIsDropped() {
        var cache = GmailFilterCache()
        cache.loaded([filter("1")], account: "a", revision: 0)
        let before = cache.revision("a")
        cache.apply(.created(filter("2")), account: "a")
        cache.loaded([filter("1")], account: "a", revision: before)
        XCTAssertEqual(cache.filters["a"]?.map(\.id), ["1", "2"])
        cache.loaded([filter("1"), filter("2"), filter("7")], account: "a", revision: cache.revision("a"))
        XCTAssertEqual(cache.filters["a"]?.map(\.id), ["1", "2", "7"])
    }

    /// DEC-019: removing an account drops its filters from memory.
    func testForgettingAnAccountDropsOnlyItsFilters() {
        var cache = GmailFilterCache()
        cache.loaded([filter("1")], account: "a", revision: 0)
        cache.loaded([filter("2")], account: "b", revision: 0)
        cache.loadFailed("x", account: "a")
        cache.loadFailed("y", account: "b")
        cache.forget(account: "a")
        XCTAssertNil(cache.filters["a"])
        XCTAssertNil(cache.loadErrors["a"])
        XCTAssertEqual(cache.filters["b"]?.map(\.id), ["2"])
        XCTAssertEqual(cache.loadErrors["b"], "y")
    }

    /// The removal path calls the cache's forget (lexical guard: MailStore
    /// cannot be built in a unit test).
    func testAccountRemovalForgetsFilters() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MishMail/App/MailStore+Accounts.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "func removeAccount(_ id: String)"))
        let end = try XCTUnwrap(text.range(of: "Task { @MainActor", range: start.upperBound..<text.endIndex))
        XCTAssertTrue(text[start.lowerBound..<end.lowerBound].contains("filterCache.forget(account: id)"))
    }

    // MARK: - Local preview

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        return q
    }

    private func seed(_ db: Database, account: String, id: String, from: String,
                      subject: String, body: String, labels: String, date: Date) throws {
        if try Account.fetchOne(db, key: account) == nil {
            try Account(id: account, displayName: account, historyId: "1",
                        lastSyncAt: nil, senderName: "").insert(db)
        }
        try MailThread(
            id: "\(account):t\(id)", accountId: account, gmailThreadId: "t\(id)",
            subject: subject, snippet: "", fromDisplay: from,
            lastDate: date, isUnread: false, isStarred: false,
            inInbox: true, inTrash: labels.contains("TRASH"), labelIds: labels,
            snoozeUntil: nil, participants: from, messageCount: 1,
            hasAttachment: false, reminderAt: nil).insert(db)
        try Message(id: "\(account):\(id)", accountId: account, gmailId: id,
                    threadId: "\(account):t\(id)", fromHeader: from, toHeader: account,
                    ccHeader: "", bccHeader: "", subject: subject, date: date,
                    snippet: "", bodyText: "", bodyHTML: nil, messageIdHeader: "",
                    referencesHeader: "", labelIds: labels, isUnread: false,
                    hasAttachment: false).insert(db)
        try MessageBody(messageId: "\(account):\(id)", bodyText: body, bodyHTML: nil).insert(db)
    }

    func testPreviewMatchesLocalMailOutsideTrashAndSpam() throws {
        let q = try makeDB()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        try q.write { db in
            try seed(db, account: "a@x.com", id: "1", from: "news@shop.com", subject: "Sale",
                     body: "coupon inside", labels: "INBOX", date: base)
            try seed(db, account: "a@x.com", id: "2", from: "news@shop.com", subject: "Old sale",
                     body: "coupon", labels: "TRASH", date: base.addingTimeInterval(10))
            try seed(db, account: "a@x.com", id: "3", from: "friend@x.com", subject: "Hi",
                     body: "coupon", labels: "INBOX", date: base.addingTimeInterval(20))
            try seed(db, account: "b@x.com", id: "4", from: "news@shop.com", subject: "Other account",
                     body: "coupon", labels: "INBOX", date: base)
            try seed(db, account: "a@x.com", id: "5", from: "news@shop.com", subject: "My reply",
                     body: "coupon", labels: "SENT", date: base.addingTimeInterval(30))
        }
        var draft = GmailFilterDraft()
        draft.from = "shop.com"
        draft.hasWords = "coupon"
        let result = try q.read {
            try GmailFilterPreview.fetch($0, account: "a@x.com", criteria: draft.criteria)
        }
        XCTAssertEqual(result.scanned, 2, "trash, sent mail and the other account are left out")
        XCTAssertEqual(result.matchCount, 1)
        XCTAssertEqual(result.hits.map(\.subject), ["Sale"], "body text comes from message_body")
        XCTAssertFalse(result.sizeNotChecked)
    }

    /// R4: `a OR b` in From matches either sender, as in Gmail.
    func testFromAcceptsOrAlternatives() {
        let fields = GmailFilterMatch.MessageFields(
            from: "News <b@y.com>", to: "me@x.com", subject: "Weekly digest", hasAttachment: false)
        let match = { (from: String) in
            GmailFilterMatch.matches(GFilter.Criteria(
                from: from, to: nil, subject: nil, query: nil, negatedQuery: nil,
                hasAttachment: nil, size: nil, sizeComparison: nil), message: fields)
        }
        XCTAssertTrue(match("a@x.com OR b@y.com"))
        XCTAssertFalse(match("a@x.com OR c@z.com"))
        XCTAssertTrue(match("News"))
        let subject = GFilter.Criteria(from: nil, to: nil, subject: "digest OR invoice", query: nil,
                                       negatedQuery: nil, hasAttachment: nil, size: nil,
                                       sizeComparison: nil)
        XCTAssertTrue(GmailFilterMatch.matches(subject, message: fields))
    }

    func testPreviewFlagsASizeItCannotCheck() {
        var draft = GmailFilterDraft()
        draft.sizeValue = "1"
        let fields = GmailFilterMatch.MessageFields(from: "a", to: "b", subject: "s", hasAttachment: false)
        let hit = GmailFilterPreview.Hit(id: "1", from: "a", subject: "s", date: Date())
        let result = GmailFilterPreview.evaluate(draft.criteria, messages: [(hit, fields)])
        XCTAssertTrue(result.sizeNotChecked)
        XCTAssertEqual(result.matchCount, 0)
    }
}

/// Answers Gmail requests from a queue of canned replies, matched by method
/// and URL, and records each request with its body.
final class FilterStubProtocol: URLProtocol {
    struct Reply {
        var method: String
        var url: String
        var status: Int
        var body: String
    }

    struct Seen {
        var method: String
        var url: String
        var headers: [String: String]
        var body: Data
    }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [Reply] = []
        private var log: [Seen] = []
        var replies: [Reply] {
            get { lock.withLock { queue } }
            set { lock.withLock { queue = newValue } }
        }
        var seen: [Seen] { lock.withLock { log } }
        func reset() { lock.withLock { queue = []; log = [] } }
        func take(_ seen: Seen) -> Reply? {
            lock.withLock {
                log.append(seen)
                guard let i = queue.firstIndex(where: { $0.method == seen.method && $0.url == seen.url })
                else { return nil }
                return queue.remove(at: i)
            }
        }
    }

    static let state = State()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let seen = Seen(method: request.httpMethod ?? "GET", url: url.absoluteString,
                        headers: request.allHTTPHeaderFields ?? [:], body: Self.body(of: request))
        guard let reply = Self.state.take(seen) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: Data(reply.body.utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands a protocol the body as a stream, not `httpBody`.
    private static func body(of request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            guard n > 0 else { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
