import XCTest
@testable import DreaMail

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
        let with = Order.defaultOrder(hasReminders: true)
        XCTAssertLessThan(with.firstIndex(of: "reminders")!, with.firstIndex(of: "more")!,
                          "Reminders sits above More once there is one")
        XCTAssertEqual(Order.resolve(nil, hasReminders: false),
                       Order.defaultOrder(hasReminders: false))
    }

    func testEveryViewHasAnIdAndBack() {
        for id in Order.defaultOrder(hasReminders: false) where id != Order.moreId {
            let view = try? XCTUnwrap(Order.view(for: id), id)
            XCTAssertEqual(view.flatMap(Order.id(for:)), id)
        }
        XCTAssertNil(Order.id(for: .labels))
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

    func testMoreIsHiddenWhenNothingIsUnderIt() {
        let order = ["inbox", "starred", "snoozed", "important", "sent", "drafts", "allMail",
                     "trash", "outbox", "scheduled", "reminders", "promotions", "social",
                     "spam", "more"]
        let layout = Order.layout(order, exists: always)
        XCTAssertFalse(layout.showsMore)
        XCTAssertFalse(layout.rows(moreOpen: true).contains("more"))
        // Only rows that do not exist now are under it: hidden as well.
        let onlyConditional = Order.layout(["inbox", "more", "scheduled"]) { $0 != "scheduled" }
        XCTAssertFalse(onlyConditional.showsMore)
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

    func testMoveIntoMoreAndEmptyingItHidesMore() {
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
        XCTAssertFalse(layout.showsMore)
        XCTAssertEqual(layout.above.count, 14)
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
        XCTAssertNil(Order.stored(d))
        Order.store(["promotions", "more"], d)
        XCTAssertEqual(Order.stored(d), ["promotions", "more"])
        Order.store(nil, d)
        XCTAssertNil(d.object(forKey: Order.defaultsKey), "reset restores the default")
        XCTAssertEqual(Order.resolve(Order.stored(d), hasReminders: false),
                       Order.defaultOrder(hasReminders: false))
    }
}
