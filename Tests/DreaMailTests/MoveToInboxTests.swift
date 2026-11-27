import XCTest
import GRDB

/// Gmail's "Move to Inbox" for a conversation not in the Inbox: the local
/// write, the Inbox list and badge, what reaches Gmail, the undo (archive
/// again), a refusal, the offline queue, snoozed conversations, and which
/// action each surface offers. `MailStore.moveToInboxTargets` and
/// `moveThreads` (Inbox) run exactly `InboxMove.Plan` through
/// `mutateThreads(remotes:)`; the hostless test target does not compile
/// `MailStore`, so the decisions live in the plan and are tested here on an
/// in-memory database.
final class MoveToInboxTests: XCTestCase {
    private let account = "ron@example.com"

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

    /// The plan for one conversation, and its single post-action copy.
    private func plan(_ q: DatabaseQueue, _ ids: [String] = ["t1"], fromPicker: Bool = false,
                      labelViewId: String? = nil, account: String? = nil,
                      partly: Set<String> = []) throws -> InboxMove.Plan {
        let threads = try ids.map { try thread(q, $0) }
        return InboxMove.Plan(threads, fromPicker: fromPicker, labelViewId: labelViewId,
                              account: account, isPartlyTrashed: { partly.contains($0.gmailThreadId) })
    }

