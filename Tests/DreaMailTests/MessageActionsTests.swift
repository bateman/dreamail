import XCTest
import GRDB

/// The actions on one message of an open conversation (Gmail on the web:
/// star, reply, reply all and the "More" menu), the message a conversation
/// opens on, and the per-message label path they share with the Trash
/// view's restore (`messages.batchModify` on explicit ids, never a delete).
final class MessageActionsTests: XCTestCase {
    private let account = "you@example.com"

    private func msg(_ id: String, thread: String = "t1", minutesAgo: Double, labels: String,
                     unread: Bool = false) -> Message {
        Message(id: "\(account):\(id)", accountId: account, gmailId: id,
                threadId: "\(account):\(thread)", fromHeader: "Ann <ann@example.com>",
                toHeader: account, ccHeader: "", bccHeader: "", subject: "Plans",
                date: Date(timeIntervalSinceNow: -minutesAgo * 60),
                snippet: "snippet-\(id)", bodyText: "body-\(id)", bodyHTML: nil,
                messageIdHeader: "<\(id)@example.com>", referencesHeader: "",
                labelIds: labels, isUnread: unread, hasAttachment: false)
    }

    private var threadId: String { "\(account):t1" }

    private func makeDB(_ messages: [Message]) throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: self.account, displayName: "P", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
            for m in messages { try m.insert(db) }
            if !messages.isEmpty {
                try SyncEngine.deriveThreads(db, for: [self.threadId], accountId: self.account)
            }
        }
        return q
    }

    private func thread(_ q: DatabaseQueue) throws -> MailThread {
        try XCTUnwrap(try q.read { try MailThread.fetchOne($0, key: self.threadId) })
    }

    private func shown(_ q: DatabaseQueue) throws -> [String] {
        try q.read { db in
            try ThreadDetailRepository.fetchPayload(threadId: self.threadId, db: db).messages.map(\.gmailId)
        }
    }

    private func labels(_ q: DatabaseQueue, _ id: String) throws -> String {
        try XCTUnwrap(try q.read { try Message.fetchOne($0, key: "\(self.account):\(id)") }).labelIds
    }

    // MARK: - The "More" menu

    private let typical = MessageActions.Context(
        canReplyAll: true, fromSelf: false, senderBlocked: false,
        threadInSpam: false, isTrashed: false)

    func testMenuKeepsGmailsOrderAndWording() {
        let titles = MessageActions.menuItems(typical).map {
            MessageActions.title($0, senderName: "Ann")
        }
        XCTAssertEqual(titles, [
            "Reply", "Reply to all", "Forward", "Filter messages like this", "Print",
            "Delete this message", "Block \"Ann\"", "Report spam", "Show original",
            "Download message", "Mark unread from here",
        ])
    }

    func testLeftOutItemsAreNotShownAtAll() {
        for context in [typical,
                        MessageActions.Context(canReplyAll: false, fromSelf: true, senderBlocked: false,
                                               threadInSpam: true, isTrashed: true)] {
            let titles = MessageActions.menuItems(context).map {
                MessageActions.title($0, senderName: "Ann").lowercased()
            }
            for gone in ["phishing", "translate", "contacts"] {
                XCTAssertFalse(titles.contains { $0.contains(gone) }, gone)
            }
        }
    }

    func testMenuFollowsTheMessage() {
        var c = typical
        c.canReplyAll = false
        c.fromSelf = true
        c.threadInSpam = true
        c.isTrashed = true
        let items = MessageActions.menuItems(c)
        XCTAssertFalse(items.contains(.replyAll), "as the header: only when it differs from Reply")
        XCTAssertFalse(items.contains(.blockSender), "never one's own address")
        XCTAssertFalse(items.contains(.deleteMessage), "already in the Trash")
        XCTAssertTrue(items.contains(.reportNotSpam))
        XCTAssertFalse(items.contains(.reportSpam))
        c = typical
        c.senderBlocked = true
        XCTAssertTrue(MessageActions.menuItems(c).contains(.unblockSender))
        XCTAssertFalse(MessageActions.menuItems(c).contains(.blockSender))
    }

    // MARK: - The message a conversation opens on

    func testOpensOnTheNewestStarredMessage() {
        let messages = [msg("a", minutesAgo: 60, labels: "INBOX STARRED"),
                        msg("b", minutesAgo: 40, labels: "INBOX STARRED"),
                        msg("c", minutesAgo: 20, labels: "INBOX"),
                        msg("d", minutesAgo: 10, labels: "DRAFT STARRED")]
        XCTAssertEqual(MessageActions.starredOpenTarget(in: messages)?.gmailId, "b",
                       "the newest starred, drafts left out")
        let roles = ThreadMessageRoles(messages: messages)
        XCTAssertEqual(roles.openTargetId, "\(account):b")
        XCTAssertEqual(roles.lastNonDraftId, "\(account):c", "unchanged")
        XCTAssertEqual(ThreadRefresh.initialScrolledMessageId(in: messages), "\(account):b")
        XCTAssertEqual(MessageExpandPolicy.initialExpandedIds(
            policy: .single, nonDraftIds: roles.nonDraftIds, lastNonDraftId: roles.openTargetId),
                       ["\(account):b"])
    }

    func testWithoutStarredMessagesTheNewestStillOpens() {
        let messages = [msg("a", minutesAgo: 60, labels: "INBOX"),
                        msg("b", minutesAgo: 20, labels: "INBOX"),
                        msg("t", minutesAgo: 10, labels: "TRASH STARRED")]
        XCTAssertNil(MessageActions.starredOpenTarget(in: messages), "a trashed star does not count")
        let roles = ThreadMessageRoles(messages: Array(messages.prefix(2)))
        XCTAssertEqual(roles.openTargetId, roles.lastNonDraftId)
        XCTAssertEqual(ThreadRefresh.initialScrolledMessageId(in: Array(messages.prefix(2))),
                       "\(account):b")
    }

    // MARK: - Pure helpers

    func testMarkUnreadFromHereTakesThisAndTheLaterMessages() {
        let messages = [msg("a", minutesAgo: 60, labels: "INBOX"),
                        msg("b", minutesAgo: 40, labels: "INBOX"),
                        msg("c", minutesAgo: 30, labels: "INBOX UNREAD", unread: true),
                        msg("d", minutesAgo: 20, labels: "DRAFT"),
                        msg("e", minutesAgo: 10, labels: "INBOX")]
        XCTAssertEqual(MessageActions.unreadFromHereIds(in: messages, from: "\(account):b"),
                       ["b", "e"], "already unread and drafts left out")
        XCTAssertEqual(MessageActions.unreadFromHereIds(in: messages, from: "\(account):x"), [])
    }

    func testDownloadFilename() {
        XCTAssertEqual(MessageActions.downloadFilename(subject: "Plans"), "Plans.eml")
        XCTAssertEqual(MessageActions.downloadFilename(subject: "  "), "message.eml")
        XCTAssertFalse(MessageActions.downloadFilename(subject: "a/b").contains("/"))
    }

    func testPrintUsesTextNeverHTML() {
        var m = msg("a", minutesAgo: 1, labels: "INBOX")
        m.bodyText = ""
        m.bodyHTML = "<p>Hello <img src=\"https://tracker.example/p.gif\"></p>"
        let text = MessageActions.printableText(m)
        XCTAssertTrue(text.contains("Hello"))
        XCTAssertFalse(text.contains("tracker.example"))
        XCTAssertTrue(text.contains("From: Ann <ann@example.com>"))
    }

    // MARK: - Header controls fit the narrowest pane

    func testHeaderControlsLeaveTheSenderRoomOnTheNarrowestPane() {
        // The narrowest reading pane beside the list: the three-pane
        // threshold less the sidebar's and the list's minimum widths
        // (`ContentView`). The date then takes its compact form.
        let narrowest = MailLayout.threePaneMinimumWidth - 200 - 420
        for scale in [1.0, 1.3] {
            let m = ThreadMessageRowMetrics(fontScale: scale)
            let column = m.textColumnWidth(rowWidth: narrowest)
            let controls = m.headerControlsWidth(count: 4)
            let compactDate: CGFloat = 60 * CGFloat(scale)
            XCTAssertGreaterThan(column - controls - compactDate - 8, 80 * CGFloat(scale),
                                 "the sender keeps room for a name at scale \(scale)")
            XCTAssertEqual(MessageRowDateStyle.forTextColumn(width: column - controls, fontScale: scale),
                           .compact)
        }
        XCTAssertEqual(ThreadMessageRowMetrics(fontScale: 1).headerControlsWidth(count: 0), 0)
    }

    // MARK: - Delete this message (DEC-081)

    func testDeletingOneMessageKeepsTheConversationInTheInbox() throws {
        let q = try makeDB([msg("a", minutesAgo: 60, labels: "INBOX"),
                            msg("b", minutesAgo: 10, labels: "INBOX")])
        let before = try thread(q)
        try q.write { db in
            try TrashedMessages.applyMessageEdit(db, thread: before, ids: ["b"],
                                                 add: ["TRASH"], remove: [])
        }
        let after = try thread(q)
        XCTAssertTrue(after.inInbox, "still in the Inbox")
        XCTAssertFalse(after.inTrash)
        XCTAssertEqual(after.messageCount, 1)
        XCTAssertEqual(after.snippet, "snippet-a")
        XCTAssertEqual(try shown(q), ["a"], "the deleted message leaves the conversation")
        XCTAssertTrue(SyncEngine.labelIdsContain(try labels(q, "b"), "TRASH"))
        // Undo: back, in the Inbox as it was.
        try q.write { db in
            try TrashedMessages.applyMessageEdit(db, thread: after, ids: ["b"],
                                                 add: ["INBOX"], remove: ["TRASH"])
        }
        XCTAssertEqual(try shown(q), ["a", "b"])
        XCTAssertEqual(try thread(q).messageCount, 2)
        XCTAssertTrue(try thread(q).inInbox)
    }

    func testAMessageEditKeepsTheThreadsPendingEdits() throws {
        let q = try makeDB([msg("a", minutesAgo: 60, labels: "INBOX UNREAD", unread: true),
                            msg("b", minutesAgo: 10, labels: "INBOX UNREAD", unread: true)])
        // Read on open: a thread-level edit, on the thread row only.
        let stored = try thread(q)
        var read = stored
        read.isUnread = false
        try q.write { db in try OptimisticThreadWrite.updateChangedColumns(db, from: stored, to: read) }
        try q.write { db in
            try TrashedMessages.applyMessageEdit(db, thread: read, ids: ["a"],
                                                 add: ["STARRED"], remove: [])
        }
        let after = try thread(q)
        XCTAssertFalse(after.isUnread, "starring a message must not bring the unread state back")
        XCTAssertTrue(after.isStarred, "the conversation shows as starred")
        XCTAssertTrue(SyncEngine.labelIdsContain(try labels(q, "a"), "STARRED"))
        XCTAssertFalse(SyncEngine.labelIdsContain(try labels(q, "b"), "STARRED"), "that message only")
        // Unstar the only starred message: the conversation is not starred.
        try q.write { db in
            try TrashedMessages.applyMessageEdit(db, thread: after, ids: ["a"],
                                                 add: [], remove: ["STARRED"])
        }
        XCTAssertFalse(try thread(q).isStarred)
    }

    func testMarkUnreadFromHereMarksTheConversationUnread() throws {
        let q = try makeDB([msg("a", minutesAgo: 60, labels: "INBOX"),
                            msg("b", minutesAgo: 10, labels: "INBOX")])
        let row = try thread(q)
        try q.write { db in
            try TrashedMessages.applyMessageEdit(db, thread: row, ids: ["b"],
                                                 add: ["UNREAD"], remove: [])
        }
        XCTAssertTrue(try thread(q).isUnread)
        XCTAssertFalse(SyncEngine.labelIdsContain(try labels(q, "a"), "UNREAD"))
    }

    // MARK: - What reaches Gmail, offline and refused

    func testDeleteSendsExactlyThatMessageAndNoDelete() async throws {
        let stub = StubThreadEditing()
        try await RemoteThreadSend.send(.modifyMessages(ids: ["b"], add: ["TRASH"]),
                                        via: stub, gmailThreadId: "t1")
        let calls = await stub.calls
        XCTAssertEqual(calls, [.modifyMessages(ids: ["b"], add: ["TRASH"], remove: [])])
    }

    func testOfflineDeleteThenUndoFoldsInTheQueue() throws {
        let q = try makeDB([])
        try q.write { db in
            try PendingThreadOp.enqueue(db, accountId: self.account, gmailThreadId: "t1",
                                        change: .modifyMessages(ids: ["b"], add: ["TRASH"]))
            try PendingThreadOp.enqueue(db, accountId: self.account, gmailThreadId: "t1",
                                        change: .modifyMessages(ids: ["b"], add: ["INBOX"],
                                                                remove: ["TRASH"]))
        }
        let queued = try q.read { try PendingThreadOp.fetchOne($0)?.change }
        XCTAssertEqual(queued, .modifyMessages(ids: ["b"], add: ["INBOX"], remove: []),
                       "the trash is never sent once undone")
    }

    func testARefusedMessageEditIsUndoneLocally() throws {
        let q = try makeDB([msg("a", minutesAgo: 60, labels: "INBOX"),
                            msg("b", minutesAgo: 10, labels: "INBOX")])
        let refused = RemoteThreadChange.modifyMessages(ids: ["b"], add: ["TRASH"])
        XCTAssertEqual(TrashedMessages.storedRestores(in: refused).map(\.ids), [["b"]])
        let row = try thread(q)
        try q.write { db in
            try TrashedMessages.applyMessageEdit(db, thread: row, ids: ["b"],
                                                 add: ["TRASH"], remove: [])
        }
        try q.write { db in
            XCTAssertTrue(try TrashedMessages.revertStoredRestores(db, accountId: self.account,
                                                                   change: refused))
            try OptimisticThreadWrite.rederiveOrDelete(db, threadId: self.threadId, accountId: self.account)
        }
        XCTAssertEqual(try shown(q), ["a", "b"], "Gmail kept it: it is shown again")
    }

    func testTheUndoReTrashStepIsStillNotAStoredEdit() {
        let undo = ThreadUndo.undoTrashRemote(
            wasInInbox: false, before: .init(liveIds: ["b"], trashedIds: ["a"]))
        XCTAssertTrue(TrashedMessages.storedRestores(in: undo).isEmpty)
        let star = RemoteThreadChange.modifyMessages(ids: ["b"], add: ["STARRED"])
        XCTAssertEqual(TrashedMessages.storedRestores(in: undo.merged(with: star)).map(\.ids), [["b"]],
                       "a later message edit in the same queue row is found")
    }
}
