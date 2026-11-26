import XCTest
@testable import DreaMail

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

    func testSectionBreakIsShorterThanARowInBothDensities() {
        for density in ListDensity.allCases {
            for scale in [0.8, 1.0, 1.3] {
                let m = ThreadListMetrics(density: density, fontScale: scale)
                XCTAssertLessThan(m.sectionGap, m.rowHeight, "\(density) at \(scale)")
                XCTAssertGreaterThanOrEqual(m.sectionHeaderTopPadding, 0)
            }
        }
    }

    func testUnknownStoredValueIsComfortable() {
        XCTAssertEqual(ListDensity.from(raw: ""), .comfortable)
        XCTAssertEqual(ListDensity.from(raw: "compact"), .compact)
    }
}
