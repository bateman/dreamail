import XCTest

final class ThreadRowPillChromeTests: XCTestCase {
    func testFocusedUsesSelectionChrome() {
        XCTAssertEqual(ThreadRowPillChrome.forFocused(true), .onSelection)
        XCTAssertEqual(ThreadRowPillChrome.forFocused(false), .softTint)
    }

    func testSelectionFillIsStrongerThanSoft() {
        XCTAssertGreaterThan(
            ThreadRowPillChrome.onSelection.fillOpacity,
            ThreadRowPillChrome.softTint.fillOpacity)
        XCTAssertGreaterThan(ThreadRowPillChrome.onSelection.fillOpacity, 0.5)
        XCTAssertLessThan(ThreadRowPillChrome.softTint.fillOpacity, 0.3)
    }
}
