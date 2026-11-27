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

    /// What the app derives from one stored Inbox pick and the accounts that
    /// have the setting off: the list, the counts, the badges and the
    /// notification decision, each through the code the app runs.
    private struct Outcome: Equatable {
        var list: Set<String>
        var inboxCount: Int
        var perAccount: [String: Int]
        var dockBadge: Int
        var notified: Set<String>
        var optimistic: Set<String>
    }

    private func outcome(_ q: DatabaseQueue, hide: Set<String>, off: Set<String>) throws -> Outcome {
        let list = try ids(q, CategoryHide.apply(ThreadListQuery.inbox(), hide: hide,
                                                 exemptAccounts: off))
        let (counts, badge) = try q.read {
            try SidebarCounts.fetch(db: $0, activeAccount: nil, badgeAccount: nil,
                                    hideCategories: hide, categoryRowsOff: off)
        }
        let perAccount = try q.read {
            try SidebarCounts.fetchUnreadByAccount(db: $0, hideCategories: hide,
                                                   categoryRowsOff: off)
        }
        let candidates = try q.read {
            try NewMailNotifications.unreadInboxCandidates($0, now: Date())
        }
        var state = NewMailNotifications()
        state.seed([])
        let notified = Set(state.fresh(current: candidates, now: Date(), demoMode: false,
                                       hide: hide, categoryRowsOff: off,
                                       isBlocked: { _ in false }))
        let rows = try q.read { try MailThread.fetchAll($0) }
        let optimistic = Set(rows.filter {
            DockBadge.counts($0, badgeAccount: nil, hideCategories: hide, categoryRowsOff: off)
        }.map(\.id))
        return Outcome(list: list, inboxCount: counts["inbox"] ?? -1, perAccount: perAccount,
                       dockBadge: badge, notified: notified, optimistic: optimistic)
    }

    /// No stored pick: the setting changes nothing anywhere.
    func testNothingChangesWithoutAStoredPick() throws {
        let q = try makeDB()
        let on = try outcome(q, hide: [], off: [])
        XCTAssertEqual(on.list.count, 6)
        XCTAssertEqual(on.inboxCount, 6)
        for off in [[a], [b], [a, b]] as [Set<String>] {
            XCTAssertEqual(try outcome(q, hide: [], off: off), on)
        }
    }

    /// A stored "hide Promotions" pick applies to the accounts that have the
    /// setting on and to none that has it off, in the list, the Inbox count,
    /// each account's badge, the Dock badge and the notification decision;
    /// an account with it off is exactly as if nothing were hidden.
    func testAStoredPickAppliesPerAccountEverywhere() throws {
        let q = try makeDB()
        let hide: Set<String> = ["CATEGORY_PROMOTIONS"]
        let nothingHidden = try outcome(q, hide: [], off: [])

        let allOn = try outcome(q, hide: hide, off: [])
        XCTAssertEqual(allOn.list, ["\(a):primary", "\(a):social", "\(b):primary", "\(b):social"])
        XCTAssertEqual(allOn.inboxCount, 4)
        XCTAssertEqual(allOn.perAccount, [a: 2, b: 2])
        XCTAssertEqual(allOn.dockBadge, 4)
        XCTAssertEqual(allOn.notified, allOn.list)
        XCTAssertEqual(allOn.optimistic, allOn.list)

        // A on, B off: B's promotion is listed, counted, badged and notified;
        // A's is not, whichever account is on screen.
        let mixed = try outcome(q, hide: hide, off: [b])
        XCTAssertEqual(mixed.list, allOn.list.union(["\(b):promo"]))
        XCTAssertEqual(mixed.inboxCount, 5)
        XCTAssertEqual(mixed.perAccount, [a: 2, b: 3])
        XCTAssertEqual(mixed.dockBadge, 5)
        XCTAssertEqual(mixed.notified, mixed.list)
        XCTAssertEqual(mixed.optimistic, mixed.list)

        // Both off: as if no pick were stored.
        XCTAssertEqual(try outcome(q, hide: hide, off: [a, b]), nothingHidden)
    }

    /// The same stored pick for "show Promotions only" does not narrow an
    /// account that has the setting off.
    func testAStoredShowPickDoesNotNarrowAClosedAccount() throws {
        let q = try makeDB()
        let list = try ids(q, CategoryHide.applyShow(
            ThreadListQuery.inbox(), show: ["CATEGORY_PROMOTIONS"], exemptAccounts: [b]))
        XCTAssertEqual(list, ["\(a):promo", "\(b):primary", "\(b):promo", "\(b):social"])
    }

    /// The instant count after an action: mail of an account with the
    /// setting off never counts under Promotions or Social.
    func testTheOptimisticCountsSkipAClosedAccount() throws {
        let q = try makeDB()
        let rows = try q.read { try MailThread.fetchAll($0) }
        let promoB = try XCTUnwrap(rows.first { $0.id == "\(b):promo" })
        let promoA = try XCTUnwrap(rows.first { $0.id == "\(a):promo" })
        XCTAssertTrue(SidebarCounts.memberships(of: promoB, categoryRowsOff: [])
            .isSuperset(of: ["promotions", "inbox"]))
        let closed = SidebarCounts.memberships(of: promoB, categoryRowsOff: [b])
        XCTAssertTrue(closed.contains("inbox"), "still in the Inbox count")
        XCTAssertFalse(closed.contains("promotions"))
        XCTAssertTrue(SidebarCounts.memberships(of: promoA, categoryRowsOff: [b])
            .contains("promotions"), "another account's mail still counts")
        // Marking B's promotion read: the Promotions row does not move.
        var read = promoB
        read.isUnread = false
        let before = SidebarCounts.memberships(of: promoB, categoryRowsOff: [b])
        let after = SidebarCounts.memberships(of: read, categoryRowsOff: [b])
        XCTAssertEqual(before.subtracting(after), ["inbox"])
    }

    // MARK: - Views left, chips offered

    func testTogglingOffWhileSocialIsOnScreenLeavesForTheInbox() {
        // One account, the setting turned off.
        XCTAssertEqual(CategoryRows.view(
            .social, shown: CategoryRows.shown(accounts: [a], scope: a, off: [a])), .inbox)
        // All accounts, the last account that had it on turns it off.
        XCTAssertEqual(CategoryRows.view(
            .social, shown: CategoryRows.shown(accounts: [a, b], scope: nil, off: [a, b])), .inbox)
        // All accounts, another still has it on: the view stays.
        XCTAssertEqual(CategoryRows.view(
            .social, shown: CategoryRows.shown(accounts: [a, b], scope: nil, off: [a])), .social)
    }

    func testSwitchingToAnAccountThatHasItOffLeavesForTheInbox() {
        let off: Set<String> = [b]
        XCTAssertEqual(CategoryRows.view(
            .social, shown: CategoryRows.shown(accounts: [a, b], scope: a, off: off)), .social)
        XCTAssertEqual(CategoryRows.view(
            .social, shown: CategoryRows.shown(accounts: [a, b], scope: b, off: off)), .inbox)
    }

    func testRemovingTheLastAccountThatShowsThemClosesTheViewInAllAccounts() {
        let off: Set<String> = [b]
        XCTAssertTrue(CategoryRows.shown(accounts: [a, b], scope: nil, off: off))
        // A is removed: only B is left, and B has it off.
        XCTAssertFalse(CategoryRows.shown(accounts: [b], scope: nil, off: off))
        XCTAssertEqual(CategoryRows.view(.promotions, shown: false), .inbox)
    }

    func testTheConversationChipFollowsItsOwnAccount() {
        XCTAssertFalse(CategoryRows.showsChip(label: "CATEGORY_SOCIAL", accountOn: false))
        XCTAssertFalse(CategoryRows.showsChip(label: "CATEGORY_PROMOTIONS", accountOn: false))
        XCTAssertTrue(CategoryRows.showsChip(label: "CATEGORY_SOCIAL", accountOn: true))
        XCTAssertTrue(CategoryRows.showsChip(label: "CATEGORY_UPDATES", accountOn: false),
                      "Updates and Forums are out of scope")
        XCTAssertTrue(CategoryRows.showsChip(label: "CATEGORY_FORUMS", accountOn: false))
    }

    func testTheFilterOffersTheTwoOnlyWhileShown() {
        let all = ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL", "CATEGORY_UPDATES", "CATEGORY_FORUMS"]
        XCTAssertEqual(CategoryRows.offered(all, shown: true), all)
        XCTAssertEqual(CategoryRows.offered(all, shown: false),
                       ["CATEGORY_UPDATES", "CATEGORY_FORUMS"])
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
