import XCTest

/// The sidebar's system views: default order, dragging (also across the
/// "More" row), what is stored, and what a closed "More" lists.
final class SidebarSystemOrderTests: XCTestCase {
    private typealias Order = SidebarSystemOrder

    private let always: (String) -> Bool = { _ in true }

    private func listed(_ order: [String], open: Bool = true,
                        exists: ((String) -> Bool)? = nil) -> [String] {
        Order.layout(order, exists: exists ?? always).rows(moreOpen: open)
    }

    // MARK: Default order

    func testDefaultOrderKeepsTodaysRows() {
        XCTAssertEqual(Order.defaultOrder(hasReminders: false),
                       ["inbox", "starred", "snoozed", "important", "sent", "drafts",
                        "allMail", "trash", "outbox", "more", "scheduled", "reminders",
                        "promotions", "social", "spam"])
        XCTAssertEqual(Order.defaultOrder(hasReminders: true),
                       ["inbox", "starred", "snoozed", "important", "sent", "drafts",
                        "allMail", "trash", "outbox", "reminders", "more", "scheduled",
                        "promotions", "social", "spam"],
                       "Reminders sits above More once there is one")
        XCTAssertEqual(Order.resolve(nil, hasReminders: false),
                       Order.defaultOrder(hasReminders: false))
    }

    func testEveryRowHasAView() {
        for id in Order.defaultOrder(hasReminders: false) where id != Order.moreId {
            XCTAssertNotNil(Order.view(for: id), id)
        }
        XCTAssertNil(Order.view(for: Order.moreId))
    }

    // MARK: Closed More lists nothing under it

    func testClosedMoreHidesEverythingUnderIt() {
        let order = Order.defaultOrder(hasReminders: false)
        let closed = listed(order, open: false)
        XCTAssertEqual(closed.last, "more")
        XCTAssertFalse(closed.contains("spam"))
        XCTAssertFalse(closed.contains("reminders"))
        XCTAssertEqual(listed(order).suffix(5), ["scheduled", "reminders", "promotions", "social", "spam"])
    }

    func testMoreIsListedEvenWithNothingUnderIt() {
        let order = ["inbox", "starred", "snoozed", "important", "sent", "drafts", "allMail",
                     "trash", "outbox", "scheduled", "reminders", "promotions", "social",
                     "spam", "more"]
        let layout = Order.layout(order, exists: always)
        XCTAssertTrue(layout.under.isEmpty)
        XCTAssertEqual(layout.rows(moreOpen: false).last, "more")
        // Only rows that do not exist now are under it: still listed.
        let onlyConditional = Order.layout(["inbox", "more", "scheduled"]) { $0 != "scheduled" }
        XCTAssertEqual(onlyConditional.rows(moreOpen: true), ["inbox", "more"])
        // A row dropped after the empty More goes under it again.
        let rows = layout.rows(moreOpen: true)
        let back = Order.move(order, rows: rows, from: [rows.firstIndex(of: "sent")!], to: rows.count)
        XCTAssertEqual(Order.layout(back, exists: always).under, ["sent"])
    }

    /// DEC-063: Reminders is listed above More once something has a
    /// reminder, wherever an earlier drag left its slot.
    func testRemindersStayAboveMoreOnceThereIsOne() {
        let order = Order.defaultOrder(hasReminders: false)
        var rows = listed(order)
        // No reminders yet: the user drags Sent to the top; every id is stored.
        let stored = Order.move(order, rows: rows, from: [rows.firstIndex(of: "sent")!], to: 0)
        XCTAssertTrue(Order.layout(stored, exists: always).under.contains("reminders"))
        // A reminder comes due: the stored order has Reminders under More...
        let resolved = Order.resolve(stored, hasReminders: true)
        let layout = Order.layout(resolved, exists: always, aboveMore: ["reminders"])
        XCTAssertEqual(layout.above.last, "reminders", "...but it is listed above it")
        XCTAssertFalse(layout.under.contains("reminders"))
        XCTAssertTrue(layout.rows(moreOpen: false).contains("reminders"),
                      "visible with More closed")
        // Without reminders the stored slot stands.
        XCTAssertTrue(Order.layout(resolved, exists: always).under.contains("reminders"))
        // A drag with Reminders lifted stays consistent.
        rows = layout.rows(moreOpen: true)
        let again = Order.move(resolved, rows: rows, from: [0], to: rows.count)
        XCTAssertEqual(Set(again), Set(resolved))
    }

    func testDropOnTheSamePlaceChangesNothing() {
        let order = Order.defaultOrder(hasReminders: false)
        let rows = listed(order)
        XCTAssertEqual(Order.move(order, rows: rows, from: [3], to: 3), order)
        XCTAssertEqual(Order.move(order, rows: rows, from: [3], to: 4), order)
    }

    // MARK: Moves

