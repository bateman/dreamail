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

    /// F5: a trash that reached nothing (all already trashed, e.g. `#` in
    /// the Trash view) has nothing to undo: nothing is sent, nothing
    /// deleted earlier comes back.
    func testUndoOfATrashThatReachedNothingSendsNothing() async throws {
        let undo = ThreadUndo.undoTrashRemote(
            wasInInbox: false, before: .init(liveIds: [], trashedIds: ["a", "b"]))
        XCTAssertTrue(undo.isEmpty)
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

    /// F3: a trash queued offline, then its undo. The trash is never sent:
    /// a reply arriving before the replay is not trashed. The re-trash of
    /// the earlier deletions only repeats what Gmail already holds.
    func testQueuedTrashThenUndoNeverSendsTheTrash() async throws {
        let undo = ThreadUndo.undoTrashRemote(
            wasInInbox: true, before: .init(liveIds: ["b"], trashedIds: ["a"]))
        let merged = RemoteThreadChange.trash.merged(with: undo)
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
        // A restore of a thread whose trash was never sent: only the restore.
        let restore = RemoteThreadChange.modifyMessages(ids: ["a"], add: ["Label_1"],
                                                        remove: ["INBOX", "TRASH"])
        XCTAssertEqual(RemoteThreadChange.trash.merged(with: restore), restore)
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
}
