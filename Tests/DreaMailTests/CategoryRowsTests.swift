import XCTest
import GRDB

/// "Show Promotions and Social", a per-account setting (`CategoryRows`): the
/// rule for what is offered where, the fallback to the Inbox, the stored
/// category filter, the unified scope, and the guarantee that no mail is
/// hidden or counted differently. Real derivation and real queries; the
/// AppKit rows and the `MailStore` wiring are covered by `CategoryRowsUITests`.
final class CategoryRowsTests: XCTestCase {
    private let a = "a@example.com"
    private let b = "b@example.com"
    private var suiteName = ""
    private var store: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "CategoryRowsTests.\(UUID().uuidString)"
        store = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suiteName)
        store = nil
    }

    // MARK: - Setting and persistence

    func testOnByDefaultForEveryAccount() {
        XCTAssertTrue(CategoryRows.isOn(accountId: a, store))
        XCTAssertEqual(CategoryRows.off(accounts: [a, b], store), [])
    }

    func testOffIsPerAccountAndSurvivesARelaunch() throws {
        CategoryRows.setOn(false, accountId: a, store)
        XCTAssertFalse(CategoryRows.isOn(accountId: a, store))
        XCTAssertTrue(CategoryRows.isOn(accountId: b, store), "the other account keeps it on")
        // A relaunch reads the same stored domain.
        let relaunched = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        XCTAssertEqual(CategoryRows.off(accounts: [a, b], relaunched), [a])
        CategoryRows.setOn(true, accountId: a, store)
        XCTAssertNil(store.object(forKey: CategoryRows.defaultsKey(accountId: a)),
                     "on is the default: nothing stored")
    }

    func testAccountRemovalClearsTheSetting() {
        let keys = AccountLifecycle.accountDefaultsKeys(accountId: a, in: store)
        XCTAssertTrue(keys.contains(CategoryRows.defaultsKey(accountId: a)))
    }

    // MARK: - Where the views exist

    func testAnAccountShowsThemWhenItsSettingIsOn() {
        XCTAssertTrue(CategoryRows.shown(accounts: [a, b], scope: a, off: [b]))
        XCTAssertFalse(CategoryRows.shown(accounts: [a, b], scope: b, off: [b]))
    }

    func testAllAccountsShowThemWhenAnyAccountDoes() {
        XCTAssertTrue(CategoryRows.shown(accounts: [a, b], scope: nil, off: [b]))
        XCTAssertFalse(CategoryRows.shown(accounts: [a, b], scope: nil, off: [a, b]))
        XCTAssertTrue(CategoryRows.shown(accounts: [], scope: nil, off: []))
    }

    func testAClosedViewFallsBackToTheInbox() {
        XCTAssertEqual(CategoryRows.view(.promotions, shown: false), .inbox)
        XCTAssertEqual(CategoryRows.view(.social, shown: false), .inbox)
        XCTAssertEqual(CategoryRows.view(.promotions, shown: true), .promotions)
        XCTAssertEqual(CategoryRows.view(.starred, shown: false), .starred)
    }

    func testPaletteOffersThemOnlyWhileShown() {
        func titles(_ shown: Bool) -> Set<String> {
            Set(PaletteCommands.entries(.init(categoryViews: shown)).map(\.title))
        }
        XCTAssertTrue(titles(true).isSuperset(of: ["Go to Promotions", "Go to Social"]))
        XCTAssertTrue(titles(false).isDisjoint(with: ["Go to Promotions", "Go to Social"]))
        XCTAssertTrue(titles(false).contains("Go to Inbox"))
    }

    /// The reordering of the system views keeps its saved slot while the two
    /// rows are closed: listing skips them, the stored order is untouched.
    func testTheSavedOrderIsKeptWhileTheRowsAreClosed() {
        let stored = ["promotions", "inbox", "starred", "snoozed", "important", "sent",
                      "drafts", "allMail", "trash", "outbox", "more", "scheduled",
                      "reminders", "social", "spam"]
        let all = { (_: String) in true }
        let closed = { (id: String) in id != "promotions" && id != "social" }
        let open = SidebarSystemOrder.listed(stored: stored, hasReminders: false,
                                             moreOpen: true, exists: all)
        let hidden = SidebarSystemOrder.listed(stored: stored, hasReminders: false,
                                               moreOpen: true, exists: closed)
        XCTAssertEqual(open.first, "promotions")
        XCTAssertEqual(hidden, open.filter { $0 != "promotions" && $0 != "social" })
        XCTAssertEqual(SidebarSystemOrder.resolve(stored, hasReminders: false), stored,
                       "the order itself is not rewritten")
    }

    // MARK: - Stored category filter

    func testAStoredPickForTheTwoHasNoEffectWhileClosed() {
        let filter = CategoryFilter(exclude: true,
                                    show: ["CATEGORY_SOCIAL"],
                                    hide: ["CATEGORY_PROMOTIONS", "CATEGORY_UPDATES"])
        let closed = CategoryRows.scoped(filter, shown: false)
        XCTAssertEqual(closed.hide, ["CATEGORY_UPDATES"], "Updates is out of scope")
        XCTAssertEqual(closed.show, [])
        XCTAssertEqual(CategoryRows.scoped(filter, shown: true), filter)
    }

    func testTheStoredPickComesBackWhenTheSettingDoes() {
        let stored = CategoryFilter(exclude: true, show: [], hide: ["CATEGORY_SOCIAL"])
        // While closed the user hides Forums: the Social pick is kept beside it.
        let edited = CategoryFilter(exclude: true, show: [], hide: ["CATEGORY_FORUMS"])
        let saved = CategoryRows.restoring(edited, from: stored, shown: false)
        XCTAssertEqual(saved.hide, ["CATEGORY_FORUMS", "CATEGORY_SOCIAL"])
        XCTAssertEqual(CategoryRows.restoring(edited, from: stored, shown: true), edited)
    }

    // MARK: - Mail is never hidden or counted differently

    /// a: Primary, Promotions, Social (all unread, in the Inbox); b: the same.
    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        let kinds: [(String, String)] = [("primary", "INBOX UNREAD"),
                                         ("promo", "INBOX UNREAD CATEGORY_PROMOTIONS"),
                                         ("social", "INBOX UNREAD CATEGORY_SOCIAL")]
        try q.write { db in
            for account in [self.a, self.b] {
                try Account(id: account, displayName: "User", historyId: nil,
                            lastSyncAt: nil, senderName: "").insert(db)
                for (n, kind) in kinds.enumerated() {
                    try Message(id: "\(account):m-\(kind.0)", accountId: account,
                                gmailId: "m-\(kind.0)", threadId: "\(account):\(kind.0)",
                                fromHeader: "Sender <s@example.com>",
                                toHeader: account, ccHeader: "", bccHeader: "",
                                subject: kind.0,
                                date: Date(timeIntervalSince1970: 5_000 + Double(n)),
                                snippet: "", bodyText: "", bodyHTML: nil,
                                messageIdHeader: "", referencesHeader: "",
                                labelIds: kind.1, isUnread: true,
                                hasAttachment: false).insert(db)
                }
                try SyncEngine.deriveThreads(
                    db, for: Set(kinds.map { "\(account):\($0.0)" }), accountId: account)
            }
        }
        return q
    }

    private func ids(_ q: DatabaseQueue, _ request: QueryInterfaceRequest<MailThread>)
        throws -> Set<String> {
        try q.read { Set(try request.fetchAll($0).map(\.id)) }
    }

    func testInboxListAndUnreadCountsDoNotDependOnTheSetting() throws {
        let q = try makeDB()
        func snapshot(off: Set<String>) throws -> (Set<String>, Int, [String: Int], Int) {
            let hide = CategoryRows.scoped(FilterChips.initial(for: .inbox, store: store).category,
                                           shown: false).hide
            let list = try ids(q, CategoryHide.apply(ThreadListQuery.inbox(), hide: hide))
            let (counts, badge) = try q.read {
                try SidebarCounts.fetch(db: $0, activeAccount: nil, badgeAccount: nil,
                                        hideCategories: hide, categoryRowsOff: off)
            }
            let perAccount = try q.read {
                try SidebarCounts.fetchUnreadByAccount(db: $0, hideCategories: hide)
            }
            return (list, counts["inbox"] ?? -1, perAccount, badge)
        }
        let on = try snapshot(off: [])
        let off = try snapshot(off: [a])
        XCTAssertEqual(on.0.count, 6, "every Inbox conversation, any category")
        XCTAssertEqual(on.0, off.0)
        XCTAssertEqual(on.1, off.1)
        XCTAssertEqual(on.2, off.2)
        XCTAssertEqual(on.3, off.3)
        XCTAssertEqual(off.1, 6)
    }

    func testAllMailAndSearchDoNotDependOnTheSetting() throws {
        let q = try makeDB()
        // The two queries do not read the setting at all.
        XCTAssertEqual(try ids(q, MailThread.all().filter(Column("inTrash") == false)).count, 6)
        let restricted = CategoryRows.restrict(MailThread.all(), view: .allMail,
                                               activeAccount: nil, off: [a])
        XCTAssertEqual(try ids(q, restricted).count, 6, "only the two views are restricted")
    }

    func testTheAllAccountsListsHoldTheAccountsThatShowThem() throws {
        let q = try makeDB()
        let off: Set<String> = [a]
        let promotions = try ids(q, CategoryRows.restrict(
            ThreadListQuery.promotions(), view: .promotions, activeAccount: nil, off: off))
        let social = try ids(q, CategoryRows.restrict(
            ThreadListQuery.social(), view: .social, activeAccount: nil, off: off))
        XCTAssertEqual(promotions, ["\(b):promo"])
        XCTAssertEqual(social, ["\(b):social"])
        // One account's own view is the account's; with it on, nothing changes.
        let own = try ids(q, CategoryRows.restrict(
            ThreadListQuery.promotions(), view: .promotions, activeAccount: b, off: off)
            .filter(Column("accountId") == b))
        XCTAssertEqual(own, ["\(b):promo"])
        let all = try ids(q, CategoryRows.restrict(
            ThreadListQuery.promotions(), view: .promotions, activeAccount: nil, off: []))
        XCTAssertEqual(all, ["\(a):promo", "\(b):promo"])
    }

    func testTheAllAccountsRowCountsTheAccountsThatShowThem() throws {
        let q = try makeDB()
        func counts(_ account: String?, off: Set<String>) throws -> [String: Int] {
            try q.read {
                try SidebarCounts.fetch(db: $0, activeAccount: account, badgeAccount: nil,
                                        categoryRowsOff: off).counts
            }
        }
        let on = try counts(nil, off: [])
        let mixed = try counts(nil, off: [a])
        XCTAssertEqual([on["promotions"], on["social"]], [2, 2])
        XCTAssertEqual([mixed["promotions"], mixed["social"]], [1, 1])
        XCTAssertEqual(mixed["inbox"], on["inbox"], "the Inbox count is the same")
        let own = try counts(a, off: [a])
        XCTAssertEqual([own["promotions"], own["social"]], [1, 1],
                       "an account's own numbers do not change")
    }
}
