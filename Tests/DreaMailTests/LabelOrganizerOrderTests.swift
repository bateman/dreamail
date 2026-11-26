import XCTest

/// The organizer's order: families shown together, moved as blocks, never
/// re-parented by a drop.
final class LabelOrganizerOrderTests: XCTestCase {
    private func rows(_ names: [String], orders: [Int]? = nil) -> [LabelRow] {
        names.enumerated().map { i, name in
            LabelRow(id: "a:\(name)", accountId: "a", gmailLabelId: name, name: name, type: "user",
                     color: nil, sortOrder: orders?[i] ?? i, listVisibility: nil)
        }
    }

    private func shown(_ e: [LabelOrganizerEntry]) -> [String] {
        e.map { String(repeating: "-", count: $0.depth) + $0.displayName }
    }

    private func names(_ r: [LabelRow]?) -> [String]? { r?.map(\.name) }

    func testInterleavedStoredOrderIsShownAsContiguousFamilies() {
        let e = LabelOrganizerOrder.entries(rows(["a/x", "b", "a", "b/y", "a/w"]))
        // Parent `a` is stored after `b`; `b` (index 1) comes first, children keep stored order.
        XCTAssertEqual(shown(e), ["b", "-y", "a", "-x", "-w"])
    }

    func testDeepAndMissingParentGroupingFollowsTheSidebar() {
        let e = LabelOrganizerOrder.entries(rows(["a", "a/b/c", "a/d", "a/d/e"]))
        XCTAssertEqual(shown(e), ["a", "-b/c", "-d", "--e"])
        XCTAssertEqual(e[1].row.name, "a/b/c", "the full name stays on the row")
    }

    func testLookAlikeNamesAreNotAFamily() {
        let e = LabelOrganizerOrder.entries(rows(["Bandi", "Bandi2", "Bandi/x"]))
        XCTAssertEqual(shown(e), ["Bandi", "-x", "Bandi2"])
        XCTAssertEqual(LabelOrganizerOrder.blockEnd(of: 0, in: e), 2)
        XCTAssertEqual(LabelOrganizerOrder.allowedDestinations(for: 2, in: e), [0])
    }

    func testParentMovesWithAllDescendantsInOrder() {
        let e = LabelOrganizerOrder.entries(rows(["a", "a/1", "a/1/z", "a/2", "b", "c"]))
        // a's block is 0..<4; drop after b (offset 5)
        XCTAssertEqual(names(LabelOrganizerOrder.moved(e, from: 0, to: 5)),
                       ["b", "a", "a/1", "a/1/z", "a/2", "c"])
        XCTAssertEqual(names(LabelOrganizerOrder.moved(e, from: 0, to: 6)),
                       ["b", "c", "a", "a/1", "a/1/z", "a/2"])
    }

    func testMoveUpCarriesTheBlock() {
        let e = LabelOrganizerOrder.entries(rows(["x", "a", "a/1", "a/2"]))
        XCTAssertEqual(names(LabelOrganizerOrder.moved(e, from: 1, to: 0)), ["a", "a/1", "a/2", "x"])
    }

    func testTopLevelCannotLandInsideAnotherFamily() {
        let e = LabelOrganizerOrder.entries(rows(["a", "a/1", "a/2", "b"]))
        XCTAssertEqual(LabelOrganizerOrder.allowedDestinations(for: 3, in: e), [0])
        XCTAssertNil(LabelOrganizerOrder.moved(e, from: 3, to: 1))
        XCTAssertNil(LabelOrganizerOrder.moved(e, from: 3, to: 2))
        XCTAssertNil(LabelOrganizerOrder.moved(e, from: 3, to: 3), "dropping where it is changes nothing")
    }

    func testSublabelReordersOnlyAmongSiblings() {
        let e = LabelOrganizerOrder.entries(rows(["a", "a/1", "a/2", "a/2/z", "a/3", "b"]))
        // a/1 (index 1): siblings a/2 (2), a/3 (4); end of a's block is 5
        XCTAssertEqual(LabelOrganizerOrder.allowedDestinations(for: 1, in: e), [4, 5])
        XCTAssertEqual(names(LabelOrganizerOrder.moved(e, from: 1, to: 5)),
                       ["a", "a/2", "a/2/z", "a/3", "a/1", "b"])
        XCTAssertEqual(names(LabelOrganizerOrder.moved(e, from: 1, to: 4)),
                       ["a", "a/2", "a/2/z", "a/1", "a/3", "b"])
        XCTAssertEqual(names(LabelOrganizerOrder.moved(e, from: 4, to: 1)),
                       ["a", "a/3", "a/1", "a/2", "a/2/z", "b"])
        XCTAssertNil(LabelOrganizerOrder.moved(e, from: 1, to: 0), "out above the parent")
        XCTAssertNil(LabelOrganizerOrder.moved(e, from: 1, to: 6), "out below the family")
        XCTAssertNil(LabelOrganizerOrder.moved(e, from: 1, to: 3), "inside a sibling's family")
    }

