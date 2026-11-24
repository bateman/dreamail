import XCTest
import GRDB

/// Dock badge: the label rule, the scope rule, and that the badge follows
/// every change of the inbox (local action, new mail, account removal).
///
/// The recount is `SidebarCounts.fetch(...).badge`, the query `MailStore`
/// publishes after every list reload. The optimistic step is
/// `DockBadge.delta`, which `MailStore` applies in the same frame as the
/// row; each action test checks that both agree.
final class DockBadgeTests: XCTestCase {

    private let a = "a@x.com"
    private let b = "b@x.com"

    // MARK: - Label

    func testZeroOrLessRemovesTheBadge() {
        XCTAssertEqual(DockBadge.label(for: 0), "")
        XCTAssertEqual(DockBadge.label(for: -2), "")
    }

    func testCountsUpToTheCapShowAsIs() {
        XCTAssertEqual(DockBadge.label(for: 1), "1")
        XCTAssertEqual(DockBadge.label(for: 42), "42")
        XCTAssertEqual(DockBadge.label(for: 999), "999")
    }

    func testCountsAboveTheCapShowNineNineNinePlus() {
        XCTAssertEqual(DockBadge.label(for: 1000), "999+")
        XCTAssertEqual(DockBadge.label(for: 123_456), "999+")
    }

    /// The notification-center badge takes a number: same cap, never
    /// negative. (`Notifier.setBadge` repaints "999+" after it.)
    func testSystemCountIsClampedToTheCap() {
        XCTAssertEqual(DockBadge.systemCount(for: -1), 0)
        XCTAssertEqual(DockBadge.systemCount(for: 0), 0)
        XCTAssertEqual(DockBadge.systemCount(for: 7), 7)
        XCTAssertEqual(DockBadge.systemCount(for: 5000), 999)
    }

    // MARK: - Scope

    func testScopeDefaultsToEveryAccount() {
        XCTAssertEqual(DockBadge.Scope.stored(nil), .all)
        XCTAssertEqual(DockBadge.Scope.stored(""), .all)
        XCTAssertEqual(DockBadge.Scope.stored("bogus"), .all)
    }

    func testScopeRawValuesRoundTrip() {
        for scope: DockBadge.Scope in [.all, .focused, .account(a)] {
            XCTAssertEqual(DockBadge.Scope.stored(scope.rawValue), scope)
        }
        XCTAssertEqual(DockBadge.Scope.account(a).rawValue, "account:a@x.com")
    }

    func testScopeAccount() {
        XCTAssertNil(DockBadge.account(for: .all, focused: a))
        XCTAssertNil(DockBadge.account(for: .focused, focused: nil),
                     "focused on the unified inbox counts every account")
        XCTAssertEqual(DockBadge.account(for: .focused, focused: a), a)
        XCTAssertEqual(DockBadge.account(for: .account(b), focused: a), b)
    }

    func testEachScopeCountsItsAccounts() throws {
        let q = try makeDB()
        try q.write { db in
            try self.insert(db, "a1", account: self.a)
            try self.insert(db, "a2", account: self.a)
            try self.insert(db, "b1", account: self.b)
        }
        XCTAssertEqual(try badge(q, scope: .all, focused: a), 3)
        XCTAssertEqual(try badge(q, scope: .focused, focused: nil), 3)
        XCTAssertEqual(try badge(q, scope: .focused, focused: a), 2)
        XCTAssertEqual(try badge(q, scope: .focused, focused: b), 1)
        XCTAssertEqual(try badge(q, scope: .account(b), focused: a), 1)
    }

    // MARK: - What counts

