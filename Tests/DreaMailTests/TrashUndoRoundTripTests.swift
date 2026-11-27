import XCTest
import GRDB

/// Trash, then its undo, as `MailStore.trash` / `trashChecked` run them:
/// the trash states read before the action (`TrashedMessages.trashStates`),
/// the optimistic thread-row write, then the undo's write diffed against
/// the post-trash copy and the Gmail change built from the states. After
/// the undo the Inbox query the list reloads with (`ThreadListQuery.inbox`)
/// and the sidebar counts must show the conversation again.
final class TrashUndoRoundTripTests: XCTestCase {
    private let account = "you@example.com"

    private func msg(_ id: String, thread: String, minutesAgo: Double, labels: String) -> Message {
        Message(id: "\(account):\(id)", accountId: account, gmailId: id,
                threadId: "\(account):\(thread)", fromHeader: "Ann <ann@example.com>",
                toHeader: account, ccHeader: "", bccHeader: "", subject: "Plans",
                date: Date(timeIntervalSinceNow: -minutesAgo * 60),
                snippet: "snippet-\(id)", bodyText: "body-\(id)", bodyHTML: nil,
                messageIdHeader: "<\(id)@example.com>", referencesHeader: "",
                labelIds: labels, isUnread: labels.contains("UNREAD"), hasAttachment: false)
    }