    func testGrandchildStaysInItsParent() {
        let e = LabelOrganizerOrder.entries(rows(["a", "a/b", "a/b/1", "a/b/2", "a/c"]))
        XCTAssertEqual(names(LabelOrganizerOrder.moved(e, from: 2, to: 4)),
                       ["a", "a/b", "a/b/2", "a/b/1", "a/c"])
        XCTAssertNil(LabelOrganizerOrder.moved(e, from: 2, to: 5))
    }

    func testSiblingOrderMatchesTheSidebarAfterAMove() {
        let e = LabelOrganizerOrder.entries(rows(["a", "a/1", "a/2", "b"]))
        let order = LabelOrganizerOrder.moved(e, from: 0, to: 4)!
        let stored = order.enumerated().map { i, r -> LabelRow in var r = r; r.sortOrder = i; return r }
        XCTAssertEqual(SidebarLabelTree.build(stored).map(\.fullName), ["b", "a"])
        XCTAssertEqual(LabelOrganizerOrder.entries(stored).map(\.row.name), ["b", "a", "a/1", "a/2"])
    }

    private func flat(_ nodes: [SidebarLabelNode]) -> [String] {
        nodes.flatMap { [$0.id] + flat($0.children) }
    }

    func testEntriesEqualTheFlattenedSidebarTree() {
        let cases: [[LabelRow]] = [
            rows(["z", "a", "a/new", "m"], orders: [LabelRow.unsorted, LabelRow.unsorted, LabelRow.unsorted, LabelRow.unsorted]),
            rows(["b", "a", "a/1", "b/1"], orders: [5, 5, 5, 5]),
            rows(["a", "a/b", "a/bc", "a/b/x", "a/bc/y"]),
            rows(["a/b/c", "a/b", "a", "a/d"], orders: [3, 2, 9, 1]),
        ]
        for c in cases {
            XCTAssertEqual(LabelOrganizerOrder.entries(c).map(\.id), flat(SidebarLabelTree.build(c)))
        }
    }

    func testUnorderedLabelsAreAlphabeticalAndGrouped() {
        let u = LabelRow.unsorted
        let e = LabelOrganizerOrder.entries(rows(["b", "a/z", "a", "a/y"], orders: [u, u, u, u]))
        XCTAssertEqual(shown(e), ["a", "-y", "-z", "b"])
    }

    func testPrefixSiblingsAreNotNested() {
        let e = LabelOrganizerOrder.entries(rows(["a/b", "a/bc", "a"]))
        XCTAssertEqual(shown(e), ["a", "-b", "-bc"])
    }

    func testNewSublabelFromSyncLandsInsideItsFamilyInFlatReaders() {
        let u = LabelRow.unsorted
        let r = rows(["a", "a/1", "b", "a/new"], orders: [0, 1, 2, u])
        XCTAssertEqual(LabelOrganizerOrder.entries(r).map(\.row.name), ["a", "a/1", "a/new", "b"])
    }

    /// A drag stores an order for the siblings of the moved row only: the
    /// other groups stay unsorted and keep following Gmail's order.
    func testDragWritesOnlyTheMovedGroup() {
        let before = rows(["a", "a/1", "a/2", "a/3", "b", "b/x", "b/y", "c"])
        let entries = LabelOrganizerOrder.entries(before)
        // a/1 (index 1) after a/2: only a's sublabels change.
        let moved = LabelOrganizerOrder.moved(entries, from: 1, to: 3)!
        let writes = LabelOrganizerOrder.sortOrders(before: entries.map(\.row), after: moved)
        XCTAssertEqual(Set(writes.keys), ["a:a/1", "a:a/2", "a:a/3"])
        XCTAssertEqual(writes["a:a/2"], 0)
        XCTAssertEqual(writes["a:a/1"], 1)
        XCTAssertEqual(writes["a:a/3"], 2)
        // A top-level move writes the top level only.
        let top = LabelOrganizerOrder.moved(entries, from: 7, to: 0)!
        let topWrites = LabelOrganizerOrder.sortOrders(before: entries.map(\.row), after: top)
        XCTAssertEqual(Set(topWrites.keys), ["a:a", "a:b", "a:c"])
    }
}
