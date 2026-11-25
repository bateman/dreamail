import XCTest
import GRDB

/// The first sync shows mail as it is stored, and the user can act on it
/// meanwhile: edits made during the pass survive the pages that follow.
final class LocalThreadEditsTests: XCTestCase {
    private let archive = RemoteThreadChange.modify(remove: ["INBOX", "UNREAD"])

    func testNothingIsRecordedWhileNoPassRuns() {
        let edits = LocalThreadEdits()
        edits.record(threadIds: ["a:t1"], change: archive)
        XCTAssertTrue(edits.isEmpty)
    }

    func testAPassSeesOnlyEditsMadeAfterItBegan() {
        let edits = LocalThreadEdits()
        let first = edits.beginPass()
        edits.record(threadIds: ["a:t1"], change: archive)
        let second = edits.beginPass()
        edits.record(threadIds: ["a:t2"], change: .modify(add: ["STARRED"]))

        XCTAssertEqual(edits.changes(since: first, threadIds: ["a:t1", "a:t2", "a:t3"])
                        .mapValues { $0.map(\.change) },
                       ["a:t1": [archive], "a:t2": [.modify(add: ["STARRED"])]])
        XCTAssertEqual(edits.changes(since: second, threadIds: ["a:t1", "a:t2"])
                        .mapValues { $0.map(\.change) },
                       ["a:t2": [.modify(add: ["STARRED"])]])
        edits.endPass(first)
        edits.endPass(second)
        XCTAssertTrue(edits.isEmpty, "nothing outlives the passes that could need it")
    }

    func testEditsApplyInOrderAndAnUndoCancelsOut() throws {
        let edits = LocalThreadEdits()
        let mark = edits.beginPass()
        let at = Date()
        edits.record(threadIds: ["a:t1"], change: .modify(remove: ["INBOX"]), at: at)
        edits.record(threadIds: ["a:t1"], change: .modify(add: ["INBOX"]), at: at)
        let list = try XCTUnwrap(edits.changes(since: mark, threadIds: ["a:t1"])["a:t1"])
        let message = BackfillDeriveWithLocalEditsTests.message(labels: "INBOX", date: at)
        XCTAssertEqual(SyncEngine.applyingLocalEdits(list, to: [message]).map(\.labelIds), ["INBOX"])
        edits.endPass(mark)
    }

    func testRefusedEditAndRemovedAccountAreForgotten() {
        let edits = LocalThreadEdits()
        let mark = edits.beginPass()
        edits.record(threadIds: ["a@x.com:t1", "b@x.com:t2"], change: archive)
        edits.forget(threadId: "a@x.com:t1")
        XCTAssertEqual(Set(edits.changes(since: mark, threadIds: ["a@x.com:t1", "b@x.com:t2"]).keys),
                       ["b@x.com:t2"])
        edits.forget(accountId: "b@x.com")
        XCTAssertTrue(edits.isEmpty)
        edits.endPass(mark)
    }
}

