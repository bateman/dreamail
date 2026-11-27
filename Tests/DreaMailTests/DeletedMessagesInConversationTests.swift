import XCTest
import GRDB

/// Gmail web's "N deleted messages in this conversation. View message" line
/// in a live conversation: its count and place, what "View" adds, that no
/// other reader of the conversation gets the deleted messages, and the
/// exact request "Restore" sends.
final class DeletedMessagesInConversationTests: XCTestCase {
    private let account = "you@example.com"
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func msg(_ id: String, thread: String = "t1", hour: Double, labels: String) -> Message {
        Message(id: "\(account):\(id)", accountId: account, gmailId: id,
                threadId: "\(account):\(thread)", fromHeader: "Ann <ann@example.com>",
                toHeader: account, ccHeader: "", bccHeader: "", subject: "Plans",
                date: base.addingTimeInterval(hour * 3600),
                snippet: "snippet-\(id)", bodyText: "", bodyHTML: nil,
                messageIdHeader: "<\(id)@example.com>", referencesHeader: "",
                labelIds: labels, isUnread: false, hasAttachment: false)
    }

    /// Two live messages around one deleted one, as in the demo's t11.
    private var conversation: [Message] {
        [msg("a", hour: 1, labels: "INBOX"),
         msg("b", hour: 2, labels: "TRASH"),
         msg("c", hour: 3, labels: "INBOX")]
    }

