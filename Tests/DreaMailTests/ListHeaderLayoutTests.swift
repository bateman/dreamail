import XCTest

final class ListHeaderLayoutTests: XCTestCase {
    private let two: [WindowToolbarButton] = [.paneToggle, .focus]

    private func resolve(_ width: CGFloat, over: [WindowToolbarButton] = [],
                         sidebarToggle: Bool = false, searching: Bool = false)
        -> ListHeaderLayout.Result {
        ListHeaderLayout.resolve(columnWidth: width, buttonsOverRow: over,
                                 sidebarToggleOverRow: sidebarToggle, searching: searching)
    }

    func testWindowButtonsFollowTheToolbarDescription() {
        XCTAssertEqual(ListHeaderLayout.windowButtons(fullWindowThreads: false, askAIEnabled: true),
                       [.paneToggle, .focus, .askAI])
        XCTAssertEqual(ListHeaderLayout.windowButtons(fullWindowThreads: false, askAIEnabled: false),
                       [.paneToggle, .focus])
        XCTAssertEqual(ListHeaderLayout.windowButtons(fullWindowThreads: true, askAIEnabled: false),
                       [.focus])
    }

    func testReserveOnlyForButtonsReallyOverTheRow() {
        XCTAssertEqual(ListHeaderLayout.leadingReserve(buttonsOverRow: [], sidebarToggleOverRow: false), 0)
        XCTAssertEqual(ListHeaderLayout.leadingReserve(buttonsOverRow: two, sidebarToggleOverRow: false), 100)
        XCTAssertEqual(ListHeaderLayout.leadingReserve(buttonsOverRow: two, sidebarToggleOverRow: true), 145)
        XCTAssertEqual(ListHeaderLayout.leadingReserve(buttonsOverRow: [], sidebarToggleOverRow: true), 45)
        XCTAssertFalse(ListHeaderLayout.windowButtonsOverRow(mode: .threePane))
        XCTAssertTrue(ListHeaderLayout.windowButtonsOverRow(mode: .list))
    }

    /// Centre peek renders the list layout: the rule is fed the layout that is
    /// rendered, so the reserve is there.
    func testPeekUsesTheListLayoutReserve() {
        XCTAssertTrue(ListHeaderLayout.windowButtonsOverRow(mode: .list))
    }

    func testWidth340() {
        // Three panes (no buttons over the row): everything fits.
        XCTAssertEqual(resolve(340), .init(reserve: 0, showsSearchAllText: false,
                                           fieldMinWidth: 150, fieldMaxWidth: 380, titleMinWidth: 48))
        // Searching: the Gmail button stays an icon.
        XCTAssertEqual(resolve(340, searching: true).showsSearchAllText, false)
        XCTAssertEqual(resolve(340, searching: true).fieldMinWidth, 150)
        // Two window buttons: the field shrinks below 150 first.
        let tight = resolve(340, over: two)
        XCTAssertEqual(tight.fieldMinWidth, 132)
        XCTAssertEqual(tight.titleMinWidth, 48)
        // Buttons and the sidebar toggle: the field is at its hard minimum and
        // the title gives up part of its width, but keeps some.
        let tightest = resolve(340, over: two, sidebarToggle: true)
        XCTAssertEqual(tightest.fieldMinWidth, 100)
        XCTAssertEqual(tightest.titleMinWidth, 35)
    }

    func testWidth420() {
        XCTAssertEqual(resolve(420).fieldMinWidth, 150)
        XCTAssertEqual(resolve(420, over: two, sidebarToggle: true, searching: true).fieldMinWidth, 131)
        XCTAssertEqual(resolve(420, over: two, sidebarToggle: true, searching: true).showsSearchAllText, false)
    }

    func testWidth600() {
        XCTAssertEqual(resolve(600, searching: true).showsSearchAllText, true)
        XCTAssertEqual(resolve(600, over: two, sidebarToggle: true, searching: true).showsSearchAllText, false)
        XCTAssertEqual(resolve(600, over: two, sidebarToggle: true).fieldMinWidth, 150)
    }

    func testWidth1000() {
        let r = resolve(1000, over: two, sidebarToggle: true, searching: true)
        XCTAssertEqual(r.showsSearchAllText, true)
        XCTAssertEqual(r.fieldMinWidth, 150)
        XCTAssertEqual(r.titleMinWidth, 48)
    }

    /// The title never goes below its hard minimum, however narrow.
    func testTitleNeverDisappears() {
        for width in stride(from: CGFloat(0), through: 1200, by: 20) {
            for sidebarToggle in [false, true] {
                let r = resolve(width, over: two, sidebarToggle: sidebarToggle, searching: true)
                XCTAssertGreaterThanOrEqual(r.titleMinWidth, ListHeaderLayout.titleHardMinWidth)
                XCTAssertGreaterThanOrEqual(r.fieldMinWidth, ListHeaderLayout.fieldHardMinWidth)
                XCTAssertLessThanOrEqual(r.fieldMinWidth, ListHeaderLayout.fieldPreferredMinWidth)
            }
        }
    }
}
