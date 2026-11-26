import XCTest

final class ThreadListMetricsTests: XCTestCase {
    func testComfortableIsTodaysLayout() {
        for scale in [0.8, 1.0, 1.3] {
            let m = ThreadListMetrics(density: .comfortable, fontScale: scale)
            XCTAssertEqual(m.rowVerticalPadding, 6 * scale, accuracy: 0.001)
            XCTAssertEqual(m.rowContentHeight, 18 * scale, accuracy: 0.001)
            XCTAssertEqual(m.hitExtraV, ThreadRowActionLayout.hitExtraV)
        }
    }

    func testCompactOnlyReducesThePadding() {
        for scale in [0.8, 1.0, 1.3] {
            let c = ThreadListMetrics(density: .compact, fontScale: scale)
            let k = ThreadListMetrics(density: .comfortable, fontScale: scale)
            XCTAssertEqual(c.rowVerticalPadding, 2 * scale, accuracy: 0.001)
            XCTAssertEqual(c.rowContentHeight, k.rowContentHeight)
            XCTAssertLessThanOrEqual(c.hitExtraV, c.rowVerticalPadding)
        }
    }

    func testUnknownStoredValueIsComfortable() {
        XCTAssertEqual(ListDensity.from(raw: ""), .comfortable)
        XCTAssertEqual(ListDensity.from(raw: "compact"), .compact)
    }

    func testSidebarDensity() {
        XCTAssertEqual(SidebarDensity.comfortable.minRowHeight, 30)
        XCTAssertLessThan(SidebarDensity.compact.minRowHeight, 30)
        XCTAssertNil(SidebarDensity.comfortable.listRowSize)
        XCTAssertEqual(SidebarDensity.compact.listRowSize, .small)
        XCTAssertEqual(SidebarDensity.from(raw: "nope"), .comfortable)
        XCTAssertEqual(SidebarDensity.from(raw: ""), .comfortable)
        XCTAssertEqual(SidebarDensity.from(raw: "compact"), .compact)
    }
}