    private func makeDB(_ messages: [Message], thread: String = "t1") throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: self.account, displayName: "P", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
            for m in messages {
                try m.insert(db)
                try MessageBody(messageId: m.id, bodyText: "body-\(m.gmailId)", bodyHTML: nil).insert(db)
            }
            try SyncEngine.deriveThreads(db, for: ["\(self.account):\(thread)"], accountId: self.account)
        }
        return q
    }

    // MARK: - Count and placement of the line

    func testSummaryCountsTrashedNonDraftMessagesOfALiveConversation() throws {
        let summary = try XCTUnwrap(DeletedMessagesInConversation.summary(conversation, threadInTrash: false))
        XCTAssertEqual(summary.count, 1)
        XCTAssertEqual(summary.firstDate, conversation[1].date)
        XCTAssertEqual(summary.messageIds, ["\(account):b"])
        var other = conversation
        other[1].id = "\(account):b2"
        XCTAssertNotEqual(DeletedMessagesInConversation.summary(other, threadInTrash: false), summary,
                          "another deleted message with the same count and date is a change")

        let two = conversation + [msg("d", hour: 0.5, labels: "TRASH"),
                                  msg("e", hour: 4, labels: "DRAFT TRASH")]
        let both = try XCTUnwrap(DeletedMessagesInConversation.summary(two, threadInTrash: false))
        XCTAssertEqual(both.count, 2, "a discarded draft is not a deleted message")
        XCTAssertEqual(both.firstDate, two[3].date, "the oldest deleted message places the line")
    }

    func testNoLineInTheTrashOrWithoutLiveMessagesOrWithoutDeletedOnes() {
        XCTAssertNil(DeletedMessagesInConversation.summary(conversation, threadInTrash: true),
                     "a conversation in the trash shows all its messages")
        XCTAssertNil(DeletedMessagesInConversation.summary(
            [msg("x", hour: 1, labels: "TRASH")], threadInTrash: false),
                     "a lone trashed message shows itself (TrashedMessages.shown)")
        XCTAssertNil(DeletedMessagesInConversation.summary(
            [msg("a", hour: 1, labels: "INBOX"), msg("d", hour: 2, labels: "DRAFT TRASH")],
            threadInTrash: false))
    }

    func testLabelSaysTheCountAndNoMailContent() {
        XCTAssertEqual(DeletedMessagesInConversation.label(count: 1),
                       "1 deleted message in this conversation")
        XCTAssertEqual(DeletedMessagesInConversation.label(count: 3),
                       "3 deleted messages in this conversation")
    }

    func testLineSitsWhereTheFirstDeletedMessageWas() throws {
        let live = TrashedMessages.shown(conversation, threadInTrash: false)
        let summary = DeletedMessagesInConversation.summary(conversation, threadInTrash: false)
        let rows = DeletedMessagesInConversation.rows(
            live: live, deleted: [], summary: summary, showing: false)
        XCTAssertEqual(rows.map(\.id), ["\(account):a", DeletedMessagesInConversation.lineId, "\(account):c"])

        let oldest = DeletedMessagesSummary(count: 1, firstDate: base)
        XCTAssertEqual(DeletedMessagesInConversation.rows(
            live: live, deleted: [], summary: oldest, showing: false).first?.id,
                       DeletedMessagesInConversation.lineId, "older than every live message: at the top")
        let newest = DeletedMessagesSummary(count: 1, firstDate: base.addingTimeInterval(9 * 3600))
        XCTAssertEqual(DeletedMessagesInConversation.rows(
            live: live, deleted: [], summary: newest, showing: false).last?.id,
                       DeletedMessagesInConversation.lineId)
        XCTAssertEqual(DeletedMessagesInConversation.rows(
            live: live, deleted: [], summary: nil, showing: true).map(\.id),
                       live.map(\.id), "no line without deleted messages")
    }

    // MARK: - What "View" adds

    func testViewMergesTheDeletedMessagesByDateMarkedInTrash() throws {
        let all = conversation + [msg("d", hour: 2.5, labels: "TRASH")]
        let live = TrashedMessages.shown(all, threadInTrash: false)
        let deleted = DeletedMessagesInConversation.deleted(all, threadInTrash: false)
        XCTAssertEqual(deleted.map(\.gmailId), ["b", "d"])
        let summary = DeletedMessagesInConversation.summary(all, threadInTrash: false)
        let rows = DeletedMessagesInConversation.rows(
            live: live, deleted: deleted, summary: summary, showing: true)
        XCTAssertEqual(rows.map(\.id), ["\(account):a", DeletedMessagesInConversation.lineId,
                                        "\(account):b", "\(account):d", "\(account):c"])
        let marked = rows.compactMap { row -> String? in
            if case .message(let m, true) = row { return m.gmailId }
            return nil
        }
        XCTAssertEqual(marked, ["b", "d"])

        // Hide: only the line again.
        XCTAssertEqual(DeletedMessagesInConversation.rows(
            live: live, deleted: deleted, summary: summary, showing: false).count, live.count + 1)
    }

    func testARestoredMessageIsShownOnceAsLive() {
        var restored = conversation
        restored[1].labelIds = "INBOX"
        let live = TrashedMessages.shown(restored, threadInTrash: false)
        // The deleted list loaded before the restore still names b.
        let staleDeleted = [conversation[1]]
        let rows = DeletedMessagesInConversation.rows(
            live: live, deleted: staleDeleted,
            summary: DeletedMessagesSummary(count: 1, firstDate: conversation[1].date), showing: true)
        XCTAssertEqual(rows.filter { $0.id == "\(account):b" },
                       [.message(live[1], inTrash: false)])
        XCTAssertNil(DeletedMessagesInConversation.summary(restored, threadInTrash: false),
                     "nothing deleted left: the line goes")
    }

    func testViewLoadsOnlyTheDeletedMessagesWithTheirStoredBodies() throws {
        let q = try makeDB(conversation + [msg("d", hour: 4, labels: "DRAFT TRASH")])
        let loaded = try q.read { db in
            try DeletedMessagesInConversation.load(db, threadId: "\(self.account):t1")
        }
        XCTAssertEqual(loaded.messages.map(\.gmailId), ["b"])
        XCTAssertEqual(loaded.messages.first?.bodyText, "body-b")

        let trashed = try makeDB([msg("x", thread: "t2", hour: 1, labels: "TRASH"),
                                  msg("y", thread: "t2", hour: 2, labels: "TRASH")], thread: "t2")
        let none = try trashed.read { db in
            try DeletedMessagesInConversation.load(db, threadId: "\(self.account):t2")
        }
        XCTAssertTrue(none.messages.isEmpty, "a conversation in the Trash has no deleted-messages line")
    }

    // MARK: - Other readers are unchanged

    /// The payload (quoting, summary, export, toolbar, keyboard read its
    /// messages) carries the count only; reading the deleted messages for
    /// "View" leaves the cached payload as it was.
    func testPayloadAndItsReadersNeverGetTheDeletedMessages() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("deleted-in-conversation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let pool = try DatabasePool(path: directory.appendingPathComponent("mail.sqlite").path)
        try AppDatabase.migrator.migrate(pool)
        let messages = conversation
        let threadId = "\(account):t1"
        try await pool.write { db in
            try Account(id: self.account, displayName: "P", historyId: nil,
                        lastSyncAt: nil, senderName: "").insert(db)
            for m in messages {
                try m.insert(db)
                try MessageBody(messageId: m.id, bodyText: "body-\(m.gmailId)", bodyHTML: nil).insert(db)
            }
            try SyncEngine.deriveThreads(db, for: [threadId], accountId: self.account)
        }
        let live = [messages[0], messages[2]]
        let repository = ThreadDetailRepository(db: pool)
        let revisions = ThreadContentRevisions()
        let first = await repository.payload(threadId: threadId, suppressingDrafts: [],
                                             revision: revisions.revision(of: threadId))
        XCTAssertEqual(first.payload.messages.map(\.gmailId), ["a", "c"])
        XCTAssertEqual(first.payload.deletedSummary?.count, 1)

        let viewed = try await pool.read { db in
            try DeletedMessagesInConversation.load(db, threadId: threadId)
        }
        XCTAssertEqual(viewed.messages.map(\.gmailId), ["b"])

        let again = await repository.payload(threadId: threadId, suppressingDrafts: [],
                                             revision: revisions.revision(of: threadId))
        XCTAssertTrue(again.cacheHit)
        XCTAssertEqual(again.payload.messages.map(\.gmailId), ["a", "c"], "View never fills the cache")
        XCTAssertEqual(ThreadSummaryPolicy.fingerprint(subject: "Plans", messages: again.payload.messages),
                       ThreadSummaryPolicy.fingerprint(subject: "Plans", messages: live),
                       "the AI summary's input is the live messages")
        XCTAssertTrue(ThreadExporter.markdown(subject: "Plans", messages: again.payload.messages)
            .contains("_2 messages_"), "print and export count the live messages only")
        // Quoting (`MailStore.messages(inThread:)`), MCP `get_thread` and the
        // thread row all read `TrashedMessages.shown`.
        XCTAssertEqual(TrashedMessages.shown(messages, threadInTrash: false).map(\.gmailId), ["a", "c"])
        let row = try await pool.read { db in try MailThread.fetchOne(db, key: threadId) }
        XCTAssertEqual(row?.messageCount, 2)
        XCTAssertEqual(row?.snippet, "snippet-c")

        // The Trash view's reader of the same conversation has no line.
        let trashView = await repository.payload(threadId: threadId, suppressingDrafts: [],
                                                 revision: revisions.revision(of: threadId),
                                                 trashView: true)
        XCTAssertNil(trashView.payload.deletedSummary)
        XCTAssertEqual(trashView.payload.messages.map(\.gmailId), ["b"])
    }

    func testDraftSuppressionKeepsTheLine() {
        let payload = ThreadDetailPayload(
            messages: [conversation[0]], attachmentsByMessageId: [:], bodyPrepByMessageId: [:],
            deletedSummary: DeletedMessagesSummary(count: 2, firstDate: base))
        XCTAssertEqual(payload.suppressingDrafts(["\(account):z"]).deletedSummary?.count, 2)
    }

    // MARK: - Restore

    func testRestoreRequestNamesTheMessagesAndInboxOnlyWhenTheConversationIsThere() async throws {
        XCTAssertEqual(DeletedMessagesInConversation.restoreChange(gmailIds: ["b"], conversationInInbox: true),
                       .modifyMessages(ids: ["b"], add: ["INBOX"], remove: ["TRASH"]))
        XCTAssertEqual(DeletedMessagesInConversation.restoreChange(gmailIds: ["b", "d"],
                                                                   conversationInInbox: false),
                       .modifyMessages(ids: ["b", "d"], add: [], remove: ["TRASH"]))

        let stub = StubThreadEditing()
        try await RemoteThreadSend.send(
            DeletedMessagesInConversation.restoreChange(gmailIds: ["b", "d"], conversationInInbox: true),
            via: stub, gmailThreadId: "t1")
        let calls = await stub.calls
        XCTAssertEqual(calls, [.modifyMessages(ids: ["b", "d"], add: ["INBOX"], remove: ["TRASH"])],
                       "messages.batchModify on those ids: no thread-wide change, no delete")
    }

    /// Stored before Gmail answers; a refusal puts the message back in the
    /// trash and the line comes back.
    func testRestoreIsWrittenLocallyAndRevertedOnRefusal() throws {
        let q = try makeDB(conversation)
        let threadId = "\(account):t1"
        let change = DeletedMessagesInConversation.restoreChange(gmailIds: ["b"], conversationInInbox: true)
        guard case .modifyMessages(let ids, let add, let remove) = change else {
            return XCTFail("a per-message change")
        }
        try q.write { db in
            try TrashedMessages.applyRestore(db, accountId: self.account, threadId: threadId,
                                             ids: ids, add: add, remove: remove)
        }
        try q.read { db in
            let b = try XCTUnwrap(Message.fetchOne(db, key: "\(self.account):b"))
            XCTAssertEqual(b.labelIds, "INBOX")
            XCTAssertEqual(try MailThread.fetchOne(db, key: threadId)?.messageCount, 3)
            let payload = try ThreadDetailRepository.fetchPayload(threadId: threadId, db: db)
            XCTAssertEqual(payload.messages.map(\.gmailId), ["a", "b", "c"], "a normal live message")
            XCTAssertNil(payload.deletedSummary)
        }
        XCTAssertEqual(TrashedMessages.storedRestores(in: change).count, 1)
        try q.write { db in
            XCTAssertTrue(try TrashedMessages.revertStoredRestores(db, accountId: self.account, change: change))
            try SyncEngine.deriveThreads(db, for: [threadId], accountId: self.account)
        }
        try q.read { db in
            let b = try XCTUnwrap(Message.fetchOne(db, key: "\(self.account):b"))
            XCTAssertEqual(b.labelIds, "TRASH")
            XCTAssertEqual(try MailThread.fetchOne(db, key: threadId)?.messageCount, 2)
            let payload = try ThreadDetailRepository.fetchPayload(threadId: threadId, db: db)
            XCTAssertEqual(payload.deletedSummary?.count, 1)
        }
    }
}
