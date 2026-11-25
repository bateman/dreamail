import XCTest
import GRDB

/// Dock badge rules: the label, the scope, what counts, how the count
/// state accepts recounts and local deltas, and what Settings says about
/// macOS hiding it.
///
/// The recount is `SidebarCounts.fetch(...).badge`, the query `MailStore`
/// recounts with. The per-thread delta is `DockBadge.delta`, which
/// `MailStore` sums per action and feeds to `DockBadge.Counter`; the action
/// tests check that delta and recount agree. AppKit painting and the
/// `MailStore` wiring are not hosted here.
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

    func testReadArchiveTrashSpamSnoozeDeltaMatchesRecount() throws {
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

    func testMarkUnreadAndMoveToInboxDeltaMatchesRecount() throws {
        let now = Date()
        try assertActionMovesBadge("mark unread", by: +1, now: now,
                                   start: { $0.isUnread = false },
                                   { $0.isUnread = true })
        try assertActionMovesBadge("move to inbox", by: +1, now: now,
                                   start: { $0.inInbox = false },
                                   { $0.inInbox = true })
    }

    func testStarringDeltaIsZero() throws {
        try assertActionMovesBadge("star", by: 0, now: Date(),
                                   { $0.isStarred = true })
    }

    /// The badge scope is not the sidebar's: with "All accounts", reading
    /// mail of an account the sidebar does not show still lowers it, and a
    /// badge scoped to one account ignores the others.
    func testDeltaFollowsTheBadgeScopeNotTheSidebar() {
        let now = Date()
        let old = thread("b1", account: b)
        var new = old
        new.isUnread = false
        XCTAssertEqual(DockBadge.delta(from: old, to: new, badgeAccount: nil, now: now), -1)
        XCTAssertEqual(DockBadge.delta(from: old, to: new, badgeAccount: b, now: now), -1)
        XCTAssertEqual(DockBadge.delta(from: old, to: new, badgeAccount: a, now: now), 0)
    }

    // MARK: - Counter

    func testDeltaBeforeTheFirstRecountIsNotApplied() {
        var counter = DockBadge.Counter()
        XCTAssertFalse(counter.applyDelta(-1, account: nil))
        XCTAssertNil(counter.count, "nothing to paint before a recount")
    }

    func testRecountThenDeltaMovesTheCount() {
        var counter = DockBadge.Counter()
        XCTAssertTrue(counter.applyRecount(5, ticket: counter.ticket(account: nil)))
        XCTAssertTrue(counter.applyDelta(-1, account: nil))
        XCTAssertEqual(counter.count, 4)
        XCTAssertTrue(counter.applyDelta(+3, account: nil))
        XCTAssertEqual(counter.count, 7)
    }

    func testCountIsClampedAtZero() {
        var counter = DockBadge.Counter()
        counter.applyRecount(-4, ticket: counter.ticket(account: nil))
        XCTAssertEqual(counter.count, 0)
        counter.applyDelta(-2, account: nil)
        XCTAssertEqual(counter.count, 0)
    }

    /// A recount whose read started before a local action must not undo
    /// that action's delta (the badge would go N → N-1 → N → N-1).
    func testRecountStartedBeforeAnActionIsRejected() {
        var counter = DockBadge.Counter()
        counter.applyRecount(5, ticket: counter.ticket(account: nil))
        let stale = counter.ticket(account: nil)
        counter.applyDelta(-1, account: nil)
        XCTAssertFalse(counter.applyRecount(5, ticket: stale))
        XCTAssertEqual(counter.count, 4)
        // The action's own reconciliation starts afterwards and lands.
        XCTAssertTrue(counter.applyRecount(4, ticket: counter.ticket(account: nil)))
        XCTAssertEqual(counter.count, 4)
    }

    /// Any action invalidates older reads, even one that moves no badge.
    func testActionWithoutBadgeChangeStillRejectsOlderRecounts() {
        var counter = DockBadge.Counter()
        counter.applyRecount(5, ticket: counter.ticket(account: nil))
        let stale = counter.ticket(account: nil)
        XCTAssertFalse(counter.applyDelta(0, account: nil))
        XCTAssertFalse(counter.applyRecount(9, ticket: stale))
        XCTAssertEqual(counter.count, 5)
    }

    /// After a scope, focus or account change the count belongs to the old
    /// scope: a delta waits for the new recount instead of landing on it.
    func testDeltaForAnotherScopeIsNotApplied() {
        var counter = DockBadge.Counter()
        counter.applyRecount(5, ticket: counter.ticket(account: a))
        XCTAssertFalse(counter.applyDelta(-1, account: nil))
        XCTAssertFalse(counter.applyDelta(-1, account: b))
        XCTAssertEqual(counter.count, 5)
        XCTAssertTrue(counter.applyDelta(-1, account: a))
        XCTAssertEqual(counter.count, 4)
        counter.applyRecount(2, ticket: counter.ticket(account: nil))
        XCTAssertTrue(counter.applyDelta(-1, account: nil))
        XCTAssertEqual(counter.count, 1)
    }

    /// A bulk action applies its summed delta once.
    func testBulkActionSumsIntoOneDelta() throws {
        let now = Date()
        let rows = (0..<4).map { thread("t\($0)", account: a) }
        let read = rows.map { row -> MailThread in
            var copy = row
            copy.isUnread = false
            return copy
        }
        let total = zip(rows, read).reduce(0) {
            $0 + DockBadge.delta(from: $1.0, to: $1.1, badgeAccount: nil, now: now)
        }
        XCTAssertEqual(total, -4)
        var counter = DockBadge.Counter()
        counter.applyRecount(6, ticket: counter.ticket(account: nil))
        XCTAssertTrue(counter.applyDelta(total, account: nil))
        XCTAssertEqual(counter.count, 2)
        XCTAssertEqual(counter.epoch, 1, "one action, one epoch")
    }

    // MARK: - What macOS allows

    func testSystemStatus() {
        XCTAssertEqual(DockBadge.status(authorization: .denied, badgeEnabled: true,
                                        lastErrorCode: nil), .notificationsOff)
        XCTAssertEqual(DockBadge.status(authorization: .notDetermined, badgeEnabled: false,
                                        lastErrorCode: nil), .notAsked)
        XCTAssertEqual(DockBadge.status(authorization: .allowed, badgeEnabled: false,
                                        lastErrorCode: nil), .badgesOff)
        XCTAssertEqual(DockBadge.status(authorization: .allowed, badgeEnabled: true,
                                        lastErrorCode: 1), .failed(code: 1))
        XCTAssertEqual(DockBadge.status(authorization: .allowed, badgeEnabled: true,
                                        lastErrorCode: nil), .allowed)
    }

    func testOnlyBlockingStatesOfferSystemSettings() {
        let problems: [DockBadge.SystemStatus] = [.badgesOff, .notificationsOff, .failed(code: 3)]
        let fine: [DockBadge.SystemStatus] = [.unknown, .notAsked, .allowed]
        for status in problems {
            XCTAssertTrue(DockBadge.summary(status).problem, "\(status)")
        }
        for status in fine {
            XCTAssertFalse(DockBadge.summary(status).problem, "\(status)")
        }
        XCTAssertTrue(DockBadge.summary(.failed(code: 3)).text.contains("3"))
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

    // MARK: - Per-account counts (avatar badges)

    private func perAccount(_ q: DatabaseQueue, hide: Set<String> = []) throws -> [String: Int] {
        try q.read { try SidebarCounts.fetchUnreadByAccount(db: $0, hideCategories: hide) }
    }

    /// Several accounts: each gets its own number, and they add up to the
    /// Dock badge counting every account. Accounts with none are absent.
    func testPerAccountCountsAddUpToTheDockBadge() throws {
        let q = try makeDB()
        try q.write { db in
            try self.insert(db, "a1", account: self.a)
            try self.insert(db, "a2", account: self.a)
            try self.insert(db, "b1", account: self.b)
            try self.insert(db, "b2", account: self.b) { $0.isUnread = false }
            try self.insert(db, "c1", account: "c@x.com") { $0.inTrash = true }
        }
        let counts = try perAccount(q)
        XCTAssertEqual(counts, [a: 2, b: 1])
        XCTAssertEqual(counts.values.reduce(0, +), try badge(q))
    }

    /// Same exclusions as the Dock badge: promotions and hidden categories.
    func testPerAccountCountsUseTheDockBadgeRule() throws {
        let q = try makeDB()
        try q.write { db in
            try self.insert(db, "a1", account: self.a)
            try self.insert(db, "a2", account: self.a, labels: "INBOX UNREAD CATEGORY_UPDATES")
            try self.insert(db, "a3", account: self.a) { $0.inPromotions = true }
        }
        let hide: Set<String> = ["CATEGORY_UPDATES"]
        XCTAssertEqual(try perAccount(q, hide: hide), [a: 1])
        XCTAssertEqual(try perAccount(q, hide: hide)[a], try badge(q, hide: hide))
        XCTAssertEqual(try perAccount(q), [a: 2])
    }

    /// Mark read / unread moves only the thread's own account, and the
    /// optimistic result equals the recount.
    func testOptimisticDeltaOnMarkReadAndUnread() throws {
        let q = try makeDB()
        try q.write { db in
            try self.insert(db, "a1", account: self.a)
            try self.insert(db, "a2", account: self.a)
            try self.insert(db, "b1", account: self.b)
        }
        var state = DockBadge.AccountCounts()
        state.applyRecount(try perAccount(q), epoch: state.epoch)
        let old = try q.read { try XCTUnwrap(MailThread.fetchOne($0, key: "\(self.a):a1")) }
        var read = old
        read.isUnread = false

        let down = DockBadge.delta(from: old, to: read, badgeAccount: old.accountId)
        state.applyDelta([old.accountId: down])
        XCTAssertEqual(state.unread(for: a), 1)
        XCTAssertEqual(state.unread(for: b), 1, "other accounts do not move")
        try q.write { db in try OptimisticThreadWrite.updateChangedColumns(db, from: old, to: read) }
        XCTAssertEqual(state.counts, try perAccount(q))

        let up = DockBadge.delta(from: read, to: old, badgeAccount: old.accountId)
        state.applyDelta([old.accountId: up])
        XCTAssertEqual(state.unread(for: a), 2)
        try q.write { db in try OptimisticThreadWrite.updateChangedColumns(db, from: read, to: old) }
        XCTAssertEqual(state.counts, try perAccount(q))
    }

    func testAccountCountsClampAndDropAtZero() {
        var state = DockBadge.AccountCounts()
        state.applyRecount([a: 1], epoch: state.epoch)
        state.applyDelta([a: -3])
        XCTAssertEqual(state.unread(for: a), 0)
        XCTAssertNil(state.counts[a], "no entry, so no badge")
    }

    /// A recount that started before a local action must not undo it.
    func testAccountRecountStartedBeforeAnActionIsRejected() {
        var state = DockBadge.AccountCounts()
        state.applyRecount([a: 3], epoch: state.epoch)
        let stale = state.epoch
        state.applyDelta([a: -1])
        XCTAssertFalse(state.applyRecount([a: 3], epoch: stale))
        XCTAssertEqual(state.unread(for: a), 2)
    }

    /// Removing an account drops its mail from the recount, and so its entry.
    func testRemovingAnAccountDropsItsUnreadCount() throws {
        let q = try makeDB()
        try q.write { db in
            try self.insert(db, "a1", account: self.a)
            try self.insert(db, "b1", account: self.b)
        }
        var state = DockBadge.AccountCounts()
        state.applyRecount(try perAccount(q), epoch: state.epoch)
        XCTAssertEqual(state.unread(for: b), 1)
        try q.write { db in try AccountLifecycle.purgeAccount(db, id: self.b) }
        state.applyRecount(try perAccount(q), epoch: state.epoch)
        XCTAssertEqual(state.counts, [a: 1])
        XCTAssertEqual(state.unread(for: b), 0)
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
