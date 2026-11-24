import XCTest
import GRDB

/// F-04: after an account is removed, nothing of it remains (Ask Mish chats,
/// snippet scopes, the search index, attachment copies, notifications),
/// and another account's are untouched.
final class AccountRemovalResidueTests: XCTestCase {

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        return q
    }

    private func insertAccount(_ db: Database, _ id: String) throws {
        try Account(id: id, displayName: id, historyId: nil,
                    lastSyncAt: nil, senderName: "").insert(db)
    }

    private func insertChat(_ db: Database, id: String, quoting text: String) throws {
        try ChatConversationRow(id: id, title: "t", providerID: "p", modelID: "m",
                                createdAt: Date(), updatedAt: Date()).insert(db)
        try ChatMessageRow(id: "\(id)-m", conversationId: id, role: "tool", text: "",
                           toolCallsJSON: "[]", toolResultsJSON: "[\"\(text)\"]",
                           promptTokens: nil, completionTokens: nil,
                           createdAt: Date()).insert(db)
    }

    private func chatIds(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT id FROM chatConversation ORDER BY id")
    }

    // MARK: - Ask Mish chats

    func testRemovalDeletesOnlyChatsThatDrewOnTheAccount() throws {
        let q = try makeDB()
        try q.write { db in
            try self.insertAccount(db, "a@x.com")
            try self.insertAccount(db, "b@x.com")
            try self.insertChat(db, id: "chat-a", quoting: "a's mail")
            try self.insertChat(db, id: "chat-b", quoting: "b's mail")
            try self.insertChat(db, id: "chat-ab", quoting: "both")
            try self.insertChat(db, id: "chat-none", quoting: "no mail")
            try ChatProvenance.record(db, conversationId: "chat-a", accounts: ["a@x.com"])
            try ChatProvenance.record(db, conversationId: "chat-b", accounts: ["b@x.com"])
            try ChatProvenance.record(db, conversationId: "chat-ab", accounts: [],
                                      includingAllAccounts: true)

            try AccountLifecycle.purgeAccount(db, id: "a@x.com")
        }
        try q.read { db in
            XCTAssertEqual(try self.chatIds(db), ["chat-b", "chat-none"])
            XCTAssertEqual(try ChatMessageRow.fetchCount(db), 2,
                           "the deleted chats' messages cascade")
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM chatConversationAccount WHERE accountId = 'a@x.com'
                """), 0)
            XCTAssertEqual(try ChatProvenance.accounts(db, conversationId: "chat-b"),
                           ["b@x.com"])
        }
    }

    /// Conversations stored before v48 say nothing about the accounts they
    /// drew on: any removal deletes them. Inserted the way an older build
    /// did, without the provenance column.
    func testRemovalDeletesEveryChatWithoutProvenance() throws {
        let q = try makeDB()
        try q.write { db in
            try self.insertAccount(db, "a@x.com")
            try self.insertAccount(db, "b@x.com")
            try db.execute(sql: """
                INSERT INTO chatConversation (id, title, providerID, modelID, createdAt, updatedAt)
                VALUES ('legacy', 't', 'p', 'm', '2026-01-01 00:00:00', '2026-01-01 00:00:00')
                """)
            try db.execute(sql: """
                INSERT INTO chatMessage (id, conversationId, role, text, toolCallsJSON,
                                         toolResultsJSON, createdAt)
                VALUES ('legacy-m', 'legacy', 'assistant', 'quoted mail', '[]', '[]',
                        '2026-01-01 00:00:00')
                """)
            try AccountLifecycle.purgeAccount(db, id: "b@x.com")
        }
        try q.read { db in
            XCTAssertEqual(try self.chatIds(db), [])
            XCTAssertEqual(try ChatMessageRow.fetchCount(db), 0)
        }
    }

    func testMigratedConversationReadsAsUntrackedAndNewOneAsTracked() throws {
        let q = try makeDB()
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO chatConversation (id, title, providerID, modelID, createdAt, updatedAt)
                VALUES ('old', 't', 'p', 'm', '2026-01-01 00:00:00', '2026-01-01 00:00:00')
                """)
            try ChatConversationRow(id: "new", title: "t", providerID: "p", modelID: "m",
                                    createdAt: Date(), updatedAt: Date()).insert(db)
        }
        try q.read { db in
            XCTAssertEqual(try ChatConversationRow.fetchOne(db, key: "old")?.tracksAccounts, false)
            XCTAssertEqual(try ChatConversationRow.fetchOne(db, key: "new")?.tracksAccounts, true)
        }
    }

    /// A turn that read an account's mail and writes after that account was
    /// removed must not leave the chat behind.
    func testRecordingAnAccountRemovedMeanwhileDeletesTheChat() throws {
        let q = try makeDB()
        let stored = try q.write { db -> Bool in
            try self.insertAccount(db, "b@x.com")
            try self.insertChat(db, id: "chat", quoting: "a's mail")
            return try ChatProvenance.record(db, conversationId: "chat",
                                             accounts: ["a@x.com"])
        }
        XCTAssertFalse(stored)
        try q.read { db in
            XCTAssertEqual(try self.chatIds(db), [])
        }
    }

    func testRecordingOnADeletedChatWritesNothing() throws {
        let q = try makeDB()
        let stored = try q.write { db -> Bool in
            try self.insertAccount(db, "a@x.com")
            return try ChatProvenance.record(db, conversationId: "gone",
                                             accounts: ["a@x.com"])
        }
        XCTAssertFalse(stored)
        try q.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM chatConversationAccount"), 0)
        }
    }

    // MARK: - Snippets

    func testRemovalDropsTheAccountFromSnippetScopes() throws {
        let q = try makeDB()
        try q.write { db in
            try self.insertAccount(db, "a@x.com")
            try self.insertAccount(db, "b@x.com")
            var onlyA = Snippet(id: nil, name: "only a", body: "x")
            onlyA.accountIds = ["A@x.com"]
            try onlyA.insert(db)
            var both = Snippet(id: nil, name: "both", body: "x")
            both.accountIds = ["a@x.com", "b@x.com"]
            try both.insert(db)
            var onlyB = Snippet(id: nil, name: "only b", body: "x")
            onlyB.accountIds = ["b@x.com"]
            try onlyB.insert(db)
            try Snippet(id: nil, name: "everyone", body: "x").insert(db)

            try AccountLifecycle.purgeAccount(db, id: "a@x.com")
        }
        try q.read { db in
            let rows = try Snippet.order(Column("name")).fetchAll(db)
            XCTAssertEqual(rows.map(\.name), ["both", "everyone", "only b"],
                           "a snippet scoped only to the removed account goes, rather than opening up to every account")
            XCTAssertEqual(rows.first { $0.name == "both" }?.accountIds, ["b@x.com"])
            XCTAssertEqual(rows.first { $0.name == "only b" }?.accountIds, ["b@x.com"])
            XCTAssertEqual(rows.first { $0.name == "everyone" }?.accountIds, [])
        }
    }

    // MARK: - Search index

    func testRemovalLeavesNoSearchTermsOfTheAccount() throws {
        let q = try makeDB()
        try q.write { db in
            for (account, word) in [("a@x.com", "zanzibarquux"), ("b@x.com", "mozambiquux")] {
                try self.insertAccount(db, account)
                let thread = MailThread(
                    id: "\(account):t1", accountId: account, gmailThreadId: "t1",
                    subject: word, snippet: "sn", fromDisplay: "F",
                    lastDate: Date(), isUnread: false, isStarred: false,
                    inInbox: true, inTrash: false, labelIds: "INBOX",
                    snoozeUntil: nil, participants: "F", messageCount: 1,
                    hasAttachment: false, reminderAt: nil)
                try thread.insert(db)
                try Message(
                    id: "\(account):m1", accountId: account, gmailId: "m1",
                    threadId: thread.id, fromHeader: "F <f@y.com>", toHeader: account,
                    ccHeader: "", subject: word, date: Date(),
                    snippet: "sn", bodyText: "body", bodyHTML: nil,
                    messageIdHeader: "<m1@x>", referencesHeader: "",
                    labelIds: "INBOX", isUnread: false, hasAttachment: false).insert(db)
            }
            try AccountLifecycle.purgeAccount(db, id: "a@x.com")
        }
        try q.read { db in
            let terms = try String.fetchAll(db, sql: "SELECT term FROM message_fts_vocab")
            XCTAssertFalse(terms.contains("zanzibarquux"))
            XCTAssertTrue(terms.contains("mozambiquux"))
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM message_fts WHERE message_fts MATCH 'zanzibarquux'
                """), 0)
        }
    }

    // MARK: - Provenance still to write

    /// A write that fails (a busy database) must not drop the "every
    /// account" mark of a tool turn: the results written later still need it.
    func testPendingProvenanceStaysUntilAWriteSucceeds() {
        var pending = ChatProvenance.Pending()
        pending.noteTools()
        pending.noteThread(accountId: "a@x.com")
        let firstAttempt = pending
        // The write of `firstAttempt` failed: nothing is committed.
        XCTAssertTrue(pending.needsAllAccounts)
        XCTAssertEqual(pending.accounts, ["a@x.com"])

        pending.noteThread(accountId: "b@x.com")
        let retry = pending
        pending.committed(retry)
        XCTAssertFalse(pending.needsAllAccounts)
        XCTAssertEqual(pending.accounts, [])
        XCTAssertNotEqual(firstAttempt, pending)
    }

    func testProvenanceNotedDuringAWriteIsKept() {
        var pending = ChatProvenance.Pending()
        pending.noteThread(accountId: "a@x.com")
        let inFlight = pending
        pending.noteThread(accountId: "b@x.com")
        pending.noteTools()
        pending.committed(inFlight)
        XCTAssertEqual(pending.accounts, ["b@x.com"])
        XCTAssertTrue(pending.needsAllAccounts)
    }

    /// The open thread named in the system prompt counts even when none of
    /// its bodies was injected.
    func testRecordingPendingProvenanceStoresTheAccounts() throws {
        let q = try makeDB()
        try q.write { db in
            try self.insertAccount(db, "a@x.com")
            try self.insertAccount(db, "b@x.com")
            try self.insertChat(db, id: "thread", quoting: "")
            try self.insertChat(db, id: "tools", quoting: "")
            var thread = ChatProvenance.Pending()
            thread.noteThread(accountId: "a@x.com")
            XCTAssertTrue(try ChatProvenance.record(db, conversationId: "thread", pending: thread))
            var tools = ChatProvenance.Pending()
            tools.noteTools()
            XCTAssertTrue(try ChatProvenance.record(db, conversationId: "tools", pending: tools))
            XCTAssertEqual(try ChatProvenance.accounts(db, conversationId: "thread"), ["a@x.com"])
            XCTAssertEqual(try ChatProvenance.accounts(db, conversationId: "tools"),
                           ["a@x.com", "b@x.com"])
            try AccountLifecycle.purgeAccount(db, id: "b@x.com")
        }
        try q.read { db in
            XCTAssertEqual(try self.chatIds(db), ["thread"])
        }
    }

    // MARK: - Late writes and leftovers

    /// An open composer's autosave or a schedule that lands after the purge
    /// is refused instead of storing mail for an account that is gone.
    func testWritesForARemovedAccountAreRefused() throws {
        let q = try makeDB()
        try q.write { db in
            try self.insertAccount(db, "b@x.com")
            XCTAssertNoThrow(try AccountLifecycle.requireLiveAccount(db, id: "b@x.com"))
            XCTAssertNoThrow(try AccountLifecycle.requireLiveAccount(db, id: ""))
            XCTAssertThrowsError(try AccountLifecycle.requireLiveAccount(db, id: "a@x.com")) {
                XCTAssertTrue($0 is AccountLifecycle.AccountRemovedError)
            }
        }
    }

    /// Rows that a late write or an interrupted removal left for an account
    /// that no longer exists go at launch; the live account's stay.
    func testLaunchSweepDeletesRowsOfAccountsThatAreGone() throws {
        let q = try makeDB()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try q.write { db in
            try self.insertAccount(db, "b@x.com")
            for account in ["a@x.com", "b@x.com"] {
                try LocalDraft(
                    id: nil, accountId: account, fromEmail: "", toHeader: "j@y.com",
                    ccHeader: "", bccHeader: "", subject: "Draft", body: "b",
                    replyToMessageId: nil, forward: false, replacingDraftId: nil,
                    attachmentsJSON: Data("[]".utf8), createdAt: now, updatedAt: now).insert(db)
                try ScheduledSend(
                    id: nil, accountId: account, toHeader: "j@y.com",
                    ccHeader: "", bccHeader: "", subject: "Later", body: "b",
                    sendAt: now, replyToMessageId: nil, forward: false, replacingDraftId: nil,
                    attachmentsJSON: Data("[]".utf8), createdAt: now).insert(db)
                try PendingThreadOp.enqueue(db, accountId: account, gmailThreadId: "t1",
                                            change: .modify(add: ["STARRED"]))
                var view = SavedView.empty()
                view.name = "View \(account)"
                view.accountId = account
                try view.insert(db)
                try ThreadAICategory(threadId: "\(account):t1", category: "fyi").insert(db)
                try self.insertChat(db, id: "chat-\(account)", quoting: "x")
            }
            try MailThread(
                id: "b@x.com:t1", accountId: "b@x.com", gmailThreadId: "t1",
                subject: "s", snippet: "sn", fromDisplay: "F",
                lastDate: now, isUnread: false, isStarred: false,
                inInbox: true, inTrash: false, labelIds: "INBOX",
                snoozeUntil: nil, participants: "F", messageCount: 1,
                hasAttachment: false, reminderAt: nil).insert(db)
            var unified = SavedView.empty()
            unified.name = "All accounts"
            try unified.insert(db)
            // Provenance recorded while a@x.com existed; its row is gone now.
            try db.execute(sql: """
                INSERT INTO chatConversationAccount (conversationId, accountId)
                VALUES ('chat-a@x.com', 'a@x.com'), ('chat-b@x.com', 'b@x.com')
                """)

            try AccountLifecycle.purgeOrphanRows(db)
        }
        try q.read { db in
            for table in ["localDraft", "scheduledSend", "pendingThreadOp"] {
                XCTAssertEqual(try String.fetchAll(db, sql: "SELECT accountId FROM \(table)"),
                               ["b@x.com"], table)
            }
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT name FROM savedView ORDER BY name"),
                           ["All accounts", "View b@x.com"])
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT threadId FROM threadAI"),
                           ["b@x.com:t1"])
            XCTAssertEqual(try self.chatIds(db), ["chat-b@x.com"])
        }
    }

    // MARK: - Notifications

    /// Every identifier the app posts names its account, so a removal
    /// withdraws exactly that account's notifications.
    func testNotificationIdentifiersSelectOnlyTheRemovedAccount() {
        let a = NotificationContent.MailItem(accountId: "a@x.com", threadId: "a@x.com:t1",
                                             sender: "S", subject: "Sub")
        // Starts with "a@x.com": must not be taken for it.
        let longer = NotificationContent.MailItem(accountId: "a@x.com.au",
                                                  threadId: "a@x.com.au:t2",
                                                  sender: "S", subject: "Sub")
        let b = NotificationContent.MailItem(accountId: "b@x.com", threadId: "b@x.com:t3",
                                             sender: "S", subject: "Sub")
        var ids: [String] = []
        for details in [false, true] {
            ids += NotificationContent.newMail([a], showDetails: details).map(\.id)
            ids += NotificationContent.newMail([longer], showDetails: details).map(\.id)
            ids += NotificationContent.newMail([b], showDetails: details).map(\.id)
            ids += NotificationContent.reminders([a], showDetails: details).map(\.id)
            ids += NotificationContent.reminders([b, longer], showDetails: details).map(\.id)
            ids.append(NotificationContent.scheduledSent(
                accountId: "a@x.com", rowId: 7, subject: "s", showDetails: details).id)
            ids.append(NotificationContent.scheduledSent(
                accountId: "b@x.com", rowId: 8, subject: "s", showDetails: details).id)
        }
        let mixedBatch = NotificationContent.newMail(
            [a, b, longer, b], showDetails: false).map(\.id)
        XCTAssertEqual(mixedBatch.count, 1)

        let removed = (ids + mixedBatch).filter {
            NotificationContent.belongs($0, toAccount: "a@x.com")
        }
        let kept = (ids + mixedBatch).filter {
            !NotificationContent.belongs($0, toAccount: "a@x.com")
        }
        XCTAssertFalse(removed.isEmpty)
        for id in removed {
            XCTAssertTrue(id.contains(NotificationContent.identifier(
                kind: .mail, accounts: ["a@x.com"], key: "").split(separator: "/")[1]), id)
        }
        XCTAssertTrue(removed.contains(mixedBatch[0]),
                      "a count that includes the account goes with it")
        XCTAssertTrue(kept.contains { $0.hasPrefix("mail/") && !$0.contains("batch") })
        XCTAssertTrue(kept.contains { $0.hasPrefix("reminder/") })
        XCTAssertTrue(kept.contains { $0.hasPrefix("scheduled/") })
        for id in kept {
            XCTAssertFalse(NotificationContent.belongs(id, toAccount: "a@x.com"), id)
        }
    }

    /// Earlier builds used `mail.<threadId>` and friends. Those cannot say
    /// which account they were for, so any removal withdraws them.
    func testLegacyNotificationIdentifiersAreWithdrawnOnAnyRemoval() {
        for id in ["mail.a@x.com:t1", "mail.batch", "reminder.b@x.com:t2", "scheduled.4"] {
            XCTAssertTrue(NotificationContent.belongs(id, toAccount: "c@x.com"), id)
        }
        XCTAssertFalse(NotificationContent.belongs("update.available", toAccount: "c@x.com"))
    }
}
