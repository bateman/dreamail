import XCTest
import GRDB

/// The Inbox lists every conversation with a live INBOX message, whatever
/// its Gmail category, like Gmail without category tabs. The same set is
/// counted by the Inbox unread, the Dock badge and the avatar badges, and
/// notifies. Measured through the real derivation (`SyncEngine.deriveThreads`)
/// and the real queries, on a fresh install and after the one-time reset of
/// the old "hide Promotions and Social" default.
final class InboxCategoryDefaultTests: XCTestCase {
    private let account = "user@example.com"
    private let categories = ["CATEGORY_SOCIAL", "CATEGORY_PROMOTIONS",
                              "CATEGORY_UPDATES", "CATEGORY_FORUMS"]
    private var suiteName = ""
    private var store: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "InboxCategoryDefaultTests.\(UUID().uuidString)"
        store = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suiteName)
        store = nil
    }

    // MARK: - Fixture

    private struct Fixture {
        var all: Set<String> = []
        var unread: Set<String> = []
    }

    /// One conversation per category × unread/read × starred/not, plus a
    /// Primary one, an archived Social one and a trashed Social one.
    private func makeDB() throws -> (DatabaseQueue, Fixture) {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        var fixture = Fixture()
        var threads: [(id: String, labels: String)] = [("primary", "INBOX UNREAD")]
        fixture.all.insert("primary")
        fixture.unread.insert("primary")
        for cat in categories {
            for unread in [true, false] {
                for starred in [true, false] {
                    let id = "\(cat)-\(unread ? "unread" : "read")-\(starred ? "starred" : "plain")"
                    var labels = ["INBOX", cat]
                    if unread { labels.append("UNREAD") }
                    if starred { labels.append("STARRED") }
                    threads.append((id, labels.joined(separator: " ")))
                    fixture.all.insert(id)
                    if unread { fixture.unread.insert(id) }
                }
            }
        }
        threads.append(("archived", "CATEGORY_SOCIAL UNREAD"))
        threads.append(("trashed", "TRASH CATEGORY_SOCIAL UNREAD"))
        try q.write { db in
            try Account(id: self.account, displayName: "User", historyId: nil,
                        lastSyncAt: nil, senderName: "").insert(db)
            for (n, t) in threads.enumerated() {
                try Message(id: "\(self.account):m-\(t.id)", accountId: self.account,
                            gmailId: "m-\(t.id)", threadId: "\(self.account):\(t.id)",
                            fromHeader: "Notifier <notify@example.com>",
                            toHeader: self.account, ccHeader: "", bccHeader: "",
                            subject: t.id, date: Date(timeIntervalSince1970: 5_000 + Double(n)),
                            snippet: "", bodyText: "", bodyHTML: nil,
                            messageIdHeader: "", referencesHeader: "",
                            labelIds: t.labels, isUnread: t.labels.contains("UNREAD"),
                            hasAttachment: false).insert(db)
            }
            try SyncEngine.deriveThreads(
                db, for: Set(threads.map { "\(self.account):\($0.id)" }),
                accountId: self.account)
        }
        return (q, fixture)
    }

    private func key(_ id: String) -> String { "\(account):\(id)" }

    private func inboxHide() -> Set<String> {
        FilterChips.initial(for: .inbox, store: store).category.hide
    }

    /// The Inbox list as `MailStore.baseQuery` + `applyChips` build it.
    private func inboxIds(_ q: DatabaseQueue, hide: Set<String>) throws -> Set<String> {
        try q.read { db in
            let rows = try CategoryHide.apply(ThreadListQuery.inbox(), hide: hide).fetchAll(db)
            return Set(rows.map(\.id))
        }
    }

    // MARK: - Assertions shared by both installs

    private func assertEverythingListedAndCounted(
        _ q: DatabaseQueue, _ fixture: Fixture, hide: Set<String>,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertEqual(hide, [], "nothing hidden from the Inbox", file: file, line: line)
        let listed = try inboxIds(q, hide: hide)
        XCTAssertEqual(listed, Set(fixture.all.map(key)),
                       "every INBOX conversation is listed, any category, read or unread, "
                       + "starred or not; archived and trashed are not",
                       file: file, line: line)

        let (counts, badge) = try q.read {
            try SidebarCounts.fetch(db: $0, activeAccount: nil, badgeAccount: nil,
                                    hideCategories: hide)
        }
        let unreadListed = try q.read { db in
            try CategoryHide.apply(ThreadListQuery.inbox(), hide: hide)
                .filter(Column("isUnread") == true).fetchCount(db)
        }
        XCTAssertEqual(unreadListed, fixture.unread.count, file: file, line: line)
        XCTAssertEqual(counts["inbox"], fixture.unread.count,
                       "Inbox unread counts what the Inbox lists", file: file, line: line)
        XCTAssertEqual(badge, fixture.unread.count, "Dock badge", file: file, line: line)
        let perAccount = try q.read {
            try SidebarCounts.fetchUnreadByAccount(db: $0, hideCategories: hide)
        }
        XCTAssertEqual(perAccount, [account: fixture.unread.count], "avatar badge",
                       file: file, line: line)

        // Optimistic rules say the same for every row.
        let rows = try q.read { try MailThread.fetchAll($0) }
        let counted = Set(rows.filter {
            DockBadge.counts($0, badgeAccount: nil, hideCategories: hide)
        }.map(\.id))
        XCTAssertEqual(counted, Set(fixture.unread.map(key)), file: file, line: line)

        // Notifications: every unread listed conversation is eligible.
        let candidates = try q.read {
            try NewMailNotifications.unreadInboxCandidates($0, now: Date())
        }
        var state = NewMailNotifications()
        state.seed([])
        let fresh = state.fresh(current: candidates, now: Date(), demoMode: false,
                                hide: hide, isBlocked: { _ in false })
        XCTAssertEqual(Set(fresh), Set(fixture.unread.map(key)),
                       "category mail the Inbox lists notifies", file: file, line: line)
    }

    // MARK: - Fresh install

    func testFreshInstallListsAndCountsEveryCategory() throws {
        let (q, fixture) = try makeDB()
        try assertEverythingListedAndCounted(q, fixture, hide: inboxHide())
    }

    func testSocialUnreadNotStarredIsInInbox() throws {
        let (q, _) = try makeDB()
        let thread = try q.read {
            try XCTUnwrap(MailThread.fetchOne($0, key: self.key("CATEGORY_SOCIAL-unread-plain")))
        }
        XCTAssertTrue(thread.inInbox)
        XCTAssertTrue(thread.inSocial)
        XCTAssertTrue(try inboxIds(q, hide: inboxHide()).contains(thread.id))
    }

    // MARK: - Install that stored the previous default

    private func storeInboxPick(_ category: CategoryFilter) throws {
        store.set(try JSONEncoder().encode(category), forKey: "categoryFilter.inbox")
    }

    private var storedInboxPick: CategoryFilter? {
        store.data(forKey: "categoryFilter.inbox")
            .flatMap { try? JSONDecoder().decode(CategoryFilter.self, from: $0) }
    }

    func testStoredPreviousDefaultIsResetAndEverythingShows() throws {
        try storeInboxPick(CategoryFilter(
            exclude: true, hide: ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL"]))
        let (q, fixture) = try makeDB()
        try assertEverythingListedAndCounted(q, fixture, hide: inboxHide())
        XCTAssertNil(storedInboxPick, "the old default is dropped, not kept as a pick")
        XCTAssertTrue(store.bool(forKey: FilterChips.inboxCategoryResetKey))
    }

    /// A pick of Updates on top of the old default keeps Updates (never a
    /// default, so the user's own) and shows Promotions and Social.
    func testResetKeepsUpdatesOrForumsTheUserAdded() throws {
        try storeInboxPick(CategoryFilter(
            exclude: true,
            hide: ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL", "CATEGORY_UPDATES"]))
        XCTAssertEqual(inboxHide(), ["CATEGORY_UPDATES"])
        let (q, _) = try makeDB()
        let listed = try inboxIds(q, hide: inboxHide())
        XCTAssertTrue(listed.contains(key("CATEGORY_SOCIAL-unread-plain")))
        XCTAssertTrue(listed.contains(key("CATEGORY_PROMOTIONS-unread-plain")))
        XCTAssertFalse(listed.contains(key("CATEGORY_UPDATES-unread-plain")))
        XCTAssertTrue(listed.contains(key("CATEGORY_UPDATES-unread-starred")), "star pins through")
    }

    /// The reset runs once: a hide the user turns on afterwards stays a
    /// working filter, and a "contains" pick is never touched.
    func testResetRunsOnceAndLaterPicksWork() throws {
        XCTAssertEqual(inboxHide(), [])
        try storeInboxPick(CategoryFilter(exclude: true, hide: ["CATEGORY_SOCIAL"]))
        XCTAssertEqual(inboxHide(), ["CATEGORY_SOCIAL"])

        let (q, _) = try makeDB()
        let hide = inboxHide()
        XCTAssertFalse(try inboxIds(q, hide: hide).contains(key("CATEGORY_SOCIAL-unread-plain")))
        let (counts, badge) = try q.read {
            try SidebarCounts.fetch(db: $0, activeAccount: nil, badgeAccount: nil,
                                    hideCategories: hide)
        }
        let unreadListed = try q.read { db in
            try CategoryHide.apply(ThreadListQuery.inbox(), hide: hide)
                .filter(Column("isUnread") == true).fetchCount(db)
        }
        XCTAssertEqual(counts["inbox"], unreadListed, "a user hide moves list and count together")
        XCTAssertEqual(badge, unreadListed)
        XCTAssertEqual(counts["social"], 2, "the Social row still counts its unread")
    }

    func testResetLeavesAContainsPickAlone() throws {
        let pick = CategoryFilter(exclude: false, show: ["CATEGORY_SOCIAL"])
        try storeInboxPick(pick)
        XCTAssertEqual(FilterChips.initial(for: .inbox, store: store).category, pick)
    }

    func testEveryViewDefaultHidesNothing() {
        for view: MailboxView in [.inbox, .account(account), .allMail, .social, .promotions] {
            XCTAssertFalse(FilterChips.defaults(for: view).category.isActive, "\(view)")
        }
    }

    /// The Inbox unread predicate stays on an index with no hide and with
    /// every category hidden.
    func testInboxUnreadPredicateIsIndexed() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        for hide: Set<String> in [[], Set(categories)] {
            let predicate = SidebarCounts.primaryUnreadSQL(
                hideSQL: SidebarCounts.inboxHideSQL(hide: hide))
            let detail = try q.read { db in
                try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT COUNT(*) FROM thread WHERE \(predicate)",
                                 arguments: [Date()])
                    .map { $0["detail"] as String? ?? "" }.joined(separator: " | ")
            }
            XCTAssertTrue(detail.contains("USING INDEX") || detail.contains("USING COVERING INDEX"),
                          "hide \(hide): \(detail)")
        }
    }
}