final class BackfillDeriveWithLocalEditsTests: XCTestCase {
    private let account = "ron@x.com"
    private var key: String { "\(account):t1" }

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: self.account, displayName: "P", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
        }
        return q
    }

    private func insert(_ db: Database, _ gmailId: String, daysAgo: Double,
                        labels: String, unread: Bool) throws {
        try Message(
            id: "\(account):\(gmailId)", accountId: account, gmailId: gmailId,
            threadId: key, fromHeader: "a@b.com", toHeader: account,
            ccHeader: "", bccHeader: "", subject: "s",
            date: Date(timeIntervalSinceNow: -daysAgo * 86_400),
            snippet: "snippet-\(gmailId)", bodyText: "", bodyHTML: nil, messageIdHeader: "",
            referencesHeader: "", labelIds: labels, isUnread: unread,
            hasAttachment: false).save(db)
    }

    private func thread(_ q: DatabaseQueue) throws -> MailThread {
        try XCTUnwrap(try q.read { db in try MailThread.fetchOne(db, key: self.key) })
    }

    /// Page 1 stores the newest message; the user archives the thread; page 2
    /// brings an older message downloaded before Gmail took the archive. The
    /// re-derive keeps the thread archived and read, with both messages.
    func testArchiveDuringThePassIsNotUndoneByALaterPage() throws {
        let q = try makeDB()
        try q.write { db in
            try self.insert(db, "m2", daysAgo: 0, labels: "INBOX UNREAD", unread: true)
            try SyncEngine.deriveThreads(db, for: [self.key], accountId: self.account)
        }
        XCTAssertTrue(try thread(q).inInbox)

        // The optimistic write (thread row only), as `mutateThread` does.
        let shown = try thread(q)
        var archived = shown
        ThreadUndo.apply(.archive, &archived)
        try q.write { db in
            try OptimisticThreadWrite.updateChangedColumns(db, from: shown, to: archived)
            try self.insert(db, "m1", daysAgo: 1, labels: "INBOX UNREAD", unread: true)
            try SyncEngine.deriveThreads(
                db, for: [self.key], accountId: self.account,
                localEdits: [self.key: [.init(change: ThreadUndo.remote(.archive), at: Date())]])
        }
        let t = try thread(q)
        XCTAssertFalse(t.inInbox, "the archive stays")
        XCTAssertFalse(t.isUnread)
        XCTAssertEqual(t.messageCount, 2, "the older message still joins the thread")

        // Message rows keep Gmail's last known labels: a refused edit
        // reverts from them.
        let labels = try q.read { db in
            try String.fetchAll(db, sql: "SELECT labelIds FROM message ORDER BY id")
        }
        XCTAssertEqual(labels, ["INBOX UNREAD", "INBOX UNREAD"])
        try q.write { db in
            try OptimisticThreadWrite.rederiveOrDelete(db, threadId: self.key, accountId: self.account)
        }
        XCTAssertTrue(try thread(q).inInbox, "a revert still goes back to Gmail's state")
    }

    func testWithoutTheEditTheOldLabelsWouldComeBack() throws {
        let q = try makeDB()
        try q.write { db in
            try self.insert(db, "m2", daysAgo: 0, labels: "INBOX", unread: false)
            try SyncEngine.deriveThreads(db, for: [self.key], accountId: self.account)
            try db.execute(sql: "UPDATE thread SET inInbox = 0 WHERE id = ?", arguments: [self.key])
            try self.insert(db, "m1", daysAgo: 1, labels: "INBOX", unread: false)
            try SyncEngine.deriveThreads(db, for: [self.key], accountId: self.account)
        }
        XCTAssertTrue(try thread(q).inInbox, "the case LocalThreadEdits exists for")
    }

    static func message(id: String = "m", labels: String, date: Date,
                        unread: Bool = false) -> Message {
        Message(
            id: "a:\(id)", accountId: "a", gmailId: id, threadId: "a:t", fromHeader: "",
            toHeader: "", ccHeader: "", bccHeader: "", subject: "", date: date,
            snippet: "", bodyText: "", bodyHTML: nil, messageIdHeader: "", referencesHeader: "",
            labelIds: labels, isUnread: unread, hasAttachment: false)
    }

    /// Mail that arrived after an archive or mark-read is new mail: the
    /// edit does not reach it.
    func testAnEditDoesNotReachMailThatArrivedAfterIt() {
        let edit = Date(timeIntervalSince1970: 10_000)
        let before = Self.message(id: "old", labels: "INBOX UNREAD",
                                  date: edit.addingTimeInterval(-60), unread: true)
        let after = Self.message(id: "new", labels: "INBOX UNREAD",
                                 date: edit.addingTimeInterval(60), unread: true)
        let result = SyncEngine.applyingLocalEdits(
            [.init(change: ThreadUndo.remote(.archive), at: edit)], to: [after, before])
        XCTAssertEqual(result.map(\.labelIds), ["INBOX UNREAD", ""])
        XCTAssertEqual(result.map(\.isUnread), [true, false])
    }

    /// Messages and their thread rows commit together: a pass stopped after
    /// any chunk leaves no stored message with a missing or stale thread.
    func testAChunkCommitsItsThreadRowsWithIt() throws {
        let q = try makeDB()
        func upsert(_ gmailId: String, daysAgo: Double, unread: Bool) throws {
            let m = Message(
                id: "\(account):\(gmailId)", accountId: account, gmailId: gmailId,
                threadId: key, fromHeader: "a@b.com", toHeader: account,
                ccHeader: "", bccHeader: "", subject: "s",
                date: Date(timeIntervalSinceNow: -daysAgo * 86_400),
                snippet: "snippet-\(gmailId)", bodyText: "", bodyHTML: nil, messageIdHeader: "",
                referencesHeader: "", labelIds: unread ? "INBOX UNREAD" : "INBOX",
                isUnread: unread, hasAttachment: false)
            try q.write { db in
                _ = try SyncEngine.upsertDerivingThreads(
                    db, items: [.init(message: m, attachments: [])], accountId: self.account)
            }
        }
        try upsert("m1", daysAgo: 1, unread: false)
        XCTAssertEqual(try thread(q).messageCount, 1, "the first chunk has its thread row")
        try upsert("m2", daysAgo: 0, unread: true)
        let t = try thread(q)
        XCTAssertEqual(t.messageCount, 2)
        XCTAssertTrue(t.isUnread, "a later chunk brings the thread up to date in the same commit")
        XCTAssertEqual(t.snippet, "snippet-m2")
    }

    /// A first sync cut short resumes from its kept id and replays history
    /// from it before listing; the expired-history reconcile always starts
    /// fresh, and so does a first sync with nothing kept.
    func testABackfillResumesFromTheKeptHistoryId() {
        XCTAssertEqual(SyncEngine.backfillStart(kept: "42", reconcile: false), .replay("42"))
        XCTAssertEqual(SyncEngine.backfillStart(kept: nil, reconcile: false), .fresh)
        XCTAssertEqual(SyncEngine.backfillStart(kept: "", reconcile: false), .fresh)
        XCTAssertEqual(SyncEngine.backfillStart(kept: "42", reconcile: true), .fresh)
    }

    func testTheFirstSyncHistoryIdGoesWithTheAccount() {
        let key = SyncEngine.firstSyncHistoryKey(accountId: "a@x.com")
        XCTAssertEqual(key, "backfill.startHistory.a@x.com")
        XCTAssertTrue(AccountLifecycle.accountDefaultsKeys(
            accountId: "a@x.com", in: UserDefaults(suiteName: "first-sync-\(UUID())")!)
            .contains(key))
    }

    func testStarTrashAndReadApplyToEveryMessage() throws {
        let m = Self.message(labels: "INBOX UNREAD", date: Date(), unread: true)
        let starred = SyncEngine.applyingLocalEdit(.modify(add: ["STARRED"]), to: m)
        XCTAssertEqual(starred.labelIds, "INBOX STARRED UNREAD")
        XCTAssertTrue(starred.isUnread, "a star does not touch the read state")
        let read = SyncEngine.applyingLocalEdit(.modify(remove: ["UNREAD"]), to: m)
        XCTAssertEqual(read.labelIds, "INBOX")
        XCTAssertFalse(read.isUnread)
        let trashed = SyncEngine.applyingLocalEdit(.trash, to: m)
        XCTAssertEqual(trashed.labelIds, "TRASH UNREAD")
    }

    /// A run cut short between a write and its page's derive left messages
    /// without a thread row; the resumed first sync finds them.
    func testMessagesWithoutAThreadRowAreFound() throws {
        let q = try makeDB()
        try q.write { db in
            try self.insert(db, "m1", daysAgo: 0, labels: "INBOX", unread: false)
        }
        XCTAssertEqual(try q.read { db in
            try SyncEngine.threadKeysMissingRow(db, accountId: self.account)
        }, [key])
        try q.write { db in
            try SyncEngine.deriveThreads(db, for: [self.key], accountId: self.account)
        }
        XCTAssertEqual(try q.read { db in
            try SyncEngine.threadKeysMissingRow(db, accountId: self.account)
        }, [])
    }

    func testListingStartsSmallAndWithTheInbox() {
        XCTAssertEqual(SyncEngine.listPageSize(cap: 500, firstPageSize: 50), 50)
        XCTAssertEqual(SyncEngine.listPageSize(cap: 20, firstPageSize: 50), 20)
        XCTAssertEqual(SyncEngine.listPageSize(cap: 500, firstPageSize: nil), 500)
        XCTAssertEqual(SyncEngine.inboxFirstQuery(windowQuery: "newer_than:90d"),
                       "in:inbox newer_than:90d")
        XCTAssertEqual(SyncEngine.inboxFirstQuery(windowQuery: nil), "in:inbox")
    }
}

