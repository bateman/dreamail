import XCTest
import GRDB

/// The Trash view lists partly trashed conversations from their trashed
/// messages, and restoring or undoing reaches exactly the messages it
/// should (`messages.batchModify` on explicit ids, never a delete).
final class TrashViewTests: XCTestCase {
    private let account = "you@example.com"

    private func msg(_ id: String, thread: String = "t1", minutesAgo: Double, labels: String,
                     from: String = "Ann <ann@example.com>", subject: String = "Plans") -> Message {
        Message(id: "\(account):\(id)", accountId: account, gmailId: id,
                threadId: "\(account):\(thread)", fromHeader: from, toHeader: account,
                ccHeader: "", bccHeader: "", subject: subject,
                date: Date(timeIntervalSinceNow: -minutesAgo * 60),
                snippet: "snippet-\(id)", bodyText: "body-\(id)", bodyHTML: nil,
                messageIdHeader: "<\(id)@example.com>", referencesHeader: "",
                labelIds: labels, isUnread: false, hasAttachment: false)
    }

    private func derive(_ messages: [Message], thread: String = "t1") throws -> MailThread {
        try XCTUnwrap(SyncEngine.deriveThread(
            threadKey: "\(account):\(thread)", gmailThreadId: thread, accountId: account,
            messages: messages.sorted { $0.date > $1.date }, existing: nil))
    }