    /// The database keeps dates to the millisecond: whole seconds compare
    /// equal after a round trip.
    private func wholeSecondsFromNow(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + seconds).rounded(.down))
    }

    private func setSnooze(_ q: DatabaseQueue, _ until: Date?, _ id: String = "t1") throws {
        let before = try thread(q, id)
        var after = before
        after.snoozeUntil = until
        try write(q, from: before, to: after)
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

        let p = try plan(q)
        XCTAssertEqual(p.targets.map(\.id), [before.id])
        let moved = try XCTUnwrap(p.acted.first)
        let remote = try XCTUnwrap(p.remotes[before.id])
        XCTAssertTrue(moved.inInbox)
        XCTAssertTrue(moved.isUnread, "Gmail's Move to inbox does not change the read state")
        XCTAssertEqual(moved.userLabelIds, ["Label_7"], "the label stays")
        XCTAssertEqual(remote, .modify(add: ["INBOX"], remove: []))
        XCTAssertEqual(DockBadge.delta(from: before, to: moved, badgeAccount: nil), 1)

        try write(q, from: before, to: moved)
        XCTAssertEqual(try inboxIds(q), ["t1"], "in the Inbox list before Gmail answers")
        XCTAssertEqual(try badge(q), badgeBefore + 1, "the recount agrees with the delta")

        try historyApplies(q, remote)
        let synced = try thread(q)
        XCTAssertTrue(synced.inInbox, "the next sync keeps the move")
        XCTAssertEqual(synced.userLabelIds, ["Label_7"])
    }

    /// The undo archives again: INBOX off, nothing else touched.
    func testUndoArchivesAgain() throws {
        let q = try makeDB([("t1", ["Label_7"])])
        let before = try thread(q)
        let p = try plan(q)
        let moved = try XCTUnwrap(p.acted.first)
        try write(q, from: before, to: moved)

        XCTAssertEqual(p.undoRemotes[before.id], .modify(add: [], remove: ["INBOX"]))
        var restored = moved
        p.restore(&restored)
        try write(q, from: moved, to: restored)
        let row = try thread(q)
        XCTAssertFalse(row.inInbox)
        XCTAssertEqual(row.userLabelIds, ["Label_7"])
        XCTAssertEqual(try inboxIds(q), [])
    }

    /// One `threads.modify` that adds INBOX, as Gmail web sends.
    func testReachesGmailAsOneThreadModifyAddingInbox() async throws {
        let stub = StubThreadEditing()
        let q = try makeDB([("t1", ["Label_7"])])
        let remote = try XCTUnwrap(try plan(q).remotes[key("t1")])
        try await RemoteThreadSend.send(remote, via: stub, gmailThreadId: "t1")
        let calls = await stub.calls
        XCTAssertEqual(calls, [.modify(id: "t1", add: ["INBOX"], remove: [])])
    }

    /// Gmail refuses: the store re-derives the row from its messages, which
    /// still hold Gmail's state, so the conversation leaves the Inbox again.
    func testRefusalRollsBackFromTheMessageRows() async throws {
        let q = try makeDB([("t1", ["Label_7"])])
        let before = try thread(q)
        let p = try plan(q)
        try write(q, from: before, to: try XCTUnwrap(p.acted.first))
        XCTAssertEqual(try inboxIds(q), ["t1"])
        let remote = try XCTUnwrap(p.remotes[before.id])

        let refusal = GmailError.http(400, "Invalid label")
        let stub = StubThreadEditing(error: refusal)
        do {
            try await RemoteThreadSend.send(remote, via: stub, gmailThreadId: "t1")
            XCTFail("the stub refuses")
        } catch {
            XCTAssertEqual(RemoteThreadSend.disposition(for: error), .revert)
        }
        try rederive(q)
        XCTAssertFalse(try thread(q).inInbox)
        XCTAssertEqual(try inboxIds(q), [])
        XCTAssertFalse(RemoteThreadSend.refusalMessage(for: remote, error: refusal).isEmpty,
                       "the refusal is shown as an error")
    }

    /// Offline the edit is queued for replay; an undo before the replay
    /// cancels it out, so nothing reaches Gmail.
    func testOfflineQueuesTheEditAndAnUndoCancelsIt() throws {
        let q = try makeDB([("t1", ["Label_7"])])
        let p = try plan(q)
        let id = key("t1")
        XCTAssertEqual(RemoteThreadSend.disposition(for: URLError(.notConnectedToInternet)),
                       .queueOffline)
        try q.write { db in
            try PendingThreadOp.enqueue(db, accountId: self.account, gmailThreadId: "t1",
                                        change: p.remotes[id]!)
        }
        try q.read { db in
            XCTAssertEqual(try PendingThreadOp.fetchAll(db).map(\.change),
                           [.modify(add: ["INBOX"], remove: [])])
        }
        try q.write { db in
            try PendingThreadOp.enqueue(db, accountId: self.account, gmailThreadId: "t1",
                                        change: p.undoRemotes[id]!)
        }
        XCTAssertEqual(try q.read { try PendingThreadOp.fetchCount($0) }, 0)
    }

    // MARK: - Snoozed

    /// A conversation snoozed here: Move to inbox is unsnooze (same local
    /// result and the same Gmail change as `ThreadUndo.unsnooze`).
    func testSnoozedConversationIsUnsnoozed() throws {
        let q = try makeDB([("t1", ["Label_7"])])
        let until = wholeSecondsFromNow(86_400)
        try setSnooze(q, until)
        let snoozed = try thread(q)
        XCTAssertTrue(InboxMove.offered(for: snoozed))

        let p = try plan(q)
        let moved = try XCTUnwrap(p.acted.first)
        var unsnoozed = snoozed
        ThreadUndo.unsnooze(&unsnoozed)
        XCTAssertNil(moved.snoozeUntil)
        XCTAssertTrue(moved.inInbox)
        XCTAssertEqual(moved.labelIds, unsnoozed.labelIds)
        XCTAssertEqual(p.remotes[snoozed.id], .modify(add: ["INBOX"]),
                       "the unsnooze path's Gmail change")
        XCTAssertEqual(p.endedSnoozes[snoozed.id], until, "kept for a refusal")
    }

    /// Snoozed view, Move to inbox by mistake, Undo: back to sleep until the
    /// same date, in the Snoozed list and out of the Inbox.
    func testUndoGivesTheSnoozeBack() throws {
        let q = try makeDB([("t1", ["Label_7"])])
        let until = wholeSecondsFromNow(86_400)
        try setSnooze(q, until)
        let before = try thread(q)
        let p = try plan(q)
        let moved = try XCTUnwrap(p.acted.first)
        try write(q, from: before, to: moved)
        XCTAssertEqual(try inboxIds(q), ["t1"])

        var restored = moved
        p.restore(&restored)
        try write(q, from: moved, to: restored)
        let row = try thread(q)
        XCTAssertEqual(row.snoozeUntil, until)
        XCTAssertFalse(row.inInbox)
        XCTAssertTrue(SidebarCounts.isActivelySnoozed(row))
        XCTAssertEqual(try inboxIds(q), [])
    }

    /// Gmail refuses the move of a snoozed conversation: the row is
    /// re-derived from its messages, then the date (local only) goes back.
    func testRefusalGivesTheSnoozeBack() throws {
        let q = try makeDB([("t1", ["Label_7"])])
        let until = wholeSecondsFromNow(86_400)
        try setSnooze(q, until)
        let before = try thread(q)
        let p = try plan(q)
        try write(q, from: before, to: try XCTUnwrap(p.acted.first))
        let refused = p.remotes[before.id]
        XCTAssertTrue(InboxMove.refusalRestoresSnooze(refused))

        try rederive(q)
        XCTAssertNil(try thread(q).snoozeUntil, "the re-derive alone loses it")
        let wrote = try q.write {
            try InboxMove.restoreSnoozeAfterRefusal($0, threadId: before.id, until: until)
        }
        XCTAssertTrue(wrote)
        let row = try thread(q)
        XCTAssertEqual(row.snoozeUntil, until)
        XCTAssertFalse(row.inInbox)
        XCTAssertEqual(try inboxIds(q), [])
    }

    /// The date is not put back over a newer snooze, nor on a conversation
    /// Gmail has in the Inbox, nor for a refusal that is not a move there.
    func testRefusalRestoreLeavesNewerStateAlone() throws {
        let q = try makeDB([("t1", ["Label_7"]), ("t2", ["INBOX"])])
        let old = wholeSecondsFromNow(3_600)
        let newer = wholeSecondsFromNow(86_400)
        try setSnooze(q, newer)
        XCTAssertFalse(try q.write {
            try InboxMove.restoreSnoozeAfterRefusal($0, threadId: self.key("t1"), until: old)
        })
        XCTAssertEqual(try thread(q).snoozeUntil, newer)
        XCTAssertFalse(try q.write {
            try InboxMove.restoreSnoozeAfterRefusal($0, threadId: self.key("t2"), until: old)
        })
        XCTAssertNil(try thread(q, "t2").snoozeUntil)
        XCTAssertFalse(InboxMove.refusalRestoresSnooze(.modify(remove: ["INBOX"])))
        XCTAssertFalse(InboxMove.refusalRestoresSnooze(nil))
    }

    /// The ended-snooze entries: set for every target of a move, settled
    /// only by that move's own success (direct or replayed) or refusal, or
    /// by its undo.
    func testEndedSnoozeLifecycle() throws {
        let q = try makeDB([("t1", ["Label_7"]), ("t2", ["Label_7"])])
        let first = wholeSecondsFromNow(3_600)
        try setSnooze(q, first)
        let id1 = key("t1"), id2 = key("t2")
        var ended = InboxMove.EndedSnoozes()
        let move = try plan(q, ["t1", "t2"])
        ended.begin(move)
        XCTAssertEqual(ended.dates, [id1: first], "only the snoozed target")

        // An unrelated edit on the thread settles nothing.
        ended.succeeded(threadId: id1, change: .modify(add: ["STARRED"]))
        XCTAssertEqual(ended.refused(threadId: id1, change: .modify(add: ["STARRED"])), nil)
        XCTAssertEqual(ended.dates, [id1: first])

        // The move replayed from the offline queue succeeds: settled.
        ended.succeeded(threadId: id1, change: move.remotes[id1]!)
        XCTAssertEqual(ended.dates, [:])
        XCTAssertNil(ended.refused(threadId: id1, change: move.remotes[id1]!),
                     "a later refusal finds no stale date")

        // A later move replaces an older entry, and clears one it ends none of.
        ended.begin(move)
        let second = wholeSecondsFromNow(7_200)
        try setSnooze(q, second)
        ended.begin(try plan(q, ["t1"]))
        XCTAssertEqual(ended.refused(threadId: id1, change: move.remotes[id1]!), second)
        ended.begin(move)
        try setSnooze(q, nil)
        ended.begin(try plan(q, ["t1"]))
        XCTAssertEqual(ended.dates, [:])

        // Undo settles too.
        try setSnooze(q, first)
        ended.begin(try plan(q, ["t1"]))
        ended.undone([id1, id2])
        XCTAssertEqual(ended.dates, [:])
    }

    // MARK: - Trash, spam, mute, drafts, label views

    /// "Move to… → Inbox" on a trashed conversation reached by a search,
    /// outside the Trash view: TRASH goes too (Gmail would purge it), and
    /// the undo puts it back. The explicit button is not offered there.
    func testTrashedConversationLeavesTheTrashWherever() throws {
        let q = try makeDB([("t1", ["TRASH Label_7"])])
        let before = try thread(q)
        XCTAssertTrue(before.inTrash)
        XCTAssertTrue(try plan(q).targets.isEmpty, "no Move to inbox button in the Trash")

        let p = try plan(q, fromPicker: true)
        XCTAssertEqual(p.remotes[before.id], .modify(add: ["INBOX"], remove: ["TRASH"]))
        let moved = try XCTUnwrap(p.acted.first)
        XCTAssertFalse(moved.inTrash)
        XCTAssertTrue(moved.inInbox)
        try write(q, from: before, to: moved)
        XCTAssertEqual(try inboxIds(q), ["t1"])

        XCTAssertEqual(p.undoRemotes[before.id], .modify(add: ["TRASH"], remove: ["INBOX"]))
        var restored = moved
        p.restore(&restored)
        try write(q, from: moved, to: restored)
        let row = try thread(q)
        XCTAssertTrue(row.inTrash)
        XCTAssertFalse(row.inInbox)
    }

    /// A Trash copy of a live conversation is left to the Trash restore
    /// (DEC-081): never in the plan.
    func testPartlyTrashedRowsAreLeftToTheTrashRestore() throws {
        let q = try makeDB([("t1", ["TRASH", "Label_7"]), ("t2", ["Label_7"])])
        let p = try plan(q, ["t1", "t2"], fromPicker: true, partly: ["t1"])
        XCTAssertEqual(p.targets.map(\.gmailThreadId), ["t2"])
    }

    /// Spam leaves with Not spam: neither the button nor Move to → Inbox.
    func testSpamIsNotMoved() throws {
        let q = try makeDB([("t1", ["SPAM"])])
        XCTAssertTrue(try plan(q).targets.isEmpty)
        XCTAssertTrue(try plan(q, fromPicker: true).targets.isEmpty)
    }

    /// Muted: MUTED goes too, so the next reply lands in the Inbox; the
    /// undo mutes again.
    func testMutedConversationIsUnmuted() throws {
        let q = try makeDB([("t1", ["MUTED"])])
        let before = try thread(q)
        XCTAssertTrue(before.isMuted)
        let p = try plan(q)
        XCTAssertEqual(p.remotes[before.id], .modify(add: ["INBOX"], remove: ["MUTED"]))
        let moved = try XCTUnwrap(p.acted.first)
        XCTAssertFalse(moved.isMuted)
        XCTAssertEqual(p.undoRemotes[before.id], .modify(add: ["MUTED"], remove: ["INBOX"]))
        var restored = moved
        p.restore(&restored)
        XCTAssertTrue(restored.isMuted)
        XCTAssertFalse(restored.inInbox)
    }

    /// A lone draft has nothing to move: no button, no Move to → Inbox.
    func testDraftOnlyConversationIsNotOffered() throws {
        let q = try makeDB([("d1", ["DRAFT"]), ("d2", ["SENT", "DRAFT"])])
        let lone = try thread(q, "d1")
        XCTAssertTrue(InboxMove.isDraftOnly(lone))
        XCTAssertFalse(InboxMove.offered(for: lone))
        XCTAssertFalse(InboxMove.movable(lone))
        XCTAssertTrue(try plan(q, ["d1"], fromPicker: true).targets.isEmpty)
        let reply = try thread(q, "d2")
        XCTAssertFalse(InboxMove.isDraftOnly(reply), "a conversation with a draft reply moves")
        XCTAssertTrue(InboxMove.offered(for: reply))
    }

    /// From a label view, Move to → Inbox leaves that label (Gmail's Move
    /// to); the explicit button keeps it.
    func testMoveToInboxFromALabelViewLeavesThatLabel() throws {
        let q = try makeDB([("t1", ["Label_3"])])
        let id = key("t1")
        XCTAssertEqual(try plan(q, fromPicker: true, labelViewId: "Label_3").remotes[id],
                       .modify(add: ["INBOX"], remove: ["Label_3"]))
        XCTAssertEqual(try plan(q).remotes[id], .modify(add: ["INBOX"], remove: []))
        // Other destinations still leave the Inbox.
        XCTAssertEqual(ConversationAction.moveTo(labelId: "Label_7").remote,
                       .modify(add: ["Label_7"], remove: ["INBOX"]))
    }

    /// One bulk move: each conversation its own Gmail change; others'
    /// accounts and conversations already in the Inbox are left alone.
    func testBulkPlanHasOneChangePerConversation() throws {
        let q = try makeDB([("a", ["Label_7"]), ("b", ["MUTED"]), ("c", ["INBOX"]),
                            ("d", ["TRASH"])])
        let p = try plan(q, ["a", "b", "c", "d"], fromPicker: true, account: account)
        XCTAssertEqual(p.targets.map(\.gmailThreadId), ["a", "b", "d"])
        XCTAssertEqual(p.remotes[key("a")], .modify(add: ["INBOX"], remove: []))
        XCTAssertEqual(p.remotes[key("b")], .modify(add: ["INBOX"], remove: ["MUTED"]))
        XCTAssertEqual(p.remotes[key("d")], .modify(add: ["INBOX"], remove: ["TRASH"]))
        let other = try plan(q, ["a"], account: "someone@example.com")
        XCTAssertTrue(other.targets.isEmpty)
        XCTAssertEqual(other.skipped.count, 1)
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
        let entry = archived.first { $0.id == "act.moveToInbox" }
        XCTAssertEqual(entry?.title, "Move to inbox")
        XCTAssertEqual(entry?.action, .perform(.moveToInbox))
        XCTAssertEqual(entry?.shortcut, .moveToInbox)
        XCTAssertEqual(entry?.icon, "tray.and.arrow.down")

        let mixed = ids(focused: nil, checked: [T(offersMoveToInbox: true), T()])
        XCTAssertTrue(mixed.contains("act.archive"))
        XCTAssertFalse(mixed.contains("act.moveToInbox"))
        let allOut = ids(focused: nil, checked: [T(offersMoveToInbox: true), T(offersMoveToInbox: true)])
        XCTAssertTrue(allOut.contains("act.moveToInbox"))
        XCTAssertFalse(allOut.contains("act.archive"))
    }

    /// Gmail has no key for Move to inbox: it ships unbound and steals none.
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

    func testMovePickerListsInboxFirstForAConversationThatCanMove() throws {
        let q = try makeDB([("archived", ["Label_7"]), ("trash", ["TRASH"]), ("inbox", ["INBOX"]),
                            ("spam", ["SPAM"]), ("draft", ["DRAFT"])])
        func p(_ id: String, _ query: String = "") throws -> LabelPickerInboxRow.Placement? {
            LabelPickerInboxRow.placement(moveMode: true, thread: try thread(q, id), query: query)
        }
        XCTAssertEqual(try p("archived"), .first)
        XCTAssertEqual(try p("archived", "inbox"), .first)
        XCTAssertEqual(try p("archived", "In"), .first)
        XCTAssertEqual(try p("trash"), .first, "Gmail's Trash lists Inbox too")
        XCTAssertNil(try p("inbox"), "already in the Inbox")
        XCTAssertNil(try p("spam"), "spam leaves with Not spam")
        XCTAssertNil(try p("draft"), "a lone draft has nothing to move")
        XCTAssertNil(try p("archived", "work"), "filtered out by the query")
    }

    /// Over several conversations the row is there when any of them can
    /// move, whatever their order; only those move.
    func testMovePickerListsInboxWhenAnyTargetCanMove() throws {
        let q = try makeDB([("inbox", ["INBOX"]), ("archived", ["Label_7"])])
        let inbox = try thread(q, "inbox"), archived = try thread(q, "archived")
        for targets in [[inbox, archived], [archived, inbox]] {
            XCTAssertEqual(LabelPickerInboxRow.placement(moveMode: true, thread: targets[0],
                                                         moveTargets: targets, query: ""), .first)
        }
        XCTAssertNil(LabelPickerInboxRow.placement(moveMode: true, thread: inbox,
                                                   moveTargets: [inbox], query: ""))
        let p = InboxMove.Plan([inbox, archived], fromPicker: true)
        XCTAssertEqual(p.targets.map(\.gmailThreadId), ["archived"])
    }

    func testLabelAsPickerOffersMoveToInboxOnlyWhenTyped() throws {
        let q = try makeDB([("archived", ["Label_7"]), ("trash", ["TRASH"]), ("inbox", ["INBOX"]),
                            ("spam", ["SPAM"])])
        func p(_ id: String, _ query: String) throws -> LabelPickerInboxRow.Placement? {
            LabelPickerInboxRow.placement(moveMode: false, thread: try thread(q, id), query: query)
        }
        XCTAssertEqual(try p("archived", "inbox"), .last)
        XCTAssertEqual(try p("archived", "INBOX "), .last)
        XCTAssertNil(try p("archived", ""), "not listed among the labels")
        XCTAssertNil(try p("inbox", "inbox"), "already in the Inbox")
        XCTAssertNil(try p("trash", "inbox"), "Trash keeps its restore")
        XCTAssertNil(try p("spam", "inbox"))
    }

    /// What a pick does: the Inbox row is a move in both modes.
    func testPickerCommit() {
        XCTAssertEqual(LabelPickerInboxRow.commit(moveMode: false, labelId: "INBOX"), .moveToInbox)
        XCTAssertEqual(LabelPickerInboxRow.commit(moveMode: false, labelId: "Label_7"),
                       .toggleLabel("Label_7"))
        XCTAssertEqual(LabelPickerInboxRow.commit(moveMode: true, labelId: "INBOX"), .move("INBOX"))
        XCTAssertEqual(LabelPickerInboxRow.commit(moveMode: true, labelId: "Label_7"),
                       .move("Label_7"))
    }

    /// Space on a label, type "inbox", Return: the Move to inbox row still
    /// runs (a label row would only close after a pick).
    func testReturnRunsTheMoveToInboxRowAfterALabelWasToggled() {
        XCTAssertTrue(LabelPickerKeyRules.returnTogglesLabel(moveMode: false, changed: true,
                                                             actionRow: true))
        XCTAssertFalse(LabelPickerKeyRules.returnTogglesLabel(moveMode: false, changed: true))
        XCTAssertTrue(LabelPickerKeyRules.returnTogglesLabel(moveMode: false, changed: false))
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

    // MARK: - Find emails from

    /// Only a strict address is searched, quoted: a crafted From cannot add
    /// operators or empty the result.
    func testSenderSearchTakesOnlyAStrictAddressAndQuotesIt() {
        XCTAssertEqual(SenderSearch.strictAddress("alex@example.com"), "alex@example.com")
        XCTAssertEqual(SenderSearch.query("alex@example.com"), "from:\"alex@example.com\"")
        let crafted = [
            "alex@example.com in:anywhere",       // extra operator
            "x@example.com OR from:y@example.com",
            "\"Alex\" alex@example.com",           // quotes and space
            "alex@example.com\"",                  // a closing quote
            "alex(at)example.com", "alex@exa(mple).com",
            "alex@@example.com", "a@b@example.com", "@example.com", "alex@",
            "alex@example.com.", "alex@.example.com",
            "alex@example.com\n", "alex@exa\u{0007}mple.com",
            "alex@example.com\u{202E}moc", "<alex@example.com>", "a,b@example.com",
            "%@%", "a%@example.com", "a_b@example.com", "*@example.com",  // search wildcards
            "\u{0301}alex@example.com",                                   // leading combining mark
            "al\u{3164}ex@example.com",                                   // invisible filler
            "",
        ]
        for raw in crafted {
            XCTAssertNil(SenderSearch.strictAddress(raw), raw.debugDescription)
        }
        // The quoted query stays one token for the search parser.
        XCTAssertEqual(SearchQuery.tokenize(SenderSearch.query("alex@example.com")).count, 1)
    }

    func testSenderDisplayNameIsCleanedAndCapped() {
        XCTAssertEqual(SenderSearch.displayName("Alex Sample", address: "a@example.com"), "Alex Sample")
        XCTAssertEqual(SenderSearch.displayName("Alex\u{202E}elpmaS", address: "a@example.com"),
                       "AlexelpmaS", "bidi override removed")
        XCTAssertEqual(SenderSearch.displayName("Alex\n\tSample", address: "a@example.com"),
                       "Alex Sample", "controls removed, whitespace collapsed")
        XCTAssertEqual(SenderSearch.displayName("\u{200F} ", address: "a@example.com"), "a@example.com")
        // Stacked combining marks: one character of thousands of scalars.
        let zalgo = "A" + String(repeating: "\u{0301}", count: 5_000) + "lex"
        let capped = SenderSearch.displayName(zalgo, address: "a@example.com")
        XCTAssertLessThanOrEqual(capped.unicodeScalars.count, 121)
        // Invisible letters only: the address.
        XCTAssertEqual(SenderSearch.displayName("\u{3164}\u{115F}", address: "a@example.com"),
                       "a@example.com")
        XCTAssertEqual(SenderSearch.displayName("\u{0301}\u{0302}", address: "a@example.com"),
                       "a@example.com", "marks alone show nothing")
        let long = String(repeating: "x", count: 100)
        let shown = SenderSearch.displayName(long, address: "a@example.com")
        XCTAssertEqual(shown.count, 40)
        XCTAssertTrue(shown.hasSuffix("…"))
    }
}
