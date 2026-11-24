import XCTest

/// Section breaks in the thread list must stay compact: a small gap after
/// the last row and a header about half a row tall, at every font scale.
/// (Before: a 40 pt footer row plus a full-height header cost about two
/// rows of empty space per break.)
final class ThreadListSectionMetricsTests: XCTestCase {
    private let scales: [CGFloat] = [0.85, 1.0, 1.25, 1.5, 2.0]

    func testGapIsSmallAtDefaultScale() {
        let gap = ThreadListSectionMetrics.sectionGap(fontScale: 1)
        XCTAssertGreaterThanOrEqual(gap, 6)
        XCTAssertLessThanOrEqual(gap, 10)
    }

    func testGapIsAFractionOfARow() {
        for s in scales {
            let gap = ThreadListSectionMetrics.sectionGap(fontScale: s)
            let row = ThreadListSectionMetrics.rowContentHeight(fontScale: s)
            XCTAssertGreaterThan(gap, 0, "scale \(s)")
            XCTAssertLessThanOrEqual(gap, row / 3, "scale \(s)")
        }
    }

    func testHeaderIsAboutHalfARowAndNeverARowOrMore() {
        for s in scales {
            let header = ThreadListSectionMetrics.headerHeight(fontScale: s)
            let row = ThreadListSectionMetrics.rowContentHeight(fontScale: s)
            XCTAssertLessThan(header, row, "scale \(s)")
            XCTAssertGreaterThanOrEqual(header, 0.4 * row, "scale \(s)")
            XCTAssertLessThanOrEqual(header, 0.85 * row, "scale \(s)")
        }
    }

    func testHeaderFitsItsTitle() {
        // 12 pt semibold text, or the Labels view pill (12 pt text plus
        // 2 pt padding above and below).
        for s in scales {
            XCTAssertGreaterThanOrEqual(
                ThreadListSectionMetrics.headerTitleHeight(fontScale: s), (12 + 4) * s,
                "scale \(s)")
        }
    }

    func testHeaderIsGapPlusTitle() {
        for s in scales {
            XCTAssertEqual(ThreadListSectionMetrics.headerHeight(fontScale: s),
                           ThreadListSectionMetrics.sectionGap(fontScale: s)
                               + ThreadListSectionMetrics.headerTitleHeight(fontScale: s),
                           accuracy: 0.001)
        }
    }

    func testEveryValueScalesLinearlyWithFontScale() {
        let fns: [(CGFloat) -> CGFloat] = [
            { ThreadListSectionMetrics.sectionGap(fontScale: $0) },
            { ThreadListSectionMetrics.headerTitleHeight(fontScale: $0) },
            { ThreadListSectionMetrics.headerHeight(fontScale: $0) },
            { ThreadListSectionMetrics.rowContentHeight(fontScale: $0) },
        ]
        for fn in fns {
            for s in scales {
                XCTAssertEqual(fn(s), fn(1) * s, accuracy: 0.001, "scale \(s)")
            }
        }
    }
}
