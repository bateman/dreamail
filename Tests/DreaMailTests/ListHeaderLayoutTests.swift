import XCTest

final class ListHeaderLayoutTests: XCTestCase {
    func testFieldWidthsAreOrdered() {
        XCTAssertLessThan(ListHeaderLayout.fieldMinWidth, ListHeaderLayout.fieldIdealWidth)
        XCTAssertLessThan(ListHeaderLayout.fieldIdealWidth, ListHeaderLayout.fieldMaxWidth)
    }
}
