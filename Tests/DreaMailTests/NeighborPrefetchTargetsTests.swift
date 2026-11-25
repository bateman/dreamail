import XCTest

final class NeighborPrefetchTargetsTests: XCTestCase {
    private let order = ["a", "b", "c", "d"]

    /// The auto-highlighted top row after launch is the first thing ↩ or a
    /// click opens: it must be warmed itself, not only its neighbour.
    func testHighlightedRowThatIsNotOpenIsWarmedFirst() {
        XCTAssertEqual(
            NeighborPrefetch.targets(selected: "a", openedId: nil, in: order),
            ["a", "b"])
        XCTAssertEqual(
            NeighborPrefetch.targets(selected: "c", openedId: "b", in: order),
            ["c", "b", "d"])
    }

    /// The open conversation loads itself; prefetch only warms neighbours.
    func testOpenConversationIsNotPrefetchedAgain() {
        XCTAssertEqual(
            NeighborPrefetch.targets(selected: "b", openedId: "b", in: order),
            ["a", "c"])
    }

    func testNoSelectionOrUnknownRowWarmsOnlyWhatIsListed() {
        XCTAssertEqual(
            NeighborPrefetch.targets(selected: nil, openedId: nil, in: order), [])
        XCTAssertEqual(
            NeighborPrefetch.targets(selected: "zz", openedId: nil, in: order),
            ["zz"])
    }

    /// Quiet (auto-highlight) and browse selections warm; opening intents
    /// warm through `openDetail` instead.
    func testWarmingIntents() {
        XCTAssertTrue(NeighborPrefetch.warmsOnSelection(.quiet))
        XCTAssertTrue(NeighborPrefetch.warmsOnSelection(.browse))
        for intent: ThreadSelectionIntent in [.click, .autoAdvance, .explicitOpen, .restoreFocus] {
            XCTAssertFalse(NeighborPrefetch.warmsOnSelection(intent))
            XCTAssertTrue(intent.opensDetailImmediately)
        }
    }
}
