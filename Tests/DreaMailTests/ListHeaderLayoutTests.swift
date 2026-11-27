import XCTest

final class ListHeaderLayoutTests: XCTestCase {
    private typealias L = ListHeaderLayout

    func testFieldWidthsAreOrdered() {
        XCTAssertLessThan(L.fieldMinWidth, L.fieldIdealWidth)
        XCTAssertLessThan(L.fieldIdealWidth, L.fieldMaxWidth)
    }

    /// Three panes: the list is a middle column of at least 420 pt, with no
    /// window buttons in it. The bar fits with the field at its minimum, also
    /// while searching.
    func testBarFitsTheNarrowestThreePaneColumn() {
        let narrowest: CGFloat = 420
        XCTAssertLessThanOrEqual(L.requiredColumnWidth(searching: false), narrowest)
        XCTAssertLessThanOrEqual(L.requiredColumnWidth(searching: true), narrowest)
    }

    /// The list as the window's last column, at the window's minimum width
    /// (900 + the 64 pt rail): it shares its bar with the window's button
    /// group (3 buttons with Ask AI) and the system sidebar toggle. Sidebar
    /// expanded (240 default, 200 minimum), strip (40 pt) and hidden.
    func testBarFitsTheMinimumWindowInEverySidebarState() {
        let window: CGFloat = 900 + 64
        let rail: CGFloat = 64
        for (name, sidebar) in [("expanded at its minimum", CGFloat(200)),
                                ("expanded at its default", CGFloat(240)),
                                ("strip", CGFloat(40)), ("hidden", CGFloat(0))] {
            let column = window - rail - sidebar
            // The sidebar's own toggle shares the bar only when not expanded.
            let chrome = L.sharedWindowChrome(buttons: 3, sidebarToggle: sidebar < 200)
            XCTAssertLessThanOrEqual(L.requiredColumnWidth(searching: true) + chrome, column,
                                     "sidebar \(name)")
        }
    }

    func testChromeCountsWhatIsThere() {
        XCTAssertEqual(L.sharedWindowChrome(buttons: 0, sidebarToggle: false), 0)
        XCTAssertEqual(L.sharedWindowChrome(buttons: 2, sidebarToggle: false), 90)
        XCTAssertEqual(L.sharedWindowChrome(buttons: 3, sidebarToggle: true), 135 + 48)
    }
}
