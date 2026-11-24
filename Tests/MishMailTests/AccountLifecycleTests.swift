import XCTest
import GRDB

final class AccountLifecycleTests: XCTestCase {

    func testReauthRequiredForInvalidGrantAndMissingToken() {
        XCTAssertTrue(AccountLifecycle.isReauthRequired(OAuthError.invalidGrant))
        XCTAssertTrue(AccountLifecycle.isReauthRequired(GmailError.noRefreshToken("a@x.com")))
        XCTAssertFalse(AccountLifecycle.isReauthRequired(OAuthError.cancelled))
        XCTAssertFalse(AccountLifecycle.isReauthRequired(GmailError.historyExpired))
        XCTAssertFalse(AccountLifecycle.isReauthRequired(GmailError.partialFetch(failedCount: 2)))
        XCTAssertFalse(AccountLifecycle.isReauthRequired(URLError(.timedOut)))
    }

    func testDemoConnectBlockedOnlyForFixtureKey() {
        XCTAssertTrue(AccountLifecycle.blocksDemoConnect(usesFixtureDatabaseKey: true))
        XCTAssertFalse(AccountLifecycle.blocksDemoConnect(usesFixtureDatabaseKey: false))
        XCTAssertTrue(AccountLifecycle.demoConnectBlockedMessage.contains("DEMO=0"))
    }

    func testSignInInsertsNewAccount() {
        let account = AccountLifecycle.accountAfterSignIn(
            email: "a@x.com", name: "Ada", existing: nil)
        XCTAssertEqual(account.id, "a@x.com")
        XCTAssertEqual(account.displayName, "Ada")
        XCTAssertEqual(account.senderName, "Ada")
        XCTAssertNil(account.historyId)
        XCTAssertNil(account.lastSyncAt)
    }

    func testReauthPreservesHistoryAndFillsEmptySenderName() {
        var existing = Account(
            id: "a@x.com", displayName: "a@x.com",
            historyId: "99", lastSyncAt: Date(timeIntervalSince1970: 50),
            senderName: "")
        let updated = AccountLifecycle.accountAfterSignIn(
            email: "a@x.com", name: "Ada", existing: existing)
        XCTAssertEqual(updated.historyId, "99")
        XCTAssertEqual(updated.lastSyncAt, existing.lastSyncAt)
        XCTAssertEqual(updated.displayName, "Ada",
                       "email-as-display-name is replaced by the profile name")
        XCTAssertEqual(updated.senderName, "Ada")

        existing.displayName = "Personal"
        existing.senderName = "Kept"
        let nicknamed = AccountLifecycle.accountAfterSignIn(
            email: "a@x.com", name: "Ada", existing: existing)
        XCTAssertEqual(nicknamed.displayName, "Personal")
        XCTAssertEqual(nicknamed.senderName, "Kept")
    }