    /// Gmail's Inbox unread: one per conversation, primary tab only.
    func testOnlyUnreadPrimaryInboxConversationsCount() throws {
        let now = Date()
        let q = try makeDB()
        try q.write { db in
            try self.insert(db, "counted", account: self.a)
            try self.insert(db, "updates", account: self.a,
                            labels: "INBOX UNREAD CATEGORY_UPDATES")
            try self.insert(db, "read", account: self.a) { $0.isUnread = false }
            try self.insert(db, "archived", account: self.a) { $0.inInbox = false }
            try self.insert(db, "trash", account: self.a) { $0.inTrash = true }
            try self.insert(db, "spam", account: self.a) { $0.inSpam = true }
            try self.insert(db, "promo", account: self.a) { $0.inPromotions = true }
            try self.insert(db, "social", account: self.a) { $0.inSocial = true }
            try self.insert(db, "snoozed", account: self.a) {
                $0.snoozeUntil = now.addingTimeInterval(3600)
            }
        }
        XCTAssertEqual(try badge(q, now: now), 2)
        XCTAssertEqual(try badge(q, now: now, hide: ["CATEGORY_UPDATES"]), 1,
                       "Updates hidden from the inbox leave the badge too")
        // The in-memory rule says the same for each row.
        let rows = try q.read { try MailThread.fetchAll($0) }
        let counted = rows.filter {
            DockBadge.counts($0, badgeAccount: nil, now: now)
        }.map(\.gmailThreadId).sorted()
        XCTAssertEqual(counted, ["counted", "updates"])
    }

    // MARK: - Local actions

    func testReadArchiveTrashSpamSnoozeLowerTheBadgeAtOnce() throws {
        let now = Date()
        let actions: [(String, (inout MailThread) -> Void)] = [
            ("read", { $0.isUnread = false }),
            ("archive", { $0.inInbox = false }),
            ("trash", { $0.inTrash = true; $0.inInbox = false }),
            ("spam", { $0.inSpam = true; $0.inInbox = false }),
            ("snooze", { $0.snoozeUntil = now.addingTimeInterval(3600) }),
        ]
        for (name, action) in actions {
            try assertActionMovesBadge(name, by: -1, now: now, action)
        }
    }

    func testMarkUnreadAndMoveToInboxRaiseTheBadge() throws {
        let now = Date()
        try assertActionMovesBadge("mark unread", by: +1, now: now,
                                   start: { $0.isUnread = false },
                                   { $0.isUnread = true })
        try assertActionMovesBadge("move to inbox", by: +1, now: now,
                                   start: { $0.inInbox = false },
                                   { $0.inInbox = true })
    }

    func testStarringLeavesTheBadgeAlone() throws {
        try assertActionMovesBadge("star", by: 0, now: Date(),
                                   { $0.isStarred = true })
    }

    /// The badge scope is not the sidebar's: with "All accounts", reading
    /// mail of an account the sidebar does not show still lowers it, and a
    /// badge scoped to one account ignores the others.
    func testActionOnAnotherAccountFollowsTheBadgeScope() {
        let now = Date()
        let old = thread("b1", account: b)
        var new = old
        new.isUnread = false
        XCTAssertEqual(DockBadge.delta(from: old, to: new, badgeAccount: nil, now: now), -1)
        XCTAssertEqual(DockBadge.delta(from: old, to: new, badgeAccount: b, now: now), -1)
        XCTAssertEqual(DockBadge.delta(from: old, to: new, badgeAccount: a, now: now), 0)
    }

    // MARK: - New mail, account removal

    func testNewMailRaisesTheBadge() throws {
        let q = try makeDB()
        try q.write { db in try self.insert(db, "a1", account: self.a) }
        XCTAssertEqual(try badge(q), 1)
        try q.write { db in
            try self.insert(db, "a2", account: self.a)
            try self.insert(db, "b1", account: self.b)
        }
        XCTAssertEqual(try badge(q), 3)
        XCTAssertEqual(try badge(q, scope: .account(a), focused: nil), 2)
    }