    func testMoveWithinASection() {
        let order = Order.defaultOrder(hasReminders: false)
        let rows = listed(order)
        // Sent (4) to the front.
        let moved = Order.move(order, rows: rows, from: [4], to: 0)
        XCTAssertEqual(Array(moved.prefix(3)), ["sent", "inbox", "starred"])
        XCTAssertEqual(Set(moved), Set(order))
        // Down: Inbox to just above Drafts.
        let down = Order.move(order, rows: rows, from: [0], to: 5)
        XCTAssertEqual(Array(down.prefix(6)), ["starred", "snoozed", "important", "sent", "inbox", "drafts"])
    }

    func testMoveOutOfMoreAboveDrafts() {
        let order = Order.defaultOrder(hasReminders: false)
        let rows = listed(order)
        let promotions = rows.firstIndex(of: "promotions")!
        let drafts = rows.firstIndex(of: "drafts")!
        let moved = Order.move(order, rows: rows, from: [promotions], to: drafts)
        let layout = Order.layout(moved, exists: always)
        XCTAssertEqual(layout.above.firstIndex(of: "promotions"), drafts)
        XCTAssertLessThan(layout.above.firstIndex(of: "promotions")!, layout.above.firstIndex(of: "drafts")!)
        XCTAssertFalse(layout.under.contains("promotions"))
        XCTAssertEqual(layout.rows(moreOpen: true).filter { $0 == "more" }.count, 1)
    }

    func testMoveIntoMoreAndEmptyingIt() {
        let order = Order.defaultOrder(hasReminders: false)
        var rows = listed(order)
        // Trash to the very end: under More.
        var moved = Order.move(order, rows: rows, from: [rows.firstIndex(of: "trash")!], to: rows.count)
        XCTAssertTrue(Order.layout(moved, exists: always).under.contains("trash"))
        // Everything under More goes above it: More disappears.
        for id in ["scheduled", "reminders", "promotions", "social", "spam", "trash"] {
            rows = listed(moved)
            moved = Order.move(moved, rows: rows, from: [rows.firstIndex(of: id)!],
                               to: rows.firstIndex(of: "more")!)
        }
        let layout = Order.layout(moved, exists: always)
        XCTAssertTrue(layout.under.isEmpty)
        XCTAssertEqual(layout.above.count, 14)
        XCTAssertTrue(layout.rows(moreOpen: false).contains("more"), "More stays listed")
    }

    func testMoveWhileMoreIsClosedPutsTheRowUnderIt() {
        let order = Order.defaultOrder(hasReminders: false)
        let rows = listed(order, open: false)
        XCTAssertEqual(rows.last, "more")
        let moved = Order.move(order, rows: rows, from: [rows.firstIndex(of: "sent")!], to: rows.count)
        let layout = Order.layout(moved, exists: always)
        XCTAssertTrue(layout.under.contains("sent"))
        XCTAssertEqual(layout.under.suffix(3), ["promotions", "social", "spam"],
                       "the rows hidden under a closed More keep their order")
    }

    func testRowsThatDoNotExistKeepTheirSideOfMore() {
        // Outbox and Scheduled are absent: dragging a row across More must
        // not push them to the other side.
        let order = Order.defaultOrder(hasReminders: false)
        let exists: (String) -> Bool = { $0 != "outbox" && $0 != "scheduled" }
        var rows = listed(order, exists: exists)
        var moved = Order.move(order, rows: rows, from: [rows.firstIndex(of: "sent")!], to: rows.count)
        var layout = Order.layout(moved, exists: always)
        XCTAssertTrue(layout.above.contains("outbox"), "Outbox stays above More")
        XCTAssertFalse(layout.under.contains("outbox"))
        rows = listed(moved, exists: exists)
        moved = Order.move(moved, rows: rows, from: [rows.firstIndex(of: "spam")!], to: 0)
        layout = Order.layout(moved, exists: always)
        XCTAssertTrue(layout.under.contains("scheduled"), "Scheduled stays under More")
        XCTAssertTrue(layout.above.contains("outbox"))
    }

    func testRowsThatDoNotExistKeepTheirSlot() {
        let order = ["a", "outbox", "b", "more", "c"]
        let moved = Order.move(order, rows: ["a", "b", "more", "c"], from: [0], to: 2)
        XCTAssertEqual(moved, ["b", "outbox", "a", "more", "c"])
    }

    func testIgnoredMoves() {
        let order = Order.defaultOrder(hasReminders: false)
        XCTAssertEqual(Order.move(order, rows: listed(order), from: [], to: 1), order)
        XCTAssertEqual(Order.move(order, rows: listed(order), from: [99], to: 1), order)
    }

    // MARK: Stored order

    func testMissingAndUnknownIdsInTheStoredOrder() {
        let stored = ["promotions", "ghost", "inbox", "inbox", "more"]
        let order = Order.resolve(stored, hasReminders: false)
        XCTAssertFalse(order.contains("ghost"))
        XCTAssertEqual(order.filter { $0 == "inbox" }.count, 1)
        XCTAssertEqual(Set(order), Set(Order.defaultOrder(hasReminders: false)))
        XCTAssertEqual(order.count, 15)
        XCTAssertLessThan(order.firstIndex(of: "promotions")!, order.firstIndex(of: "inbox")!,
                          "stored ids keep their order")
        // A view the stored value lacks takes its default place after its predecessor.
        XCTAssertEqual(Order.resolve(["inbox", "more"], hasReminders: false).prefix(3),
                       ["inbox", "starred", "snoozed"])
        XCTAssertEqual(Order.resolve([], hasReminders: false), Order.defaultOrder(hasReminders: false))
    }

