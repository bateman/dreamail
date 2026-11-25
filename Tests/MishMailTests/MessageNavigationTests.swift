import XCTest

/// Gmail's `n` / `p` (next / previous message) and `;` / `:` (expand /
/// collapse all) inside an open conversation, on the flat message rows.
final class MessageNavigationTests: XCTestCase {
    private let ids = ["m1", "m2", "m3", "m4"]

    private func state(_ expanded: Set<String>, cursor: String? = nil,
                       all: Bool = false) -> MessageNavigation.State {
        .init(expanded: expanded, cursor: cursor, expandAll: all)
    }

    func testCommandsMapToActions() {
        XCTAssertEqual(MessageNavigation.Action(.nextMessage), .next)
        XCTAssertEqual(MessageNavigation.Action(.previousMessage), .previous)
        XCTAssertEqual(MessageNavigation.Action(.expandAll), .expandAll)
        XCTAssertEqual(MessageNavigation.Action(.collapseAll), .collapseAll)
        XCTAssertNil(MessageNavigation.Action(.next), "j is the conversation list's key")
    }

    /// The conversation opens on its newest message; `p` opens the one
    /// before it (and closes the newest, the reading pane keeps one open).
    func testPreviousFromTheOpenNewestMessage() {
        let (after, scroll) = MessageNavigation.apply(
            .previous, to: state(["m4"]), ids: ids, policy: .single)
        XCTAssertEqual(after.expanded, ["m3"])
        XCTAssertEqual(after.cursor, "m3")
        XCTAssertEqual(scroll, "m3")
        let (back, scrollBack) = MessageNavigation.apply(
            .next, to: after, ids: ids, policy: .single)
        XCTAssertEqual(back.expanded, ["m4"])
        XCTAssertEqual(scrollBack, "m4")
    }

    func testEndsOfTheConversationStayPut() {
        let newest = state(["m4"], cursor: "m4")
        XCTAssertEqual(MessageNavigation.apply(.next, to: newest, ids: ids, policy: .single).state,
                       newest)
        XCTAssertNil(MessageNavigation.apply(.next, to: newest, ids: ids, policy: .single).scrollTo)
        let oldest = state(["m1"], cursor: "m1")
        XCTAssertNil(MessageNavigation.apply(.previous, to: oldest, ids: ids, policy: .single).scrollTo)
    }

    /// Nothing open (after `:`): the walk starts from the newest message.
    func testWithNothingOpenTheCursorStartsAtTheNewest() {
        XCTAssertEqual(MessageNavigation.current(state([]), ids: ids), "m4")
        let (after, _) = MessageNavigation.apply(.previous, to: state([]), ids: ids, policy: .single)
        XCTAssertEqual(after.expanded, ["m3"])
    }

    /// A cursor that left the thread (a draft sent, a message deleted) is
    /// ignored.
    func testStaleCursorFallsBackToTheOpenMessage() {
        XCTAssertEqual(MessageNavigation.current(state(["m2"], cursor: "gone"), ids: ids), "m2")
    }

    func testExpandAllOpensEveryMessageAndNavigationKeepsThemOpen() {
        let (all, scroll) = MessageNavigation.apply(
            .expandAll, to: state(["m4"]), ids: ids, policy: .single)
        XCTAssertEqual(all.expanded, Set(ids))
        XCTAssertTrue(all.expandAll)
        XCTAssertNil(scroll)
        let (moved, to) = MessageNavigation.apply(.previous, to: all, ids: ids, policy: .multiple)
        XCTAssertEqual(moved.expanded, Set(ids), "n / p only scroll while all are open")
        XCTAssertEqual(to, "m3")
    }

    func testCollapseAllClosesEveryMessageButASoleOne() {
        let (none, _) = MessageNavigation.apply(
            .collapseAll, to: state(Set(ids), all: true), ids: ids, policy: .multiple)
        XCTAssertEqual(none.expanded, [])
        XCTAssertFalse(none.expandAll)
        let (sole, _) = MessageNavigation.apply(
            .collapseAll, to: state(["m1"]), ids: ["m1"], policy: .single)
        XCTAssertEqual(sole.expanded, ["m1"], "a one-message conversation always shows it")
    }

    func testEmptyConversationDoesNothing() {
        let s = state([])
        XCTAssertNil(MessageNavigation.apply(.next, to: s, ids: [], policy: .single).scrollTo)
    }
}