    func testReadingTheLastUnreadEmptiesTheBadge() throws {
        let q = try makeDB()
        try q.write { db in try self.insert(db, "a1", account: self.a) }
        try q.write { db in
            let old = try XCTUnwrap(MailThread.fetchOne(db, key: "\(self.a):a1"))
            var new = old
            new.isUnread = false
            try OptimisticThreadWrite.updateChangedColumns(db, from: old, to: new)
        }
        let count = try badge(q)
        XCTAssertEqual(count, 0)
        XCTAssertEqual(DockBadge.label(for: count), "")
    }

    func testRemovingAnAccountDropsItsMailFromTheBadge() throws {
        let q = try makeDB()
        try q.write { db in
            try self.insert(db, "a1", account: self.a)
            try self.insert(db, "b1", account: self.b)
            try self.insert(db, "b2", account: self.b)
        }
        XCTAssertEqual(try badge(q), 3)
        try q.write { db in try AccountLifecycle.purgeAccount(db, id: self.b) }
        XCTAssertEqual(try badge(q), 1)

        // A badge scoped to the removed account falls back to every account
        // (`MailStore.leaveScope`), which still counts the remaining one.
        let raw = AccountLifecycle.badgeScopeRawAfterRemoval(
            raw: DockBadge.Scope.account(b).rawValue, removed: b)
        let scope = DockBadge.Scope.stored(raw)
        XCTAssertEqual(scope, .all)
        XCTAssertEqual(try badge(q, scope: scope, focused: nil), 1)
    }

    // MARK: - Helpers

    /// Applies `action` to one counted thread (after `start`) and checks
    /// that the optimistic delta and the database recount agree on `by`.
    private func assertActionMovesBadge(
        _ name: String, by expected: Int, now: Date,
        start: (inout MailThread) -> Void = { _ in },
        _ action: (inout MailThread) -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let q = try makeDB()
        try q.write { db in
            try self.insert(db, "other", account: self.a)
            try self.insert(db, "t", account: self.a, start)
        }
        let before = try badge(q, now: now)
        let old = try q.read { try XCTUnwrap(MailThread.fetchOne($0, key: "\(self.a):t")) }
        var new = old
        action(&new)
        let delta = DockBadge.delta(from: old, to: new, badgeAccount: nil, now: now)
        XCTAssertEqual(delta, expected, "\(name): optimistic delta", file: file, line: line)
        try q.write { db in
            try OptimisticThreadWrite.updateChangedColumns(db, from: old, to: new)
        }
        XCTAssertEqual(try badge(q, now: now), before + expected,
                       "\(name): recount", file: file, line: line)
    }

    private func badge(
        _ q: DatabaseQueue, scope: DockBadge.Scope = .all, focused: String? = nil,
        now: Date = Date(), hide: Set<String> = []
    ) throws -> Int {
        try q.read {
            try SidebarCounts.fetch(
                db: $0, activeAccount: focused,
                badgeAccount: DockBadge.account(for: scope, focused: focused),
                now: now, hideCategories: hide
            ).badge
        }
    }

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        return q
    }

    /// An unread primary-inbox thread, then `tweak`.
    private func thread(
        _ id: String, account: String, labels: String = "INBOX UNREAD",
        _ tweak: (inout MailThread) -> Void = { _ in }
    ) -> MailThread {
        var t = MailThread(
            id: "\(account):\(id)", accountId: account, gmailThreadId: id,
            subject: "s", snippet: "sn", fromDisplay: "F",
            lastDate: Date(), isUnread: true, isStarred: false,
            inInbox: true, inTrash: false,
            labelIds: labels, snoozeUntil: nil, participants: "F",
            messageCount: 1, hasAttachment: false, reminderAt: nil)
        tweak(&t)
        return t
    }

    private func insert(
        _ db: Database, _ id: String, account: String, labels: String = "INBOX UNREAD",
        _ tweak: (inout MailThread) -> Void = { _ in }
    ) throws {
        if try Account.fetchOne(db, key: account) == nil {
            try Account(id: account, displayName: account, historyId: nil,
                        lastSyncAt: nil, senderName: "").insert(db)
        }
        try thread(id, account: account, labels: labels, tweak).insert(db)
    }
}