final class SyncBatchSinkTests: XCTestCase {
    @MainActor
    private final class Received {
        var batches: [Set<String>] = []
        var all: Set<String> { batches.reduce(into: []) { $0.formUnion($1) } }
    }

    /// Pages arrive in a burst: the first reloads at once, the rest come
    /// together in one trailing delivery — not one reload per page.
    @MainActor
    func testPagesAreSurfacedThrottledAndNothingIsLost() async {
        let received = Received()
        let sink = SyncBatchSink(interval: 0.05) { received.batches.append($0) }
        sink.submit(["a:1"])
        sink.submit(["a:2"])
        sink.submit([])
        sink.submit(["a:3"])
        for _ in 0..<200 where received.all != ["a:1", "a:2", "a:3"] {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(received.all, ["a:1", "a:2", "a:3"])
        XCTAssertLessThanOrEqual(received.batches.count, 2)

        sink.submit(["a:4"])
        sink.close()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(received.all.contains("a:4"), "the pass's own final reload follows close()")
    }
}

final class FirstSyncBacklogNotificationTests: XCTestCase {
    private let added = Date(timeIntervalSince1970: 50_000)

    private func candidate(_ id: String, inbound: Date) -> NewMailNotifications.Candidate {
        .init(id: id, fromEmail: "x@y.com", allFromEmails: "x@y.com", lastInboundDate: inbound,
              isUnread: true, inInbox: true, inTrash: false, inSpam: false,
              inPromotions: false, inSocial: false, snoozeUntil: nil)
    }