    private func makeDB(_ threads: [String: [Message]]) throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: self.account, displayName: "P", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
            for (thread, messages) in threads {
                for m in messages { try m.insert(db) }
                try self.derive(messages, thread: thread).insert(db)
            }
        }
        return q
    }

    // A live conversation with one trashed message, a fully trashed one, a
    // live one, and a live one with only a discarded draft in the trash.
    private var mailbox: [String: [Message]] {
        ["partly": [msg("p1", thread: "partly", minutesAgo: 60, labels: "TRASH",
                        from: "Bob <bob@example.com>", subject: "Old"),
                    msg("p2", thread: "partly", minutesAgo: 5, labels: "INBOX")],
         "full": [msg("f1", thread: "full", minutesAgo: 30, labels: "TRASH")],
         "live": [msg("l1", thread: "live", minutesAgo: 10, labels: "INBOX")],
         "draft": [msg("d1", thread: "draft", minutesAgo: 20, labels: "INBOX"),
                   msg("d2", thread: "draft", minutesAgo: 15, labels: "DRAFT TRASH",
                       from: "Me <you@example.com>")]]
    }

    func testTrashViewListsFullyAndPartlyTrashedConversations() throws {
        let q = try makeDB(mailbox)
        let ids = try q.read { db in
            try MailThread.filter(sql: TrashedMessages.inTrashViewSQL()).fetchAll(db).map(\.gmailThreadId)
        }
        XCTAssertEqual(Set(ids), ["partly", "full"], "a discarded draft does not list it")
    }

    func testPartlyTrashedRowComesFromItsTrashedMessages() throws {
        let q = try makeDB(mailbox)
        let result = try q.read { db in
            try TrashedMessages.projectTrashView(
                MailThread.filter(sql: TrashedMessages.inTrashViewSQL())
                    .order(Column("id")).fetchAll(db), db: db)
        }
        XCTAssertEqual(result.projected, ["\(account):partly"])
        let partly = try XCTUnwrap(result.rows.first { $0.gmailThreadId == "partly" })
        XCTAssertTrue(partly.inTrash)
        XCTAssertEqual(partly.snippet, "snippet-p1")
        XCTAssertEqual(partly.fromEmail, "bob@example.com")
        XCTAssertEqual(partly.messageCount, 1)
        let full = try XCTUnwrap(result.rows.first { $0.gmailThreadId == "full" })
        XCTAssertEqual(full.snippet, "snippet-f1", "a fully trashed row is shown as stored")
    }

    func testReaderFromTheTrashViewShowsOnlyTheTrashedMessages() throws {
        let q = try makeDB(mailbox)
        try q.read { db in
            let trash = try ThreadDetailRepository.fetchPayload(
                threadId: "\(self.account):partly", db: db, trashView: true)
            XCTAssertEqual(trash.messages.map(\.gmailId), ["p1"])
            let live = try ThreadDetailRepository.fetchPayload(
                threadId: "\(self.account):partly", db: db)
            XCTAssertEqual(live.messages.map(\.gmailId), ["p2"])
            let full = try ThreadDetailRepository.fetchPayload(
                threadId: "\(self.account):full", db: db, trashView: true)
            XCTAssertEqual(full.messages.map(\.gmailId), ["f1"])
        }
    }

    // MARK: - Exact ids reaching Gmail

    func testRestoreSendsOnlyTheTrashedIds() async throws {
        let messages = mailbox["partly"]! + [msg("p3", thread: "partly", minutesAgo: 50,
                                                 labels: "DRAFT TRASH")]
        XCTAssertEqual(TrashedMessages.trashedIds(messages), ["p1"], "not live mail, not drafts")
        let move = ConversationAction.moveTo(labelId: "Label_1", alsoRemove: ["TRASH"]).remote
        let change = RemoteThreadChange.modifyMessages(
            ids: TrashedMessages.trashedIds(messages), add: move.addLabels, remove: move.removeLabels)
        let stub = StubThreadEditing()
        try await RemoteThreadSend.send(change, via: stub, gmailThreadId: "partly")
        let calls = await stub.calls
        XCTAssertEqual(calls, [.modifyMessages(ids: ["p1"], add: ["Label_1"],
                                               remove: ["INBOX", "TRASH"])])
    }

    /// The trash already reached Gmail (possibly a reply not synced yet):
    /// the undo un-trashes the whole thread, so that reply comes back too,
    /// then re-trashes only what was trashed before the action.
    func testUndoOfASentTrashRestoresAllItReachedAndKeepsEarlierDeletions() async throws {
        let before = [msg("a", minutesAgo: 60, labels: "TRASH"),
                      msg("b", minutesAgo: 30, labels: "INBOX"),
                      msg("c", minutesAgo: 10, labels: "INBOX UNREAD")]
        let state = ThreadUndo.TrashState(
            liveIds: TrashedMessages.liveIds(before),
            trashedIds: before.filter(TrashedMessages.isTrashed).map(\.gmailId))
        XCTAssertEqual(state, ThreadUndo.TrashState(liveIds: ["b", "c"], trashedIds: ["a"]))
        let undo = ThreadUndo.undoTrashRemote(wasInInbox: true, before: state)
        let stub = StubThreadEditing()
        try await RemoteThreadSend.send(undo, via: stub, gmailThreadId: "t1")
        let calls = await stub.calls
        XCTAssertEqual(calls, [.modify(id: "t1", add: ["INBOX"], remove: ["TRASH"]),
                               .modifyMessages(ids: ["a"], add: ["TRASH"], remove: ["INBOX"])])
    }

    func testUndoWithoutEarlierDeletionsIsTheThreadUntrash() {
        XCTAssertEqual(ThreadUndo.undoTrashRemote(
            wasInInbox: false, before: .init(liveIds: ["b"], trashedIds: [])),
                       .modify(add: [], remove: ["TRASH"]))
        // Unknown state: the whole thread, as before.
        XCTAssertEqual(ThreadUndo.undoTrashRemote(wasInInbox: false, before: nil),
                       .modify(add: [], remove: ["TRASH"]))
    }

    /// Whatever the undo restores, the messages deleted before the action
    /// go back in the trash: nothing deleted earlier comes back. (A
    /// conversation entirely in the trash is never trashed again, so its
    /// undo never arises: `MailStore.trash`.)
    func testUndoAlwaysPutsEarlierDeletionsBack() {
        XCTAssertEqual(ThreadUndo.undoTrashRemote(
            wasInInbox: false, before: .init(liveIds: [], trashedIds: ["a", "b"])),
                       .sequence([.modify(add: [], remove: ["TRASH"]),
                                  .modifyMessages(ids: ["a", "b"], add: ["TRASH"], remove: [])]))
    }

    /// Drafts are never named (a draft's id changes on every save) and the
    /// states of several threads come from one query.
    func testTrashStatesLeaveDraftsOut() throws {
        let q = try makeDB(["t1": [msg("a", minutesAgo: 60, labels: "TRASH"),
                                   msg("d", minutesAgo: 50, labels: "DRAFT TRASH"),
                                   msg("b", minutesAgo: 30, labels: "INBOX"),
                                   msg("e", minutesAgo: 20, labels: "DRAFT")],
                            "t2": [msg("c", thread: "t2", minutesAgo: 10, labels: "INBOX")]])
        let states = try q.read { db in
            try TrashedMessages.trashStates(
                db, threadIds: ["\(self.account):t1", "\(self.account):t2", "\(self.account):none"])
        }
        XCTAssertEqual(states["\(account):t1"], .init(liveIds: ["b"], trashedIds: ["a"]))
        XCTAssertEqual(states["\(account):t2"], .init(liveIds: ["c"], trashedIds: []))
        XCTAssertEqual(states["\(account):none"], .init(liveIds: [], trashedIds: []))
    }

    /// "Move to" from the Trash view works on the stored live row and the
    /// trashed ids; a conversation with nothing left to restore is skipped.
    func testRestoreTargetsAreTheStoredRows() throws {
        let q = try makeDB(mailbox)
        let targets = try q.read { db in
            try TrashedMessages.restoreTargets(
                db, threadIds: ["\(self.account):partly", "\(self.account):live"])
        }
        XCTAssertEqual(targets.map(\.row.gmailThreadId), ["partly"])
        XCTAssertEqual(targets.first?.trashedIds, ["p1"])
        XCTAssertEqual(targets.first?.row.inTrash, false, "the live row, not the Trash copy")
    }

    /// The local edit a running pass lays over the messages: only the named ones.
    func testPerMessageEditChangesOnlyTheNamedMessages() {
        let change = RemoteThreadChange.modifyMessages(ids: ["a"], add: ["INBOX"], remove: ["TRASH"])
        let a = SyncEngine.applyingLocalEdit(change, to: msg("a", minutesAgo: 1, labels: "TRASH"))
        let b = SyncEngine.applyingLocalEdit(change, to: msg("b", minutesAgo: 1, labels: "TRASH"))
        XCTAssertEqual(a.labelIds, "INBOX")
        XCTAssertEqual(b.labelIds, "TRASH")
    }

    // MARK: - Offline queue folding

    /// A trash queued offline, then its undo. The trash is never sent, so
    /// a reply arriving before the replay is not trashed. The undo goes out
    /// whole: its un-trash reaches every message of the thread, so the
    /// earlier deletions must be put back (also right when the trash did
    /// reach Gmail and only its response was lost).
    func testQueuedTrashThenUndoNeverSendsTheTrash() async throws {
        let undo = ThreadUndo.undoTrashRemote(
            wasInInbox: true, before: .init(liveIds: ["b"], trashedIds: ["a"]))
        let merged = RemoteThreadChange.trash.merged(with: undo)
        XCTAssertEqual(merged, undo)
        let stub = StubThreadEditing()
        try await RemoteThreadSend.send(merged, via: stub, gmailThreadId: "t1")
        let calls = await stub.calls
        XCTAssertFalse(calls.contains(.trash(id: "t1")))
        XCTAssertEqual(calls, [.modify(id: "t1", add: ["INBOX"], remove: ["TRASH"]),
                               .modifyMessages(ids: ["a"], add: ["TRASH"], remove: ["INBOX"])])
        // Without earlier deletions, as on main: one modify, no trash.
        XCTAssertEqual(RemoteThreadChange.trash.merged(
            with: ThreadUndo.undoTrashRemote(wasInInbox: true,
                                             before: .init(liveIds: ["b"], trashedIds: []))),
                       .modify(add: ["INBOX"], remove: ["TRASH"]))
        // A restore after a queued trash: both, in order (the trash may
        // already have reached Gmail).
        let restore = RemoteThreadChange.modifyMessages(ids: ["a"], add: ["Label_1"],
                                                        remove: ["INBOX", "TRASH"])
        XCTAssertEqual(RemoteThreadChange.trash.merged(with: restore), .sequence([.trash, restore]))
    }

    /// A trash flushed (sent) before the undo: the undo is queued alone and
    /// sends the thread un-trash, which also brings back a reply that
    /// arrived after the last sync, then re-trashes the earlier deletions.
    func testUndoAfterTheTrashWasSentIsSentOnItsOwn() async throws {
        let undo = ThreadUndo.undoTrashRemote(
            wasInInbox: false, before: .init(liveIds: ["b"], trashedIds: ["a"]))
        let stub = StubThreadEditing()
        try await RemoteThreadSend.send(undo, via: stub, gmailThreadId: "t1")
        let calls = await stub.calls
        XCTAssertEqual(calls, [.modify(id: "t1", add: [], remove: ["TRASH"]),
                               .modifyMessages(ids: ["a"], add: ["TRASH"], remove: [])])
    }

    func testFoldingKeepsEveryStep() {
        let star = RemoteThreadChange.modify(add: ["STARRED"])
        let restore = RemoteThreadChange.modifyMessages(ids: ["a"], remove: ["TRASH"])
        let seq = star.merged(with: restore)
        XCTAssertEqual(seq, .sequence([star, restore]))
        // A later thread edit folds into a trailing thread edit only.
        XCTAssertEqual(seq.merged(with: .modify(remove: ["UNREAD"])),
                       .sequence([star, restore, .modify(remove: ["UNREAD"])]))
        XCTAssertEqual(RemoteThreadChange.sequence([restore, star]).merged(with: .modify(remove: ["STARRED"])),
                       restore, "a star toggled back cancels out")
        XCTAssertEqual(seq.merged(with: .trash), .trash)
        // Same ids fold into one request.
        XCTAssertEqual(restore.merged(with: .modifyMessages(ids: ["a"], add: ["INBOX"])),
                       .modifyMessages(ids: ["a"], add: ["INBOX"], remove: ["TRASH"]))
    }

    func testQueuedChangesSurviveTheRoundTrip() throws {
        let change = RemoteThreadChange.sequence([
            .trash, .modifyMessages(ids: ["a", "b"], add: ["INBOX"], remove: ["TRASH"])])
        let data = try JSONEncoder().encode(change)
        XCTAssertEqual(try JSONDecoder().decode(RemoteThreadChange.self, from: data), change)
        XCTAssertFalse(change.isEmpty)
        XCTAssertTrue(RemoteThreadChange.modifyMessages(ids: [], add: ["INBOX"]).isEmpty)
    }

    // MARK: - Queue payloads and replay

    /// Payloads queued by builds before this change still decode.
    func testOlderQueuedPayloadsDecode() throws {
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(RemoteThreadChange.self, from: Data(#"{"trash":{}}"#.utf8)),
                       .trash)
        XCTAssertEqual(try decoder.decode(
            RemoteThreadChange.self,
            from: Data(#"{"modify":{"add":["STARRED"],"remove":[]}}"#.utf8)),
                       .modify(add: ["STARRED"], remove: []))
    }

    /// A sequence that fails at its second step is queued whole and
    /// replayed from the start: every step is a label change, so sending
    /// the first again is harmless, and the second goes out on the replay.
    func testASequenceFailingAtStepTwoIsReplayedWhole() async throws {
        let change = RemoteThreadChange.sequence([
            .modify(add: [], remove: ["TRASH"]),
            .modifyMessages(ids: ["a"], add: ["TRASH"], remove: [])])
        let stub = FailingOnceThreadEditing(failAtCall: 2)
        do {
            try await RemoteThreadSend.send(change, via: stub, gmailThreadId: "t1")
            XCTFail("the second step fails")
        } catch {}
        try await RemoteThreadSend.send(change, via: stub, gmailThreadId: "t1")
        let calls = await stub.calls
        XCTAssertEqual(calls, [.modify(id: "t1", add: [], remove: ["TRASH"]),
                               .modifyMessages(ids: ["a"], add: ["TRASH"], remove: []),
                               .modify(id: "t1", add: [], remove: ["TRASH"]),
                               .modifyMessages(ids: ["a"], add: ["TRASH"], remove: [])])
    }
}

/// Records every call; the call numbered `failAtCall` (1-based) throws once.
actor FailingOnceThreadEditing: GmailThreadEditing {
    private(set) var calls: [StubThreadEditing.Call] = []
    private let failAtCall: Int

    init(failAtCall: Int) { self.failAtCall = failAtCall }

    private func record(_ call: StubThreadEditing.Call) throws {
        calls.append(call)
        if calls.count == failAtCall { throw URLError(.badServerResponse) }
    }

    func modifyThread(id: String, add: [String], remove: [String]) async throws {
        try record(.modify(id: id, add: add, remove: remove))
    }

    func trashThread(id: String) async throws {
        try record(.trash(id: id))
    }

    func modifyMessages(ids: [String], add: [String], remove: [String]) async throws {
        try record(.modifyMessages(ids: ids, add: add, remove: remove))
    }
}

/// L3 and L4: undo after a restore, and a batch Gmail refuses for one id.
final class TrashUndoEdgeTests: XCTestCase {
    /// A message restored from the Trash but not yet seen by a sync still
    /// reads TRASH in its row: a later trash and undo must not re-trash it.
    func testUndoAfterARestoreDoesNotReTrashTheRestoredMessage() {
        let stored = ThreadUndo.TrashState(liveIds: ["b"], trashedIds: ["m1", "m2"])
        let state = stored.restoring(["m1"])
        XCTAssertEqual(state, .init(liveIds: ["b", "m1"], trashedIds: ["m2"]))
        XCTAssertEqual(ThreadUndo.undoTrashRemote(wasInInbox: false, before: state),
                       .sequence([.modify(add: [], remove: ["TRASH"]),
                                  .modifyMessages(ids: ["m2"], add: ["TRASH"], remove: [])]))
        XCTAssertEqual(stored.restoring([]), stored)
    }

    /// One earlier-trashed id Gmail no longer has fails the whole batch:
    /// the others are re-trashed one by one, the missing one skipped.
    func testARefusedBatchIsRetriedPerIdSkippingMissingOnes() async throws {
        let client = ScriptedThreadEditing { call in
            if case .modifyMessages(let ids, _, _) = call {
                if ids.count > 1 { throw GmailError.http(400, "invalid id") }
                if ids == ["gone"] { throw GmailError.http(404, "not found") }
            }
        }
        let change = RemoteThreadChange.modifyMessages(ids: ["a", "gone", "b"],
                                                       add: ["TRASH"], remove: [])
        try await RemoteThreadSend.send(change, via: client, gmailThreadId: "t1")
        let calls = await client.calls
        XCTAssertEqual(calls, [.modifyMessages(ids: ["a", "gone", "b"], add: ["TRASH"], remove: []),
                               .modifyMessages(ids: ["a"], add: ["TRASH"], remove: []),
                               .modifyMessages(ids: ["gone"], add: ["TRASH"], remove: []),
                               .modifyMessages(ids: ["b"], add: ["TRASH"], remove: [])])
    }

    /// An error that is not about the ids (quota, server) is not split up:
    /// it goes to the caller, which queues the change.
    func testOtherFailuresAreNotSplit() async throws {
        let client = ScriptedThreadEditing { _ in throw GmailError.http(503, "busy") }
        do {
            try await RemoteThreadSend.send(
                .modifyMessages(ids: ["a", "b"], add: ["TRASH"]), via: client, gmailThreadId: "t1")
            XCTFail("the failure reaches the caller")
        } catch {}
        let calls = await client.calls
        XCTAssertEqual(calls.count, 1)
    }
}

/// Records every call and lets the test decide, per call, whether it throws.
actor ScriptedThreadEditing: GmailThreadEditing {
    private(set) var calls: [StubThreadEditing.Call] = []
    private let script: @Sendable (StubThreadEditing.Call) throws -> Void

    init(_ script: @escaping @Sendable (StubThreadEditing.Call) throws -> Void) {
        self.script = script
    }

    private func record(_ call: StubThreadEditing.Call) throws {
        calls.append(call)
        try script(call)
    }

    func modifyThread(id: String, add: [String], remove: [String]) async throws {
        try record(.modify(id: id, add: add, remove: remove))
    }

    func trashThread(id: String) async throws {
        try record(.trash(id: id))
    }

    func modifyMessages(ids: [String], add: [String], remove: [String]) async throws {
        try record(.modifyMessages(ids: ids, add: add, remove: remove))
    }
}

