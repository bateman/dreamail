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
            "Reply", "Reply to all", "Forward", "Filter messages like this",
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
            for gone in ["phishing", "translate", "contacts", "print"] {
                XCTAssertFalse(titles.contains { $0.contains(gone) }, gone)
            }
        }
    }

    func testMenuFollowsTheMessage() {
        var c = typical
        c.canReplyAll = false
        c.fromSelf = true
        let items = MessageActions.menuItems(c)
        XCTAssertFalse(items.contains(.replyAll), "as the header: only when it differs from Reply")
        XCTAssertFalse(items.contains(.blockSender), "never one's own address")
        c = typical
        c.threadInSpam = true
        XCTAssertTrue(MessageActions.menuItems(c).contains(.reportNotSpam))
        XCTAssertFalse(MessageActions.menuItems(c).contains(.reportSpam))
        c = typical
        c.senderBlocked = true
        XCTAssertTrue(MessageActions.menuItems(c).contains(.unblockSender))
        XCTAssertFalse(MessageActions.menuItems(c).contains(.blockSender))
    }

    /// From the Trash view: nothing that reaches the conversation's live
    /// messages, which are not on screen (DEC-081).
    func testATrashedMessageOffersNoConversationAction() {
        for spam in [false, true] {
            var c = typical
            c.isTrashed = true
            c.threadInSpam = spam
            let items = MessageActions.menuItems(c)
            XCTAssertFalse(items.contains(.deleteMessage), "already in the Trash")
            XCTAssertFalse(items.contains(.reportSpam))
            XCTAssertFalse(items.contains(.reportNotSpam))
            XCTAssertTrue(items.contains(.markUnreadFromHere), "acts on the trashed messages shown")
            XCTAssertTrue(items.contains(.blockSender), "sender-level")
        }
    }

    // MARK: - The message a conversation opens on

    private func ids(_ names: [String]) -> [String] { names.map { "\(account):\($0)" } }

    func testWithoutStarredMessagesTheNewestStillOpens() {
        let messages = [msg("a", minutesAgo: 60, labels: "INBOX"),
                        msg("b", minutesAgo: 30, labels: "INBOX UNREAD", unread: true),
                        msg("c", minutesAgo: 20, labels: "INBOX")]
        XCTAssertNil(ConversationOpenTarget.target(in: messages))
        let roles = ThreadMessageRoles(messages: messages)
        XCTAssertEqual(roles.openExpandedIds, ["\(account):c"], "as before: the newest only")
        XCTAssertEqual(roles.scrollTargetId, "\(account):c")
        XCTAssertEqual(ThreadRefresh.initialScrolledMessageId(in: messages), "\(account):c")
        XCTAssertEqual(ThreadRefresh.initialBodyLoadSeedIds(in: messages), ["\(account):c"])
    }

    func testOldStarAndNewUnreadMailOpensOnTheNewMail() {
        let messages = [msg("a", minutesAgo: 60, labels: "INBOX STARRED"),
                        msg("b", minutesAgo: 40, labels: "INBOX"),
                        msg("c", minutesAgo: 30, labels: "INBOX UNREAD", unread: true),
                        msg("d", minutesAgo: 20, labels: "INBOX UNREAD", unread: true),
                        msg("e", minutesAgo: 10, labels: "INBOX")]
        let target = ConversationOpenTarget.target(in: messages)
        XCTAssertEqual(target?.expanded, ids(["a", "c", "d", "e"]),
                       "the star, every unread message and the newest")
        XCTAssertEqual(target?.scroll, "\(account):c", "the oldest unread newer than the star")
        let roles = ThreadMessageRoles(messages: messages)
        XCTAssertEqual(roles.openExpandedIds, Set(ids(["a", "c", "d", "e"])))
        XCTAssertEqual(ThreadRefresh.initialScrolledMessageId(in: messages), "\(account):c")
        XCTAssertEqual(MessageExpandPolicy.initialExpandedIds(
            policy: .single, nonDraftIds: roles.nonDraftIds, lastNonDraftId: roles.lastNonDraftId,
            openIds: roles.openExpandedIds), Set(ids(["a", "c", "d", "e"])))
        XCTAssertEqual(Set(ThreadRefresh.initialBodyLoadSeedIds(in: messages)),
                       Set(ids(["a", "c", "d", "e"])), "their bodies arrive with the payload")
        // One card fills the pane while its body loads: the scroll target.
        for id in ids(["a", "c", "d", "e"]) {
            XCTAssertEqual(MessageExpandPolicy.fillsPane(
                id: id, policy: .single, expanded: roles.openExpandedIds,
                lastNonDraftId: roles.lastNonDraftId, scrollTargetId: roles.scrollTargetId),
                           id == "\(account):c", id)
        }
    }

    func testUnreadMailOlderThanTheStarOpensButTheStarLeads() {
        let messages = [msg("a", minutesAgo: 60, labels: "INBOX UNREAD", unread: true),
                        msg("b", minutesAgo: 40, labels: "INBOX STARRED"),
                        msg("c", minutesAgo: 10, labels: "INBOX")]
        let target = ConversationOpenTarget.target(in: messages)
        XCTAssertEqual(target?.expanded, ids(["a", "b", "c"]))
        XCTAssertEqual(target?.scroll, "\(account):b")
    }

    func testStarOnTheLastMessage() {
        let messages = [msg("a", minutesAgo: 60, labels: "INBOX"),
                        msg("b", minutesAgo: 10, labels: "INBOX STARRED")]
        let target = ConversationOpenTarget.target(in: messages)
        XCTAssertEqual(target?.expanded, ids(["b"]))
        XCTAssertEqual(target?.scroll, "\(account):b")
    }

    func testSeveralStarsOpenOnTheNewestStarred() {
        let messages = [msg("a", minutesAgo: 60, labels: "INBOX STARRED"),
                        msg("b", minutesAgo: 40, labels: "INBOX STARRED"),
                        msg("c", minutesAgo: 10, labels: "INBOX")]
        let target = ConversationOpenTarget.target(in: messages)
        XCTAssertEqual(target?.expanded, ids(["b", "c"]))
        XCTAssertEqual(target?.scroll, "\(account):b")
    }

    func testDraftsNeverCount() {
        let messages = [msg("a", minutesAgo: 60, labels: "INBOX STARRED"),
                        msg("b", minutesAgo: 30, labels: "INBOX"),
                        msg("d", minutesAgo: 10, labels: "DRAFT STARRED UNREAD", unread: true)]
        let target = ConversationOpenTarget.target(in: messages)
        XCTAssertEqual(target?.expanded, ids(["a", "b"]), "the newest non-draft, not the draft")
        XCTAssertEqual(target?.scroll, "\(account):a")
        XCTAssertNil(ConversationOpenTarget.target(in: [msg("d", minutesAgo: 1, labels: "DRAFT STARRED")]))
    }

    func testATrashedStarDoesNotCount() {
        let messages = [msg("a", minutesAgo: 60, labels: "INBOX"),
                        msg("t", minutesAgo: 30, labels: "TRASH STARRED"),
                        msg("b", minutesAgo: 20, labels: "INBOX")]
        XCTAssertNil(ConversationOpenTarget.target(in: messages))
    }

    // MARK: - Pure helpers

    /// Read on open writes only the thread row: a message row can still
    /// say unread. It is marked all the same.
    func testMarkUnreadFromHereTakesThisAndTheLaterMessages() {
        let messages = [msg("a", minutesAgo: 60, labels: "INBOX"),
                        msg("b", minutesAgo: 40, labels: "INBOX"),
                        msg("c", minutesAgo: 30, labels: "INBOX UNREAD", unread: true),
                        msg("d", minutesAgo: 20, labels: "DRAFT"),
                        msg("e", minutesAgo: 10, labels: "INBOX")]
        XCTAssertEqual(MessageActions.unreadFromHereIds(in: messages, from: "\(account):b"),
                       ["b", "c", "e"], "drafts left out, rows that say unread kept")
        XCTAssertEqual(MessageActions.unreadFromHereIds(in: messages, from: "\(account):x"), [])
        let lone = [msg("a", minutesAgo: 5, labels: "INBOX UNREAD", unread: true)]
        XCTAssertEqual(MessageActions.unreadFromHereIds(in: lone, from: "\(account):a"), ["a"])
    }

    func testFilterPrefillTakesOnlyAPlainAddress() {
        XCTAssertEqual(MessageActions.filterFromAddress("Ann <ann@example.com>"), "ann@example.com")
        XCTAssertEqual(MessageActions.filterFromAddress("ann.b+news@mail.example.com"),
                       "ann.b+news@mail.example.com")
        for crafted in ["\"a b\"@example.com", "a@example.com OR from:b@example.com",
                        "{a@example.com b@example.com}", "a(x)@example.com", "-a@example.com",
                        "a@@example.com", "a@example", "@example.com", "a@example.com\"",
                        "Ann <a@b@example.com>", "a@exa mple.com", "a@.example.com",
                        "Undisclosed recipients:;", ""] {
            let prefill = MessageActions.filterFromAddress(crafted)
            XCTAssertTrue(prefill.isEmpty || !prefill.contains(where: { " \"(){}:".contains($0) }),
                          crafted)
            if crafted.contains(" OR ") || crafted.contains("{") || crafted.contains("\"")
                || crafted.contains("(") || crafted.contains("@@") || crafted.hasPrefix("-") {
                XCTAssertEqual(prefill, "", crafted)
            }
        }
    }

    func testDownloadFilename() {
        XCTAssertEqual(MessageActions.downloadFilename(subject: "Plans"), "Plans.eml")
        XCTAssertEqual(MessageActions.downloadFilename(subject: "  "), "message.eml")
        XCTAssertEqual(MessageActions.downloadFilename(subject: "a/b: c"), "a-b- c.eml",
                       "separators replaced, nothing kept only from the tail")
        XCTAssertEqual(MessageActions.downloadFilename(subject: "...hidden"), "hidden.eml")
        XCTAssertEqual(MessageActions.downloadFilename(subject: "in\u{202E}voice\u{0007}\n"), "invoice.eml",
                       "bidi override and control characters dropped")
        let long = MessageActions.downloadFilename(subject: String(repeating: "é", count: 400))
        XCTAssertTrue(long.hasSuffix(".eml"))
        XCTAssertLessThanOrEqual(long.utf8.count, MessageActions.filenameBaseByteLimit + 4)
        XCTAssertLessThanOrEqual(MessageActions.downloadFilename(
            subject: String(repeating: "👩‍👩‍👧", count: 100)).utf8.count, 255)
    }

    func testOriginalPreviewIsCutByBytes() {
        let small = Data("Subject: hi\r\n\r\nbody".utf8)
        XCTAssertEqual(MessageActions.originalPreview(small, limit: 1_000).text,
                       "Subject: hi\r\n\r\nbody")
        XCTAssertFalse(MessageActions.originalPreview(small, limit: 1_000).truncated)
        // One grapheme of 50 000 combining marks is still cut at the limit.
        let stuffed = Data(("e" + String(repeating: "\u{0301}", count: 50_000)).utf8)
        let preview = MessageActions.originalPreview(stuffed, limit: 1_000)
        XCTAssertTrue(preview.truncated)
        XCTAssertLessThanOrEqual(preview.text.utf8.count, 1_000 + 3)
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

    // MARK: - The store's plans, applied to the database

    private func state(_ q: DatabaseQueue, _ id: String) throws -> MessageActionPlan.State {
        let m = try XCTUnwrap(try q.read { try Message.fetchOne($0, key: "\(self.account):\(id)") })
        return try XCTUnwrap(try q.read { try MessageActionPlan.State.load($0, message: m) })
    }

    private func apply(_ q: DatabaseQueue, _ edit: MessageActionPlan.Edit) throws {
        let row = try thread(q)
        try q.write { db in
            try TrashedMessages.applyMessageEdit(db, thread: row, ids: edit.ids,
                                                 add: edit.add, remove: edit.remove)
        }
    }

    private func markRead(_ q: DatabaseQueue) throws {
        let stored = try thread(q)
        var read = stored
        read.isUnread = false
        try q.write { db in try OptimisticThreadWrite.updateChangedColumns(db, from: stored, to: read) }
    }

    func testDeletePlanTrashesThatMessageAndItsUndoRestoresIt() throws {
        let q = try makeDB([msg("a", minutesAgo: 60, labels: "INBOX"),
                            msg("b", minutesAgo: 10, labels: "INBOX STARRED")])
        guard case .message(let edit, let undo) = MessageActionPlan.delete(try state(q, "b")) else {
            return XCTFail("one message of two")
        }
        XCTAssertEqual(edit, .init(ids: ["b"], add: ["TRASH"]))
        XCTAssertEqual(undo, .init(ids: ["b"], add: ["INBOX"], remove: ["TRASH"]))
        try apply(q, edit)
        var row = try thread(q)
        XCTAssertTrue(row.inInbox)
        XCTAssertEqual(row.messageCount, 1)
        XCTAssertFalse(row.isStarred, "the starred message left the conversation")
        XCTAssertEqual(MessageActionPlan.delete(try state(q, "b")), .none, "already in the Trash")
        try apply(q, undo)
        row = try thread(q)
        XCTAssertEqual(row.messageCount, 2)
        XCTAssertTrue(row.isStarred)
        XCTAssertTrue(row.inInbox)
    }

    func testUndoDoesNotBringAnArchivedConversationBackToTheInbox() throws {
        let q = try makeDB([msg("a", minutesAgo: 60, labels: "INBOX"),
                            msg("b", minutesAgo: 10, labels: "INBOX")])
        // Archived on the thread row only, not yet on its messages.
        let stored = try thread(q)
        var archived = stored
        archived.inInbox = false
        try q.write { db in try OptimisticThreadWrite.updateChangedColumns(db, from: stored, to: archived) }
        guard case .message(_, let undo) = MessageActionPlan.delete(try state(q, "b")) else {
            return XCTFail("one message of two")
        }
        XCTAssertEqual(undo.add, [], "no INBOX: the conversation was archived")
    }

    func testDeletingTheLastMessageTrashesTheConversation() throws {
        let q = try makeDB([msg("a", minutesAgo: 60, labels: "TRASH"),
                            msg("b", minutesAgo: 10, labels: "INBOX")])
        XCTAssertEqual(MessageActionPlan.delete(try state(q, "b")), .conversation)
    }

    func testDeletingTheOnlyMessageBesideADraftKeepsTheDraft() throws {
        let q = try makeDB([msg("b", minutesAgo: 20, labels: "INBOX"),
                            msg("d", minutesAgo: 10, labels: "DRAFT")])
        guard case .message(let edit, _) = MessageActionPlan.delete(try state(q, "b")) else {
            return XCTFail("the draft stays: only the message goes")
        }
        XCTAssertEqual(edit.ids, ["b"])
        try apply(q, edit)
        XCTAssertEqual(try shown(q), ["d"], "the draft is still there")
        XCTAssertFalse(SyncEngine.labelIdsContain(try labels(q, "d"), "TRASH"))
        XCTAssertFalse(try thread(q).inTrash)
    }

    func testDraftsAndTrashedMessagesHaveNothingToDelete() throws {
        let q = try makeDB([msg("a", minutesAgo: 60, labels: "INBOX"),
                            msg("t", minutesAgo: 30, labels: "TRASH"),
                            msg("d", minutesAgo: 10, labels: "DRAFT")])
        XCTAssertEqual(MessageActionPlan.delete(try state(q, "t")), .none)
        XCTAssertEqual(MessageActionPlan.delete(try state(q, "d")), .none)
        XCTAssertNil(MessageActionPlan.toggleStar(try state(q, "d")), "no star on a draft")
    }

    func testStarTogglesFromTheStoredState() throws {
        let q = try makeDB([msg("a", minutesAgo: 60, labels: "INBOX"),
                            msg("b", minutesAgo: 10, labels: "INBOX")])
        let first = try XCTUnwrap(MessageActionPlan.toggleStar(try state(q, "a")))
        XCTAssertEqual(first, .init(ids: ["a"], add: ["STARRED"]))
        try apply(q, first)
        XCTAssertTrue(try thread(q).isStarred)
        // A second click, read after the first write: it undoes it.
        let second = try XCTUnwrap(MessageActionPlan.toggleStar(try state(q, "a")))
        XCTAssertEqual(second, .init(ids: ["a"], remove: ["STARRED"]))
        try apply(q, second)
        XCTAssertFalse(try thread(q).isStarred)
        XCTAssertEqual(try thread(q).messageCount, 2)
    }

    func testSpamIsRefusedFromATrashedMessage() throws {
        let q = try makeDB([msg("a", minutesAgo: 60, labels: "INBOX"),
                            msg("t", minutesAgo: 30, labels: "TRASH")])
        XCTAssertFalse(MessageActionPlan.allowsConversationAction(try state(q, "t")))
        XCTAssertTrue(MessageActionPlan.allowsConversationAction(try state(q, "a")))
    }

    /// Opened unread, so read on the thread row while both message rows
    /// still say unread; "from here" on the first marks both.
    func testMarkUnreadFromHereRightAfterOpeningUnreadMail() throws {
        let q = try makeDB([msg("a", minutesAgo: 60, labels: "INBOX"),
                            msg("b", minutesAgo: 10, labels: "INBOX UNREAD", unread: true)])
        try markRead(q)
        XCTAssertFalse(try thread(q).isUnread)
        let shownNow = try q.read { db in
            try ThreadDetailRepository.fetchPayload(threadId: self.threadId, db: db).messages
        }
        let ids = MessageActions.unreadFromHereIds(in: shownNow, from: "\(account):a")
        XCTAssertEqual(ids, ["a", "b"])
        try apply(q, .init(ids: ids, add: ["UNREAD"]))
        XCTAssertTrue(try thread(q).isUnread)
        XCTAssertTrue(SyncEngine.labelIdsContain(try labels(q, "a"), "UNREAD"))
        XCTAssertTrue(SyncEngine.labelIdsContain(try labels(q, "b"), "UNREAD"),
                      "the fold must not strip the message being marked")
    }

    func testMarkUnreadOnTheOnlyMessageJustOpened() throws {
        let q = try makeDB([msg("a", minutesAgo: 5, labels: "INBOX UNREAD", unread: true)])
        try markRead(q)
        let shownNow = try q.read { db in
            try ThreadDetailRepository.fetchPayload(threadId: self.threadId, db: db).messages
        }
        let ids = MessageActions.unreadFromHereIds(in: shownNow, from: "\(account):a")
        XCTAssertEqual(ids, ["a"], "something is sent")
        try apply(q, .init(ids: ids, add: ["UNREAD"]))
        XCTAssertTrue(try thread(q).isUnread)
    }

    /// A reply stored by a sync after the action read the thread row is
    /// not marked read by the fold (`applyMessageEdit` reads the row again).
    func testAReplyStoredMeanwhileStaysUnread() throws {
        let q = try makeDB([msg("a", minutesAgo: 60, labels: "INBOX")])
        let captured = try thread(q)
        try q.write { db in
            try self.msg("r", minutesAgo: 1, labels: "INBOX UNREAD", unread: true).insert(db)
            try SyncEngine.deriveThreads(db, for: [self.threadId], accountId: self.account)
        }
        try q.write { db in
            try TrashedMessages.applyMessageEdit(db, thread: captured, ids: ["a"],
                                                 add: ["STARRED"], remove: [])
        }
        XCTAssertTrue(SyncEngine.labelIdsContain(try labels(q, "r"), "UNREAD"))
        XCTAssertTrue(try thread(q).isUnread)
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