    private func fresh(_ state: inout NewMailNotifications,
                       _ current: [NewMailNotifications.Candidate]) -> [String] {
        state.fresh(current: current, now: added.addingTimeInterval(600), demoMode: false) { _ in false }
    }

    func testTheBacklogOfANewAccountDoesNotNotify() {
        var state = NewMailNotifications()
        state.seed([])
        state.quietBacklog(accountId: "new@x.com", before: added)
        let old = candidate("new@x.com:t1", inbound: added.addingTimeInterval(-86_400))
        let arrived = candidate("new@x.com:t2", inbound: added.addingTimeInterval(60))
        XCTAssertEqual(fresh(&state, [old, arrived]), ["new@x.com:t2"],
                       "only mail that arrived after the account was added")
        let reply = candidate("new@x.com:t1", inbound: added.addingTimeInterval(120))
        XCTAssertEqual(fresh(&state, [reply]), ["new@x.com:t1"], "a reply in a backlog thread is new")
    }

    func testOtherAccountsAndTheEarliestStartAreKept() {
        var state = NewMailNotifications()
        state.seed([])
        state.quietBacklog(accountId: "new@x.com", before: added)
        state.quietBacklog(accountId: "new@x.com", before: added.addingTimeInterval(3_600))
        let duringFirstAttempt = candidate("new@x.com:t1", inbound: added.addingTimeInterval(60))
        let otherAccount = candidate("old@x.com:t9", inbound: added.addingTimeInterval(-60))
        XCTAssertEqual(fresh(&state, [duringFirstAttempt, otherAccount]),
                       ["new@x.com:t1", "old@x.com:t9"])
        XCTAssertEqual(NewMailNotifications.accountId(ofThread: "a@x.com:t1"), "a@x.com")
    }