    func testStoreAndReset() throws {
        let suite = "SidebarSystemOrderTests.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertNil(Order.stored(.all, d))
        Order.store(["promotions", "more"], .all, d)
        XCTAssertEqual(Order.stored(.all, d), ["promotions", "more"])
        Order.store(nil, .all, d)
        XCTAssertNil(d.object(forKey: Order.defaultsKey(.all)), "reset restores the default")
        XCTAssertEqual(Order.resolve(Order.stored(.all, d), hasReminders: false),
                       Order.defaultOrder(hasReminders: false))
    }

    /// Each account, and the all-accounts view, has its own order.
    func testOrdersAreIndependentPerSidebar() throws {
        let suite = "SidebarSystemOrderTests.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let a = Order.Scope.account("a@x.com"), b = Order.Scope.account("b@x.com")
        let orderA = Order.defaultOrder(hasReminders: false)
        let rows = listed(orderA)
        let movedA = Order.move(orderA, rows: rows, from: [rows.firstIndex(of: "sent")!], to: 0)
        Order.store(movedA, a, d)
        XCTAssertEqual(Order.stored(a, d), movedA)
        for other in [b, .all] {
            XCTAssertNil(Order.stored(other, d))
            XCTAssertEqual(Order.resolve(Order.stored(other, d), hasReminders: false), orderA,
                           "a sidebar with no stored order shows the default")
        }
        Order.store(["promotions", "more"], b, d)
        XCTAssertEqual(Order.stored(a, d), movedA, "B's order leaves A's alone")
        Order.store(nil, a, d)
        XCTAssertEqual(Order.stored(b, d), ["promotions", "more"], "resetting A leaves B's")
        XCTAssertEqual(Set([Order.defaultsKey(a), Order.defaultsKey(b), Order.defaultsKey(.all)]).count, 3)
    }
    // MARK: One list for the full sidebar and the icon strip

    /// `listed` is what both presentations show: the same rows as the old
    /// resolve → layout → rows chain, for default and stored orders, with
    /// More open or closed and conditional rows present or not.
    func testListedMatchesTheSidebarChain() {
        let stored: [[String]?] = [
            nil, [], ["promotions", "more"],
            ["sent", "inbox", "more", "trash", "starred"],
            ["inbox", "reminders", "more", "scheduled", "outbox"],
        ]
        let noOutbox: (String) -> Bool = { $0 != "outbox" && $0 != "scheduled" }
        for order in stored {
            for reminders in [false, true] {
                for open in [false, true] {
                    for exists in [always, noOutbox] {
                        let chain = Order.layout(Order.resolve(order, hasReminders: reminders),
                                                 exists: exists,
                                                 aboveMore: reminders ? ["reminders"] : [])
                            .rows(moreOpen: open)
                        XCTAssertEqual(Order.listed(stored: order, hasReminders: reminders,
                                                    moreOpen: open, exists: exists), chain,
                                       "\(String(describing: order)) reminders \(reminders) open \(open)")
                    }
                }
            }
        }
    }

    func testListedHonoursTheStoredOrderAndMore() {
        let stored = ["sent", "inbox", "more", "trash", "starred"]
        XCTAssertEqual(Array(Order.listed(stored: stored, hasReminders: false, moreOpen: false,
                                          exists: always).prefix(2)), ["sent", "inbox"],
                       "the stored order comes first")
        let closed = Order.listed(stored: stored, hasReminders: false, moreOpen: false, exists: always)
        XCTAssertEqual(closed.last, "more", "nothing under a closed More")
        XCTAssertFalse(closed.contains("trash"))
        let open = Order.listed(stored: stored, hasReminders: false, moreOpen: true, exists: always)
        XCTAssertTrue(open.contains("trash"))
        XCTAssertGreaterThan(open.firstIndex(of: "trash")!, open.firstIndex(of: "more")!)
        // Reminders above More while one exists (DEC-063).
        let lifted = Order.listed(stored: nil, hasReminders: true, moreOpen: false, exists: always)
        XCTAssertLessThan(lifted.firstIndex(of: "reminders")!, lifted.firstIndex(of: "more")!)
    }

    func testStripHelpCarriesTheCount() {
        XCTAssertEqual(Order.stripHelp(title: "Inbox", count: 12, total: false), "Inbox, 12 unread")
        XCTAssertEqual(Order.stripHelp(title: "Drafts", count: 3, total: true), "Drafts, 3")
        XCTAssertEqual(Order.stripHelp(title: "Inbox", count: 0, total: false), "Inbox")
        XCTAssertEqual(Order.stripHelp(title: "Sent", count: nil, total: false), "Sent")
    }
}
