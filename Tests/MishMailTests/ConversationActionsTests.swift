import XCTest
import GRDB

/// Gmail's mute (`m`), important / not important (`+` `=` / `-`) and move to
/// (`v`): the local write, what reaches Gmail (through a stub client), the
/// revert when Gmail refuses, the next sync, the sidebar counts and the Dock
/// badge. `MailStore` runs exactly these values through `mutateThread(s)`;
/// the hostless test target does not compile `MailStore`.
final class ConversationActionsTests: XCTestCase {
    private let account = "ron@x.com"

    // MARK: - Fixtures

    private func makeDB(_ threads: [(id: String, labels: [String])]) throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: self.account, displayName: "P", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
            for (id, labels) in threads {
                for (n, messageLabels) in labels.enumerated() {
                    try self.insertMessage(db, thread: id, n: n, labels: messageLabels,
                                           date: Date(timeIntervalSince1970: 1_700_000_000 + Double(n) * 60))
                }
                try SyncEngine.deriveThreads(db, for: [self.key(id)], accountId: self.account)
            }
        }
        return q
    }

    private func key(_ id: String) -> String { "\(account):\(id)" }

    private func insertMessage(_ db: Database, thread: String, n: Int, labels: String,
                               date: Date) throws {
        try Message(id: "\(account):m-\(thread)-\(n)", accountId: account,
                    gmailId: "m-\(thread)-\(n)", threadId: key(thread),
                    fromHeader: "a@b.com", toHeader: account, ccHeader: "", bccHeader: "",
                    subject: "Hello", date: date, snippet: "", bodyText: "",
                    bodyHTML: nil, messageIdHeader: "", referencesHeader: "",
                    labelIds: labels, isUnread: labels.contains("UNREAD"),
                    hasAttachment: false).insert(db)
    }

    private func thread(_ q: DatabaseQueue, _ id: String = "t1") throws -> MailThread {
        try XCTUnwrap(try q.read { try MailThread.fetchOne($0, key: self.key(id)) })
    }

    private func write(_ q: DatabaseQueue, from old: MailThread, to new: MailThread) throws {
        try q.write { try OptimisticThreadWrite.updateChangedColumns($0, from: old, to: new) }
    }

    /// What `MailStore.rederiveThreadFromMessages` writes on a refusal.
    private func rederive(_ q: DatabaseQueue, _ id: String = "t1") throws {
        try q.write { db in
            try OptimisticThreadWrite.rederiveOrDelete(db, threadId: self.key(id),
                                                       accountId: self.account)
        }
    }

    private func badge(_ q: DatabaseQueue) throws -> Int {
        try q.read {
            try SidebarCounts.fetch(db: $0, activeAccount: nil, badgeAccount: nil,
                                    now: Date(), hideCategories: []).badge
        }
    }

    /// Gmail's history patch: the message rows take the edit, the thread is
    /// re-derived from them (what the next sync does).
    private func historyApplies(_ q: DatabaseQueue, _ change: RemoteThreadChange,
                                thread id: String = "t1") throws {
        try q.write { db in
            let rows = try Message.filter(Column("threadId") == self.key(id)).fetchAll(db)
            for var m in rows {
                var set = Set(m.labelIds.split(separator: " ").map(String.init))
                set.subtract(change.removeLabels)
                set.formUnion(change.addLabels)
                m.labelIds = set.sorted().joined(separator: " ")
                try m.update(db)
            }
            try SyncEngine.deriveThreads(db, for: [self.key(id)], accountId: self.account)
        }
    }

    // MARK: - Mute

    func testMuteArchivesLocallyAndSendsMutedMinusInbox() throws {
        let q = try makeDB([("t1", ["INBOX UNREAD"])])
        let before = try thread(q)
        var muted = before
        ConversationAction.mute.apply(&muted)
        XCTAssertTrue(muted.isMuted)
        XCTAssertFalse(muted.inInbox)
        XCTAssertTrue(muted.isUnread, "Gmail's mute does not mark the conversation read")
        XCTAssertEqual(ConversationAction.mute.remote, .modify(add: ["MUTED"], remove: ["INBOX"]))

        let badgeBefore = try badge(q)
        XCTAssertEqual(DockBadge.delta(from: before, to: muted, badgeAccount: nil), -1)
        try write(q, from: before, to: muted)
        XCTAssertEqual(try badge(q), badgeBefore - 1, "the recount agrees with the delta")
        let stored = try thread(q)
        XCTAssertFalse(stored.inInbox)
        XCTAssertTrue(stored.isMuted)
    }

    /// The point of mute: once Gmail has it, a reply arrives without INBOX
    /// (Gmail files it), and the next sync keeps the conversation out of the
    /// inbox, the badge and the new-mail notifications.
    func testMutedConversationStaysOutOfTheInboxWhenAReplyArrives() throws {
        let q = try makeDB([("t1", ["INBOX"])])
        let before = try thread(q)
        var muted = before
        ConversationAction.mute.apply(&muted)
        try write(q, from: before, to: muted)
        try historyApplies(q, ConversationAction.mute.remote)
        let badgeBefore = try badge(q)

        // The reply as Gmail delivers it on a muted conversation.
        try q.write { db in
            try self.insertMessage(db, thread: "t1", n: 1, labels: "MUTED UNREAD",
                                   date: Date(timeIntervalSince1970: 1_800_000_000))
            try SyncEngine.deriveThreads(db, for: [self.key("t1")], accountId: self.account)
        }
        let synced = try thread(q)
        XCTAssertTrue(synced.isUnread)
        XCTAssertTrue(synced.isMuted)
        XCTAssertFalse(synced.inInbox, "a muted conversation must not come back to the inbox")
        XCTAssertEqual(try badge(q), badgeBefore, "nor raise the badge")
        let candidate = try q.read { db in
            try XCTUnwrap(NewMailNotifications.Candidate.fetchOne(
                db, sql: """
                    SELECT id, fromEmail, allFromEmails, lastInboundDate, isUnread, inInbox,
                           inTrash, inSpam, inPromotions, inSocial, snoozeUntil
                    FROM thread WHERE id = ?
                    """, arguments: [self.key("t1")]))
        }
        XCTAssertFalse(NewMailNotifications.isEligible(candidate, now: Date()),
                       "nor notify")
    }

    func testMuteUndoRestoresTheInboxOnlyWhenItWasThere() throws {
        let q = try makeDB([("t1", ["INBOX UNREAD"]), ("t2", ["UNREAD"])])
        for (id, hadInbox) in [("t1", true), ("t2", false)] {
            let original = try thread(q, id)
            var acted = original
            ConversationAction.mute.apply(&acted)
            try write(q, from: original, to: acted)
            let undo = ConversationAction.mute.undoRemote(original: original)
            XCTAssertEqual(undo, .modify(add: hadInbox ? ["INBOX"] : [], remove: ["MUTED"]))
            var restored = acted
            ConversationAction.mute.restore(original: original, &restored)
            try write(q, from: acted, to: restored)
            let row = try thread(q, id)
            XCTAssertEqual(row.inInbox, hadInbox, id)
            XCTAssertFalse(row.isMuted, id)
        }
    }

    func testUnmuteDoesNotBringTheConversationBack() throws {
        let q = try makeDB([("t1", ["MUTED"])])
        let original = try thread(q)
        XCTAssertTrue(original.isMuted)
        var acted = original
        ConversationAction.unmute.apply(&acted)
        XCTAssertFalse(acted.isMuted)
        XCTAssertFalse(acted.inInbox)
        XCTAssertEqual(ConversationAction.unmute.remote, .modify(add: [], remove: ["MUTED"]))
        XCTAssertEqual(ConversationAction.unmute.undoRemote(original: original),
                       .modify(add: ["MUTED"], remove: []))
    }

    func testMuteKeyTogglesLikeGmail() throws {
        let q = try makeDB([("a", ["INBOX"]), ("b", ["MUTED"]), ("c", ["MUTED"])])
        let a = try thread(q, "a"), b = try thread(q, "b"), c = try thread(q, "c")
        XCTAssertEqual(ConversationAction.muteToggle(for: [a]), .mute)
        XCTAssertEqual(ConversationAction.muteToggle(for: [b]), .unmute)
        XCTAssertEqual(ConversationAction.muteToggle(for: [a, b]), .mute,
                       "a mixed selection is muted")
        XCTAssertEqual(ConversationAction.muteToggle(for: [b, c]), .unmute)
    }

    // MARK: - Importance

    func testImportanceEditsTheLabelOnlyAndLeavesTheBadge() throws {
        let q = try makeDB([("t1", ["INBOX UNREAD"])])
        let before = try thread(q)
        var marked = before
        ConversationAction.markImportant.apply(&marked)
        XCTAssertTrue(marked.isImportant)
        XCTAssertTrue(marked.inInbox)
        XCTAssertEqual(ConversationAction.markImportant.remote,
                       .modify(add: ["IMPORTANT"], remove: []))
        XCTAssertEqual(DockBadge.delta(from: before, to: marked, badgeAccount: nil), 0)
        try write(q, from: before, to: marked)
        XCTAssertTrue(try thread(q).isImportant)

        var unmarked = marked
        ConversationAction.markNotImportant.apply(&unmarked)
        XCTAssertFalse(unmarked.isImportant)
        XCTAssertEqual(ConversationAction.markNotImportant.remote,
                       .modify(add: [], remove: ["IMPORTANT"]))
        try write(q, from: marked, to: unmarked)
        XCTAssertFalse(try thread(q).isImportant)
        try historyApplies(q, ConversationAction.markNotImportant.remote)
        XCTAssertFalse(try thread(q).isImportant, "the next sync keeps it")
    }

    // MARK: - Move to

    func testMoveToAddsTheLabelAndLeavesTheInbox() throws {
        let q = try makeDB([("t1", ["INBOX UNREAD"])])
        let before = try thread(q)
        let action = ConversationAction.moveTo(labelId: "Label_7")
        var moved = before
        action.apply(&moved)
        XCTAssertFalse(moved.inInbox)
        XCTAssertEqual(moved.userLabelIds, ["Label_7"])
        XCTAssertEqual(action.remote, .modify(add: ["Label_7"], remove: ["INBOX"]))
        XCTAssertEqual(DockBadge.delta(from: before, to: moved, badgeAccount: nil), -1)
        let badgeBefore = try badge(q)
        try write(q, from: before, to: moved)
        XCTAssertEqual(try badge(q), badgeBefore - 1)
        try historyApplies(q, action.remote)
        let synced = try thread(q)
        XCTAssertFalse(synced.inInbox, "the next sync keeps the move")
        XCTAssertEqual(synced.userLabelIds, ["Label_7"])
    }

    /// The undo gives back what the move took, per thread: the inbox only
    /// where it was, and the label only where it was new.
    func testBulkMoveUndoIsGroupedByWhatEachThreadHad() throws {
        let q = try makeDB([("a", ["INBOX"]), ("b", ["INBOX Label_7"]), ("c", [""]),
                            ("d", ["INBOX"])])
        let originals = try ["a", "b", "c", "d"].map { try thread(q, $0) }
        let action = ConversationAction.moveTo(labelId: "Label_7")
        let acted = originals.map { t -> MailThread in var c = t; action.apply(&c); return c }
        let groups = action.undoGroups(acted: acted, originals: originals)
        XCTAssertEqual(groups.map(\.change), [
            .modify(add: ["INBOX"], remove: ["Label_7"]),
            .modify(add: ["INBOX"], remove: []),
            .modify(add: [], remove: ["Label_7"]),
        ])
        XCTAssertEqual(groups.map { $0.threads.map(\.gmailThreadId) }, [["a", "d"], ["b"], ["c"]])

        try q.write { db in
            for (o, a) in zip(originals, acted) {
                try OptimisticThreadWrite.updateChangedColumns(db, from: o, to: a)
            }
            for group in groups {
                for t in group.threads {
                    var restored = t
                    action.restore(original: originals.first { $0.id == t.id }!, &restored)
                    try OptimisticThreadWrite.updateChangedColumns(db, from: t, to: restored)
                }
            }
        }
        for o in originals {
            let row = try thread(q, o.gmailThreadId)
            XCTAssertEqual(row.inInbox, o.inInbox, o.gmailThreadId)
            XCTAssertEqual(row.userLabelIds, o.userLabelIds, o.gmailThreadId)
        }
    }

    // MARK: - Gmail (stub client), refusal and revert

    func testEachActionReachesGmailAsOneThreadModify() async throws {
        let stub = StubThreadEditing()
        let cases: [(ConversationAction, [String], [String])] = [
            (.mute, ["MUTED"], ["INBOX"]),
            (.unmute, [], ["MUTED"]),
            (.markImportant, ["IMPORTANT"], []),
            (.markNotImportant, [], ["IMPORTANT"]),
            (.moveTo(labelId: "Label_7"), ["Label_7"], ["INBOX"]),
        ]
        for (action, _, _) in cases {
            try await RemoteThreadSend.send(action.remote, via: stub, gmailThreadId: "t1")
        }
        let calls = await stub.calls
        let expected: [StubThreadEditing.Call] = cases.map {
            .modify(id: "t1", add: $0.1, remove: $0.2)
        }
        XCTAssertEqual(calls, expected)
    }

    /// Gmail refuses (a 400, say an unknown label): the store re-derives the
    /// thread from its message rows, which still hold Gmail's state.
    func testRefusedMuteRevertsFromTheMessageRows() async throws {
        let q = try makeDB([("t1", ["INBOX UNREAD"])])
        let before = try thread(q)
        var muted = before
        ConversationAction.mute.apply(&muted)
        try write(q, from: before, to: muted)

        let stub = StubThreadEditing(error: GmailError.http(400, "Invalid label"))
        do {
            try await RemoteThreadSend.send(ConversationAction.mute.remote, via: stub,
                                            gmailThreadId: "t1")
            XCTFail("the stub refuses")
        } catch {
            XCTAssertEqual(RemoteThreadSend.disposition(for: error), .revert)
        }
        try rederive(q)
        let reverted = try thread(q)
        XCTAssertTrue(reverted.inInbox)
        XCTAssertFalse(reverted.isMuted)
        XCTAssertTrue(reverted.isUnread)
    }

    func testOfflineAndServerErrorsQueueInsteadOfReverting() {
        XCTAssertEqual(RemoteThreadSend.disposition(for: URLError(.notConnectedToInternet)),
                       .queueOffline)
        XCTAssertEqual(RemoteThreadSend.disposition(for: GmailError.http(503, "")), .queue)
        XCTAssertEqual(RemoteThreadSend.disposition(for: GmailError.http(429, "")), .queue)
        XCTAssertEqual(RemoteThreadSend.disposition(for: GmailError.http(404, "")), .revert)
    }

    /// Queued offline, mute then unmute fold into one modify: the archive
    /// part stays (unmute does not bring the conversation back).
    func testMuteThenUnmuteOfflineFoldsToTheArchive() {
        let folded = ConversationAction.mute.remote.merged(with: ConversationAction.unmute.remote)
        XCTAssertEqual(folded, .modify(add: [], remove: ["INBOX"]))
    }
}

/// Records the thread edits that would reach Gmail.
actor StubThreadEditing: GmailThreadEditing {
    enum Call: Equatable {
        case modify(id: String, add: [String], remove: [String])
        case trash(id: String)
    }
    private(set) var calls: [Call] = []
    private let error: Error?

    init(error: Error? = nil) { self.error = error }

    func modifyThread(id: String, add: [String], remove: [String]) async throws {
        calls.append(.modify(id: id, add: add, remove: remove))
        if let error { throw error }
    }

    func trashThread(id: String) async throws {
        calls.append(.trash(id: id))
        if let error { throw error }
    }
}