    /// Once the backlog is stored the cutoff goes: a first-seen thread with
    /// older inbound mail (a snoozed thread waking) notifies again.
    func testTheCutoffEndsWhenTheBacklogIsStored() {
        var state = NewMailNotifications()
        state.seed([])
        state.quietBacklog(accountId: "new@x.com", before: added)
        XCTAssertTrue(state.hasBacklog(accountId: "new@x.com"))
        state.forgetBacklog(accountId: "new@x.com")
        XCTAssertFalse(state.hasBacklog(accountId: "new@x.com"))
        let woke = candidate("new@x.com:t1", inbound: added.addingTimeInterval(-86_400))
        XCTAssertEqual(fresh(&state, [woke]), ["new@x.com:t1"])
    }
}

final class AccountSignInTests: XCTestCase {
    private actor Calls {
        var stored: [String] = []
        func store(_ email: String) { stored.append(email) }
    }

    /// Cancel while the app waits for the browser: nothing is stored.
    func testCancelWhileWaitingForTheBrowserStoresNothing() async throws {
        let calls = Calls()
        let task = Task {
            try await AccountSignIn.connect(
                authorize: {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                    return ("refresh", "access")
                },
                profile: { _ in .init(email: "a@x.com") },
                store: { _, info in await calls.store(info.email); return true })
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled sign-in must not succeed")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let stored = await calls.stored
        XCTAssertEqual(stored, [])
    }

    func testCancelAfterTheProfileIsBackStillStoresNothing() async throws {
        let calls = Calls()
        let task = Task {
            try await AccountSignIn.connect(
                authorize: { ("refresh", "access") },
                profile: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return .init(email: "a@x.com")
                },
                store: { _, info in await calls.store(info.email); return true })
        }
        await XCTAssertThrowsErrorAsync(try await task.value)
        let stored = await calls.stored
        XCTAssertEqual(stored, [])
    }

    func testSuccessStoresOnceAndReturnsTheProfile() async throws {
        let calls = Calls()
        let profile = try await AccountSignIn.connect(
            authorize: { ("refresh", "access") },
            profile: { access in
                XCTAssertEqual(access, "access")
                return .init(email: "a@x.com", name: "A", picture: nil)
            },
            store: { refresh, info in
                XCTAssertEqual(refresh, "refresh")
                await calls.store(info.email)
                return true
            })
        XCTAssertEqual(profile?.email, "a@x.com")
        let stored = await calls.stored
        XCTAssertEqual(stored, ["a@x.com"])
    }

    /// Lexical guard (MailStore cannot be built in a unit test): the sign-in
    /// task ends once the account is stored; send-as identities and the
    /// first sync run in a separate task that quit cancels and awaits.
    func testConnectingEndsBeforeTheFirstSync() throws {
        let source = try ForkIdentityTests.repoFile("Sources/DreaMail/App/MailStore+Accounts.swift")
        let start = try XCTUnwrap(source.range(of: "accountSignInTask = Task {"))
        let end = try XCTUnwrap(source.range(of: "func cancelAccountSignIn()"))
        let signIn = source[start.lowerBound..<end.lowerBound]
        XCTAssertTrue(signIn.contains("startFirstSync(accountId: info.email)"))
        XCTAssertFalse(signIn.contains("await sync("), "the first sync must not hold \"Connecting…\"")
        XCTAssertFalse(signIn.contains("await refreshSendIdentities("))

        let store = try ForkIdentityTests.repoFile("Sources/DreaMail/App/MailStore.swift")
        XCTAssertTrue(store.contains("+ firstSyncTasks.values.map(\\.task)"),
                      "quit cancels and awaits the first syncs")
        let removal = try XCTUnwrap(source.range(of: "func removeAccount(_ id: String)"))
        XCTAssertTrue(source[removal.lowerBound...].contains("await firstSync?.value"),
                      "account removal awaits the first sync")
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                          file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {}
}
