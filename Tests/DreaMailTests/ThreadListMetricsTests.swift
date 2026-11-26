import XCTest

final class ThreadListMetricsTests: XCTestCase {
    func testComfortableIsTodaysLayout() {
        for scale in [0.8, 1.0, 1.3] {
            let m = ThreadListMetrics(density: .comfortable, fontScale: scale)
            XCTAssertEqual(m.rowVerticalPadding, 6 * scale, accuracy: 0.001)
            XCTAssertEqual(m.rowContentHeight, 18 * scale, accuracy: 0.001)
            XCTAssertEqual(m.sectionGap, 6 * scale, accuracy: 0.001)
            XCTAssertEqual(m.sectionHeaderTopPadding, max(0, 6 * scale - 4), accuracy: 0.001)
        }
    }

    func testCompactIsDenserAndKeepsContent() {
        let c = ThreadListMetrics(density: .compact)
        let k = ThreadListMetrics(density: .comfortable)
        XCTAssertEqual(c.rowVerticalPadding, 2, accuracy: 0.001)
        XCTAssertEqual(c.rowHeight, 22, accuracy: 0.001)
        XCTAssertEqual(c.rowContentHeight, k.rowContentHeight)
        XCTAssertEqual(k.rowHeight - c.rowHeight, 8, accuracy: 0.001)
        // A label chip still fits in the row's content.
        XCTAssertLessThanOrEqual(LabelChipMetrics(fontSize: ThreadRowChipLayout.fontSize).height,
                                 c.rowContentHeight)
    }

    func testSectionHeaderIsTheSameInBothDensities() {
        for scale in [0.8, 1.0, 1.3] {
            let k = ThreadListMetrics(density: .comfortable, fontScale: scale)
            let c = ThreadListMetrics(density: .compact, fontScale: scale)
            XCTAssertEqual(k.sectionGap, c.sectionGap)
            XCTAssertEqual(k.sectionHeaderTopPadding, c.sectionHeaderTopPadding)
            // Comfortable keeps the break shorter than a row.
            XCTAssertLessThan(k.sectionGap, k.rowHeight)
        }
    }

    func testUnknownStoredValueIsComfortable() {
        XCTAssertEqual(ListDensity.from(raw: ""), .comfortable)
        XCTAssertEqual(ListDensity.from(raw: "compact"), .compact)
    }
}
