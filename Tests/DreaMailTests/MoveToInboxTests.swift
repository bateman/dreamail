import XCTest
import GRDB

/// Gmail's "Move to Inbox" for a conversation not in the Inbox: the local
/// write, the Inbox list and badge, what reaches Gmail, the undo (archive
/// again), a refusal, the offline queue, snoozed conversations, and which
/// action each surface offers. `MailStore.moveToInboxTargets` runs exactly
/// `ConversationAction.moveToInbox` through `mutateThread(s)`; the hostless
/// test target does not compile `MailStore`.
final class MoveToInboxTests: XCTestCase {
    private let account = "ron@example.com"
    private let action = ConversationAction.moveToInbox

    // MARK: - Fixtures

    private func makeDB(_ threads: [(id: String, labels: [String])]) throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: self.account, displayName: "P", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
            for (id, labels) in threads {
                for (n, messageLabels) in labels.enumerated() {
                    try Message(id: "\(self.account):m-\(id)-\(n)", accountId: self.account,
                                gmailId: "m-\(id)-\(n)", threadId: self.key(id),
                                fromHeader: "a@example.com", toHeader: self.account,
                                ccHeader: "", bccHeader: "", subject: "Hello",
                                date: Date(timeIntervalSince1970: 1_700_000_000 + Double(n) * 60),
                                snippet: "", bodyText: "", bodyHTML: nil, messageIdHeader: "",
                                referencesHeader: "", labelIds: messageLabels,
                                isUnread: messageLabels.contains("UNREAD"),
                                hasAttachment: false).insert(db)
                }
                try SyncEngine.deriveThreads(db, for: [self.key(id)], accountId: self.account)
            }
        }
        return q
    }

    private func key(_ id: String) -> String { "\(account):\(id)" }

    private func thread(_ q: DatabaseQueue, _ id: String = "t1") throws -> MailThread {
        try XCTUnwrap(try q.read { try MailThread.fetchOne($0, key: self.key(id)) })
    }

    private func write(_ q: DatabaseQueue, from old: MailThread, to new: MailThread) throws {
        try q.write { try OptimisticThreadWrite.updateChangedColumns($0, from: old, to: new) }
    }

    /// What `MailStore.rederiveThreadFromMessages` writes on a refusal. Sync,
    /// so async tests call it without `await`.
    private func rederive(_ q: DatabaseQueue, _ id: String = "t1") throws {
        try q.write { db in
            try OptimisticThreadWrite.rederiveOrDelete(db, threadId: self.key(id),
                                                       accountId: self.account)
        }
    }

    private func inboxIds(_ q: DatabaseQueue) throws -> [String] {
        try q.read { try ThreadListQuery.inbox().fetchAll($0).map(\.gmailThreadId) }
    }

    private func badge(_ q: DatabaseQueue) throws -> Int {
        try q.read {
            try SidebarCounts.fetch(db: $0, activeAccount: nil, badgeAccount: nil,
                                    now: Date(), hideCategories: []).badge
        }
    }

    /// Gmail's history patch, then the derive the next sync runs.
    private func historyApplies(_ q: DatabaseQueue, _ change: RemoteThreadChange,
                                thread id: String = "t1") throws {
        try q.write { db in
            for var m in try Message.filter(Column("threadId") == self.key(id)).fetchAll(db) {
                var set = Set(m.labelIds.split(separator: " ").map(String.init))
                set.subtract(change.removeLabels)
                set.formUnion(change.addLabels)
                m.labelIds = set.sorted().joined(separator: " ")
                try m.update(db)
            }
            try SyncEngine.deriveThreads(db, for: [self.key(id)], accountId: self.account)
        }
    }

    // MARK: - The mutation

    /// An archived, labelled, unread conversation comes back to the Inbox
    /// list and badge at once; it keeps its label (it stays in that label
    /// view and in All Mail) and its read state; the next sync agrees.
    func testMoveToInboxAddsOnlyInboxAndShowsInTheInboxAtOnce() throws {
        let q = try makeDB([("t1", ["Label_7 UNREAD"])])
        let before = try thread(q)
        XCTAssertFalse(before.inInbox)
        XCTAssertEqual(try inboxIds(q), [])
        let badgeBefore = try badge(q)

        var moved = before
        action.apply(&moved)
        XCTAssertTrue(moved.inInbox)
        XCTAssertTrue(moved.isUnread, "Gmail's Move to Inbox does not change the read state")
        XCTAssertEqual(moved.userLabelIds, ["Label_7"], "the label stays")
        XCTAssertEqual(action.remote, .modify(add: ["INBOX"], remove: []))
        XCTAssertEqual(DockBadge.delta(from: before, to: moved, badgeAccount: nil), 1)

        try write(q, from: before, to: moved)
        XCTAssertEqual(try inboxIds(q), ["t1"], "in the Inbox list before Gmail answers")
        XCTAssertEqual(try badge(q), badgeBefore + 1, "the recount agrees with the delta")

        try historyApplies(q, action.remote)
        let synced = try thread(q)
        XCTAssertTrue(synced.inInbox, "the next sync keeps the move")
        XCTAssertEqual(synced.userLabelIds, ["Label_7"])
    }

    /// The undo archives again: INBOX off, nothing else touched.
    func testUndoArchivesAgain() throws {
        let q = try makeDB([("t1", ["Label_7"])])
        let before = try thread(q)
        var moved = before
        action.apply(&moved)
        try write(q, from: before, to: moved)

        XCTAssertEqual(action.undoRemote(original: before), .modify(add: [], remove: ["INBOX"]))
        var restored = moved
        action.restore(original: before, &restored)
        try write(q, from: moved, to: restored)
        let row = try thread(q)
        XCTAssertFalse(row.inInbox)
        XCTAssertEqual(row.userLabelIds, ["Label_7"])
        XCTAssertEqual(try inboxIds(q), [])

        let groups = action.undoGroups(acted: [moved], originals: [before])
        XCTAssertEqual(groups.map(\.change), [.modify(add: [], remove: ["INBOX"])])
    }

    /// One `threads.modify` that adds INBOX, as Gmail web sends.
    func testReachesGmailAsOneThreadModifyAddingInbox() async throws {
        let stub = StubThreadEditing()
        try await RemoteThreadSend.send(action.remote, via: stub, gmailThreadId: "t1")
        let calls = await stub.calls
        XCTAssertEqual(calls, [.modify(id: "t1", add: ["INBOX"], remove: [])])
    }

    /// Gmail refuses: the store re-derives the row from its messages, which
    /// still hold Gmail's state, so the conversation leaves the Inbox again.
    func testRefusalRollsBackFromTheMessageRows() async throws {
        let q = try makeDB([("t1", ["Label_7"])])
        let before = try thread(q)
        var moved = before
        action.apply(&moved)
        try write(q, from: before, to: moved)
        XCTAssertEqual(try inboxIds(q), ["t1"])

        let refusal = GmailError.http(400, "Invalid label")
        let stub = StubThreadEditing(error: refusal)
        do {
            try await RemoteThreadSend.send(action.remote, via: stub, gmailThreadId: "t1")
            XCTFail("the stub refuses")
        } catch {
            XCTAssertEqual(RemoteThreadSend.disposition(for: error), .revert)
        }
        try rederive(q)
        XCTAssertFalse(try thread(q).inInbox)
        XCTAssertEqual(try inboxIds(q), [])
        XCTAssertFalse(RemoteThreadSend.refusalMessage(for: action.remote, error: refusal).isEmpty,
                       "the refusal is shown as an error")
    }

    /// Offline the edit is queued for replay; an undo before the replay
    /// cancels it out, so nothing reaches Gmail.
    func testOfflineQueuesTheEditAndAnUndoCancelsIt() throws {
        let q = try makeDB([("t1", ["Label_7"])])
        let before = try thread(q)
        XCTAssertEqual(RemoteThreadSend.disposition(for: URLError(.notConnectedToInternet)),
                       .queueOffline)
        try q.write { db in
            try PendingThreadOp.enqueue(db, accountId: self.account, gmailThreadId: "t1",
                                        change: self.action.remote)
        }
        try q.read { db in
            let rows = try PendingThreadOp.fetchAll(db)
            XCTAssertEqual(rows.map(\.change), [.modify(add: ["INBOX"], remove: [])])
        }
        try q.write { db in
            try PendingThreadOp.enqueue(db, accountId: self.account, gmailThreadId: "t1",
                                        change: self.action.undoRemote(original: before))
        }
        XCTAssertEqual(try q.read { try PendingThreadOp.fetchCount($0) }, 0)
    }

    /// A conversation snoozed here: Move to Inbox is unsnooze (same local
    /// result and the same Gmail change as `ThreadUndo.unsnooze`).
    func testSnoozedConversationIsUnsnoozed() throws {
        let q = try makeDB([("t1", ["Label_7"])])
        var snoozed = try thread(q)
        snoozed.snoozeUntil = Date().addingTimeInterval(86_400)
        XCTAssertTrue(InboxMove.offered(for: snoozed))

        var moved = snoozed
        action.apply(&moved)
        var unsnoozed = snoozed
        ThreadUndo.unsnooze(&unsnoozed)
        XCTAssertNil(moved.snoozeUntil)
        XCTAssertTrue(moved.inInbox)
        XCTAssertEqual(moved.labelIds, unsnoozed.labelIds)
        XCTAssertEqual(action.remote, .modify(add: ["INBOX"]),
                       "the unsnooze path's Gmail change")
    }

    /// "Move to" → Inbox leaves what the list it runs in asks for: the
    /// label of a label view, or the trash in Trash.
    func testMovePickerInboxDestinationLeavesTheLabelViewOrTrash() {
        XCTAssertEqual(ConversationAction.moveTo(labelId: "INBOX").remote,
                       .modify(add: ["INBOX"], remove: []))
        XCTAssertEqual(ConversationAction.moveTo(
            labelId: "INBOX", alsoRemove: MoveSource.alsoRemove(labelViewId: "Label_3",
                                                               inTrashView: false)).remote,
                       .modify(add: ["INBOX"], remove: ["Label_3"]))
        XCTAssertEqual(ConversationAction.moveTo(
            labelId: "INBOX", alsoRemove: MoveSource.alsoRemove(labelViewId: nil,
                                                               inTrashView: true)).remote,
                       .modify(add: ["INBOX"], remove: ["TRASH"]))
        // Other destinations still leave the Inbox.
        XCTAssertEqual(ConversationAction.moveTo(labelId: "Label_7").remote,
                       .modify(add: ["Label_7"], remove: ["INBOX"]))
    }

    // MARK: - Which action a surface offers

    func testOfferedForEveryConversationNotInTheInboxExceptTrashAndSpam() throws {
        let q = try makeDB([("inbox", ["INBOX"]), ("archived", ["Label_7"]), ("sent", ["SENT"]),
                            ("trash", ["TRASH"]), ("spam", ["SPAM"])])
        XCTAssertFalse(InboxMove.offered(for: try thread(q, "inbox")))
        XCTAssertTrue(InboxMove.offered(for: try thread(q, "archived")))
        XCTAssertTrue(InboxMove.offered(for: try thread(q, "sent")))
        XCTAssertFalse(InboxMove.offered(for: try thread(q, "trash")), "Trash keeps its restore")
        XCTAssertFalse(InboxMove.offered(for: try thread(q, "spam")), "Spam keeps Not spam")

        let mixed = [try thread(q, "inbox"), try thread(q, "archived")]
        XCTAssertFalse(InboxMove.offered(for: mixed), "a mix keeps Archive")
        XCTAssertTrue(InboxMove.offered(for: [try thread(q, "archived"), try thread(q, "sent")]))
        XCTAssertFalse(InboxMove.offered(for: [MailThread]()))
    }

    func testRowHoverArchiveSlotBecomesMoveToInbox() {
        let slot = ThreadRowHoverAction.archive
        XCTAssertEqual(slot.title(isUnread: false), "Archive")
        XCTAssertEqual(slot.symbol(isUnread: false), "archivebox")
        XCTAssertEqual(slot.identifier(), "archive")
        XCTAssertEqual(slot.title(isUnread: false, movesToInbox: true), "Move to inbox")
        XCTAssertEqual(slot.symbol(isUnread: true, movesToInbox: true), "tray.and.arrow.down")
        XCTAssertEqual(slot.identifier(movesToInbox: true), "moveToInbox")
        // The other slots do not change.
        XCTAssertEqual(ThreadRowHoverAction.trash.identifier(movesToInbox: true), "trash")
        XCTAssertEqual(ThreadRowHoverAction.trash.title(isUnread: false, movesToInbox: true), "Trash")
    }

    func testPaletteOffersMoveToInboxInPlaceOfArchive() {
        typealias T = PaletteCommands.ThreadState
        func ids(focused: T?, checked: [T] = []) -> [String] {
            var ctx = PaletteCommands.Context()
            ctx.focused = focused
            ctx.checked = checked
            ctx.checkedCount = checked.count
            return PaletteCommands.entries(ctx).map(\.id)
        }
        let inInbox = ids(focused: T())
        XCTAssertTrue(inInbox.contains("act.archive"))
        XCTAssertFalse(inInbox.contains("act.moveToInbox"))

        var ctx = PaletteCommands.Context()
        ctx.focused = T(offersMoveToInbox: true)
        let archived = PaletteCommands.entries(ctx)
        XCTAssertFalse(archived.contains { $0.id == "act.archive" })
        let entry = try? XCTUnwrap(archived.first { $0.id == "act.moveToInbox" })
        XCTAssertEqual(entry?.title, "Move to inbox")
        XCTAssertEqual(entry?.action, .perform(.moveToInbox))
        XCTAssertEqual(entry?.shortcut, .moveToInbox)
        XCTAssertEqual(entry?.icon, InboxMove.symbol)

        let mixed = ids(focused: nil, checked: [T(offersMoveToInbox: true), T()])
        XCTAssertTrue(mixed.contains("act.archive"))
        XCTAssertFalse(mixed.contains("act.moveToInbox"))
        let allOut = ids(focused: nil, checked: [T(offersMoveToInbox: true), T(offersMoveToInbox: true)])
        XCTAssertTrue(allOut.contains("act.moveToInbox"))
        XCTAssertFalse(allOut.contains("act.archive"))
    }

    /// Gmail has no key for Move to Inbox: it ships unbound and steals none.
    @MainActor
    func testMoveToInboxShipsWithoutAKey() {
        let suite = "MoveToInboxTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        XCTAssertNil(KeyBindings.defaultKey(for: .moveToInbox))
        let kb = KeyBindings(defaults: defaults)
        XCTAssertNil(kb.key(for: .moveToInbox))
        XCTAssertEqual(kb.command(for: "e"), .archive)
        XCTAssertEqual(kb.command(for: "v"), .moveTo)
        XCTAssertTrue(ShortcutCommand.moveToInbox.ignoresAutoRepeat)
    }

    // MARK: - Pickers

    func testMovePickerListsInboxFirstForAConversationNotInTheInbox() {
        let p = LabelPickerInboxRow.placement
        XCTAssertEqual(p(true, false, false, false, ""), .first)
        XCTAssertEqual(p(true, false, false, false, "inbox"), .first)
        XCTAssertEqual(p(true, false, false, false, "In"), .first)
        XCTAssertEqual(p(true, false, false, true, ""), .first, "Gmail's Trash lists Inbox too")
        XCTAssertNil(p(true, true, false, false, ""), "already in the Inbox")
        XCTAssertNil(p(true, false, true, false, ""), "spam leaves with Not spam")
        XCTAssertNil(p(true, false, false, false, "work"), "filtered out by the query")
    }

    func testLabelAsPickerOffersMoveToInboxOnlyWhenTyped() {
        let p = LabelPickerInboxRow.placement
        XCTAssertEqual(p(false, false, false, false, "inbox"), .last)
        XCTAssertEqual(p(false, false, false, false, "INBOX "), .last)
        XCTAssertNil(p(false, false, false, false, ""), "not listed among the labels")
        XCTAssertNil(p(false, true, false, false, "inbox"), "already in the Inbox")
        XCTAssertNil(p(false, false, false, true, "inbox"), "Trash keeps its restore")
        XCTAssertNil(p(false, false, true, false, "inbox"))
        XCTAssertEqual(LabelPickerInboxRow.labelModeTitle, "Move to inbox")
    }

    func testNoCreateRowForReservedNames() {
        let create = LabelPickerInboxRow.createName
        for name in ["inbox", "Inbox", " INBOX ", "Sent", "spam", "Trash", "Starred",
                     "Important", "Drafts", "draft", "Unread", "CATEGORY_SOCIAL"] {
            XCTAssertNil(create(name, []), name)
        }
        XCTAssertEqual(create("Invoices", []), "Invoices")
        XCTAssertEqual(create("Inbox 2024", []), "Inbox 2024", "only the exact name is reserved")
        XCTAssertNil(create("invoices", ["Invoices"]), "already a label")
        XCTAssertNil(create("  ", []))
    }
}