    private func makeDB(_ messages: [Message]) throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: self.account, displayName: "P", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
            for m in messages { try m.insert(db) }
            try SyncEngine.deriveThreads(db, for: Set(messages.map(\.threadId)),
                                         accountId: self.account)
        }
        return q
    }

    private func key(_ thread: String) -> String { "\(account):\(thread)" }

    private func rows(_ q: DatabaseQueue, _ ids: [String]) throws -> [MailThread] {
        try q.read { db in try ids.map { try XCTUnwrap(try MailThread.fetchOne(db, key: self.key($0))) } }
    }

    private func inboxIds(_ q: DatabaseQueue) throws -> Set<String> {
        try q.read { db in Set(try ThreadListQuery.inbox().fetchAll(db).map(\.gmailThreadId)) }
    }

    private func inboxUnread(_ q: DatabaseQueue) throws -> Int {
        try q.read { db in
            try SidebarCounts.fetch(db: db, activeAccount: nil, badgeAccount: nil).counts["inbox"] ?? -1
        }
    }

    /// The store's sequence for one bulk action and its undo, every row
    /// written in the same order and with the same diff bases.
    private func trashThenUndo(_ q: DatabaseQueue, _ ids: [String])
        throws -> (states: [String: ThreadUndo.TrashState], undo: [String: RemoteThreadChange]) {
        let originals = try rows(q, ids)
        let states = try q.read { db in try TrashedMessages.trashStates(db, threadIds: originals.map(\.id)) }
        var acted: [MailThread] = []
        try q.write { db in
            for original in originals {
                var copy = original
                ThreadUndo.apply(.trash, &copy)
                copy.endGmailSnoozeIfInboxed()
                try OptimisticThreadWrite.updateChangedColumns(db, from: original, to: copy)
                acted.append(copy)
            }
        }
        XCTAssertTrue(try inboxIds(q).isDisjoint(with: ids), "the trash leaves the Inbox")
        var undo: [String: RemoteThreadChange] = [:]
        try q.write { db in
            for group in ThreadUndo.undoGroups(acted: acted, originals: originals) {
                for base in group.threads {
                    var restored = base
                    ThreadUndo.restore(.trash, wasInInbox: group.wasInInbox, &restored)
                    restored.endGmailSnoozeIfInboxed()
                    try OptimisticThreadWrite.updateChangedColumns(db, from: base, to: restored)
                    undo[base.id] = ThreadUndo.undoTrashRemote(
                        wasInInbox: group.wasInInbox, before: states[base.id])
                }
            }
        }
        return (states, undo)
    }

    func testOneRowComesBackWithItsLabelsAndCounts() throws {
        let q = try makeDB([msg("a1", thread: "a", minutesAgo: 5, labels: "INBOX UNREAD Label_1"),
                            msg("b1", thread: "b", minutesAgo: 9, labels: "INBOX")])
        let before = try rows(q, ["a"])[0]
        XCTAssertEqual(try inboxUnread(q), 1)

        let result = try trashThenUndo(q, ["a"])

        let after = try rows(q, ["a"])[0]
        XCTAssertEqual(try inboxIds(q), ["a", "b"], "the reload lists the row again")
        XCTAssertFalse(after.inTrash)
        XCTAssertTrue(after.inInbox)
        XCTAssertTrue(after.isUnread)
        XCTAssertEqual(after.labelIds, before.labelIds)
        XCTAssertEqual(try inboxUnread(q), 1, "the Inbox count comes back")
        XCTAssertEqual(result.undo[key("a")], .modify(add: ["INBOX"], remove: ["TRASH"]))
    }

    func testSeveralRowsComeBackEachToWhereItWas() throws {
        let q = try makeDB([msg("a1", thread: "a", minutesAgo: 5, labels: "INBOX UNREAD"),
                            msg("b1", thread: "b", minutesAgo: 6, labels: "INBOX"),
                            msg("c1", thread: "c", minutesAgo: 7, labels: "Label_1")])
        let result = try trashThenUndo(q, ["a", "b", "c"])

        XCTAssertEqual(try inboxIds(q), ["a", "b"])
        let restored = try rows(q, ["a", "b", "c"])
        XCTAssertFalse(restored.contains { $0.inTrash })
        XCTAssertFalse(restored[2].inInbox, "a row that was not in the Inbox does not get there")
        XCTAssertTrue(restored[2].labels.contains("Label_1"))
        XCTAssertEqual(try inboxUnread(q), 1)
        XCTAssertEqual(result.undo[key("c")], .modify(remove: ["TRASH"]))
    }

    /// DEC-081: a conversation with a message already deleted comes back
    /// to the Inbox, and the undo re-trashes only that message, so the
    /// earlier deletion stays (the message rows are not touched locally).
    func testAConversationWithAnAlreadyTrashedMessageKeepsThatDeletion() throws {
        let q = try makeDB([msg("p1", thread: "p", minutesAgo: 60, labels: "TRASH"),
                            msg("p2", thread: "p", minutesAgo: 5, labels: "INBOX UNREAD")])
        XCTAssertEqual(try inboxIds(q), ["p"], "a partly trashed conversation is live")

        let result = try trashThenUndo(q, ["p"])

        XCTAssertEqual(result.states[key("p")],
                       ThreadUndo.TrashState(liveIds: ["p2"], trashedIds: ["p1"]))
        XCTAssertEqual(result.undo[key("p")], .sequence([
            .modify(add: ["INBOX"], remove: ["TRASH"]),
            .modifyMessages(ids: ["p1"], add: ["TRASH"], remove: ["INBOX"]),
        ]))
        XCTAssertEqual(try inboxIds(q), ["p"])
        XCTAssertEqual(try inboxUnread(q), 1)
        try q.read { db in
            let p1 = try XCTUnwrap(try Message.fetchOne(db, key: self.key("p1")))
            XCTAssertTrue(SyncEngine.labelIdsContain(p1.labelIds, "TRASH"), "still deleted")
            let live = try ThreadDetailRepository.fetchPayload(threadId: self.key("p"), db: db)
            XCTAssertEqual(live.messages.map(\.gmailId), ["p2"], "the deleted message stays hidden")
        }
    }

    /// The in-memory side of the undo: the trashed row is absent from the
    /// list, and the restored copy goes back in sort order.
    func testTheRestoredRowIsReinsertedInTheList() throws {
        let q = try makeDB([msg("a1", thread: "a", minutesAgo: 5, labels: "INBOX"),
                            msg("b1", thread: "b", minutesAgo: 9, labels: "INBOX"),
                            msg("c1", thread: "c", minutesAgo: 1, labels: "INBOX")])
        let all = try rows(q, ["c", "a", "b"])
        let list = all.filter { $0.gmailThreadId != "a" }
        var restored = all[1]
        ThreadUndo.apply(.trash, &restored)
        ThreadUndo.restore(.trash, wasInInbox: true, &restored)
        XCTAssertTrue(ThreadListOptimistic.shouldReinsertAbsent(
            threadAccountId: account, activeAccountId: nil, committedSearchActive: false))
        XCTAssertEqual(ThreadListOptimistic.plan(leavesCurrentList: false).effect, .updateInPlace)
        XCTAssertEqual(ThreadListOptimistic.insertionIndex(for: restored, in: list, inboundSort: true), 1)
    }
}