    // MARK: - Account removal

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        return q
    }

    /// One row in every account-owned table that has no foreign key.
    private func seed(_ db: Database, account: String) throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try Account(id: account, displayName: account, historyId: "7",
                    lastSyncAt: nil, senderName: "").insert(db)
        try MailThread(
            id: "\(account):t1", accountId: account, gmailThreadId: "t1",
            subject: "s", snippet: "sn", fromDisplay: "F",
            lastDate: now, isUnread: false, isStarred: false,
            inInbox: true, inTrash: false, labelIds: "INBOX",
            snoozeUntil: nil, participants: "F", messageCount: 1,
            hasAttachment: false, reminderAt: nil).insert(db)
        try ThreadAICategory(threadId: "\(account):t1", category: "fyi").insert(db)
        try PendingThreadOp.enqueue(db, accountId: account, gmailThreadId: "t1",
                                    change: .modify(add: ["STARRED"]))
        try LocalDraft(
            id: nil, accountId: account, fromEmail: "", toHeader: "j@y.com",
            ccHeader: "", bccHeader: "", subject: "Offline", body: "b",
            replyToMessageId: nil, forward: false, replacingDraftId: nil,
            attachmentsJSON: Data("[]".utf8), createdAt: now, updatedAt: now).insert(db)
        try ScheduledSend(
            id: nil, accountId: account, toHeader: "j@y.com",
            ccHeader: "", bccHeader: "", subject: "Later", body: "b",
            sendAt: now, replyToMessageId: nil, forward: false, replacingDraftId: nil,
            attachmentsJSON: Data("[]".utf8), createdAt: now).insert(db)
        var view = SavedView.empty()
        view.name = "View \(account)"
        view.accountId = account
        try view.insert(db)
    }

    private func counts(_ db: Database, account: String) throws -> [String: Int] {
        var out: [String: Int] = [:]
        for table in ["account", "thread", "pendingThreadOp", "localDraft",
                      "scheduledSend", "savedView"] {
            let column = table == "account" ? "id" : "accountId"
            out[table] = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM \(table) WHERE \(column) = ?",
                arguments: [account])
        }
        out["threadAI"] = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM threadAI WHERE threadId = ?",
            arguments: ["\(account):t1"])
        return out
    }

    func testPurgeAccountRemovesOnlyThatAccountsRows() throws {
        let q = try makeDB()
        try q.write { db in
            try self.seed(db, account: "a@x.com")
            try self.seed(db, account: "b@x.com")
            try AccountLifecycle.purgeAccount(db, id: "a@x.com")
        }
        try q.read { db in
            XCTAssertEqual(try self.counts(db, account: "a@x.com"), [
                "account": 0, "thread": 0, "threadAI": 0, "pendingThreadOp": 0,
                "localDraft": 0, "scheduledSend": 0,
                // Removal deletes everything of the account (F-04).
                "savedView": 0,
            ])
            XCTAssertEqual(try self.counts(db, account: "b@x.com"), [
                "account": 1, "thread": 1, "threadAI": 1, "pendingThreadOp": 1,
                "localDraft": 1, "scheduledSend": 1, "savedView": 1,
            ])
        }
    }

    /// `_` is a single-character wildcard in SQL LIKE. A prefix match on the
    /// thread id must not reach an account whose address differs only there.
    func testPurgeAccountTreatsUnderscoreInAddressLiterally() throws {
        let q = try makeDB()
        try q.write { db in
            try self.seed(db, account: "a_b@x.com")
            try self.seed(db, account: "aXb@x.com")
            try AccountLifecycle.purgeAccount(db, id: "a_b@x.com")
        }
        try q.read { db in
            XCTAssertEqual(try self.counts(db, account: "a_b@x.com")["threadAI"], 0)
            XCTAssertEqual(try self.counts(db, account: "aXb@x.com")["threadAI"], 1)
        }
    }

    func testPurgeAccountForUnknownAccountChangesNothing() throws {
        let q = try makeDB()
        try q.write { db in
            try self.seed(db, account: "b@x.com")
            try AccountLifecycle.purgeAccount(db, id: "gone@x.com")
        }
        try q.read { db in
            XCTAssertEqual(try self.counts(db, account: "b@x.com")["scheduledSend"], 1)
            XCTAssertEqual(try self.counts(db, account: "b@x.com")["account"], 1)
        }
    }

    func testClearAccountDefaultsRemovesOnlyThatAccountsKeys() throws {
        let suite = "AccountLifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // "a@x.com.au" starts with "a@x.com": its keys must survive.
        let ids = ["a@x.com", "b@x.com", "a@x.com.au"]
        for id in ids {
            defaults.set(30, forKey: "backfill.window.\(id)")
            defaults.set(true, forKey: "backfill.starred.\(id)")
            defaults.set(true, forKey: SyncEngine.attachmentRepairDefaultsKey(accountId: id))
            defaults.set(90, forKey: WindowBackfill.listedKey(accountId: id))
            defaults.set(30, forKey: "syncWindowDays.\(id)")
            defaults.set(Data("{}".utf8), forKey: "categoryFilter.label.\(id).Label_1")
            defaults.set("accepted", forKey: CalendarInvite.rsvpDefaultsKey(
                accountId: id, uid: "event@cal"))
        }

        AccountLifecycle.clearAccountDefaults(accountId: "a@x.com", defaults: defaults)

        let gone = [
            "backfill.window.a@x.com", "backfill.starred.a@x.com",
            "backfill.attachments.a@x.com", "backfill.windowListed.a@x.com",
            "syncWindowDays.a@x.com", "categoryFilter.label.a@x.com.Label_1",
            CalendarInvite.rsvpDefaultsKey(accountId: "a@x.com", uid: "event@cal"),
        ]
        for key in gone { XCTAssertNil(defaults.object(forKey: key), key) }
        for id in ["b@x.com", "a@x.com.au"] {
            XCTAssertEqual(defaults.integer(forKey: "backfill.window.\(id)"), 30, id)
            XCTAssertTrue(defaults.bool(forKey: "backfill.starred.\(id)"), id)
            XCTAssertTrue(defaults.bool(forKey: "backfill.attachments.\(id)"), id)
            XCTAssertEqual(defaults.integer(forKey: "backfill.windowListed.\(id)"), 90, id)
            XCTAssertEqual(defaults.integer(forKey: "syncWindowDays.\(id)"), 30, id)
            XCTAssertNotNil(defaults.data(forKey: "categoryFilter.label.\(id).Label_1"), id)
            XCTAssertEqual(defaults.string(forKey: CalendarInvite.rsvpDefaultsKey(
                accountId: id, uid: "event@cal")), "accepted", id)
        }
    }

    /// A quit after the purge and before the Keychain delete leaves the
    /// removal marked; the next launch finishes it. A marked account whose
    /// row still exists was never purged (killed before the transaction
    /// committed) and keeps its sign-in: only the mark goes.
    func testInterruptedRemovalIsFinishedOnlyWhenTheRowIsGone() throws {
        let suite = "AccountLifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        AccountLifecycle.markRemovalPending("a@x.com", defaults: defaults)
        AccountLifecycle.markRemovalPending("b@x.com", defaults: defaults)
        AccountLifecycle.markRemovalPending("a@x.com", defaults: defaults)
        XCTAssertEqual(AccountLifecycle.pendingRemovals(defaults: defaults),
                       ["a@x.com", "b@x.com"])

        let q = try makeDB()
        let plan = try q.write { db -> (finish: [String], stale: [String]) in
            // b@x.com's purge never committed; a@x.com's did.
            try Account(id: "b@x.com", displayName: "b", historyId: nil,
                        lastSyncAt: nil, senderName: "").insert(db)
            try Account(id: "a@x.com.au", displayName: "c", historyId: nil,
                        lastSyncAt: nil, senderName: "").insert(db)
            return try AccountLifecycle.removalsToFinish(
                db, pending: AccountLifecycle.pendingRemovals(defaults: defaults))
        }
        XCTAssertEqual(plan.finish, ["a@x.com"])
        XCTAssertEqual(plan.stale, ["b@x.com"],
                       "an account that still has its row is not finished off")

        AccountLifecycle.clearRemovalPending("a@x.com", defaults: defaults)
        AccountLifecycle.clearRemovalPending("b@x.com", defaults: defaults)
        XCTAssertNil(defaults.object(forKey: AccountLifecycle.pendingRemovalsKey))
    }

    // MARK: - Reauthorization

    func testBackgroundSyncSkipsAccountsThatNeedReauth() {
        let all = ["a@x.com", "b@x.com", "c@x.com"]
        XCTAssertEqual(
            AccountLifecycle.accountsToSync(
                all: all, needingReauth: ["b@x.com"], interactive: false),
            ["a@x.com", "c@x.com"])
        XCTAssertEqual(
            AccountLifecycle.accountsToSync(
                all: all, needingReauth: Set(all), interactive: false),
            [])
        XCTAssertEqual(
            AccountLifecycle.accountsToSync(all: all, needingReauth: [], interactive: false),
            all)
    }

    /// "Sync now" must still try: it is how the user learns the sign-in is
    /// still rejected.
    func testInteractiveSyncTriesEveryAccount() {
        let all = ["a@x.com", "b@x.com"]
        XCTAssertEqual(
            AccountLifecycle.accountsToSync(
                all: all, needingReauth: ["b@x.com"], interactive: true),
            all)
    }

    func testReauthBannerShowsOnceUnlessTheUserAsked() {
        XCTAssertTrue(AccountLifecycle.presentsReauthBanner(
            newlyFlagged: true, interactive: false))
        XCTAssertFalse(AccountLifecycle.presentsReauthBanner(
            newlyFlagged: false, interactive: false),
            "a dismissed banner must not return on the next background failure")
        XCTAssertTrue(AccountLifecycle.presentsReauthBanner(
            newlyFlagged: false, interactive: true))
        XCTAssertTrue(AccountLifecycle.presentsReauthBanner(
            newlyFlagged: true, interactive: true))
    }

    // MARK: - Scope after removal

    func testActiveAccountResetsOnlyWhenItWasRemoved() {
        XCTAssertNil(AccountLifecycle.activeAccountAfterRemoval(
            active: "a@x.com", removed: "a@x.com"))
        XCTAssertEqual(AccountLifecycle.activeAccountAfterRemoval(
            active: "b@x.com", removed: "a@x.com"), "b@x.com")
        XCTAssertNil(AccountLifecycle.activeAccountAfterRemoval(
            active: nil, removed: "a@x.com"))
    }

    func testViewScopedToRemovedAccountIsLeft() {
        XCTAssertTrue(AccountLifecycle.viewIsScopedToRemovedAccount(
            viewAccount: "a@x.com", removed: "a@x.com"))
        XCTAssertFalse(AccountLifecycle.viewIsScopedToRemovedAccount(
            viewAccount: "b@x.com", removed: "a@x.com"))
        XCTAssertFalse(AccountLifecycle.viewIsScopedToRemovedAccount(
            viewAccount: nil, removed: "a@x.com"),
            "a unified view stays selected")
    }

    func testBadgeScopeFallsBackToAllOnlyForTheRemovedAccount() {
        XCTAssertEqual(AccountLifecycle.badgeScopeRawAfterRemoval(
            raw: "account:a@x.com", removed: "a@x.com"), "all")
        XCTAssertEqual(AccountLifecycle.badgeScopeRawAfterRemoval(
            raw: "account:b@x.com", removed: "a@x.com"), "account:b@x.com")
        // Not a prefix match: a longer address that starts the same is
        // another account.
        XCTAssertEqual(AccountLifecycle.badgeScopeRawAfterRemoval(
            raw: "account:a@x.com.au", removed: "a@x.com"), "account:a@x.com.au")
        XCTAssertEqual(AccountLifecycle.badgeScopeRawAfterRemoval(
            raw: "focused", removed: "a@x.com"), "focused")
        XCTAssertEqual(AccountLifecycle.badgeScopeRawAfterRemoval(
            raw: "all", removed: "a@x.com"), "all")
        XCTAssertNil(AccountLifecycle.badgeScopeRawAfterRemoval(
            raw: nil, removed: "a@x.com"), "an unset preference stays unset")
    }
}
