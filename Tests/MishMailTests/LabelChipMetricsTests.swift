import XCTest

/// The label chip's shape against Gmail's conversation list (13 pt text in
/// a chip about 17-18 pt tall, ~4 pt corners, 5-6 pt side padding, ~6 pt
/// between chips), and its scaling with the list's font scale.
final class LabelChipMetricsTests: XCTestCase {
    func testMatchesGmailAtThirteenPoints() {
        let m = LabelChipMetrics(fontSize: 13)
        XCTAssertEqual(m.cornerRadius, 4, accuracy: 0.5)
        XCTAssertTrue((5...6).contains(m.horizontalPadding), "\(m.horizontalPadding)")
        XCTAssertTrue((17...18).contains(m.height), "\(m.height)")
        XCTAssertEqual(m.spacing, 6, accuracy: 0.5)
        // A rounded rectangle, not a capsule: the corners are well under
        // half the height.
        XCTAssertLessThan(m.cornerRadius, m.height / 3)
    }

    func testScalesWithTheFontScale() {
        let base = LabelChipMetrics(fontSize: 13)
        for scale in [0.85, 1.0, 1.3, 1.6] {
            let m = LabelChipMetrics(fontSize: 13 * scale)
            XCTAssertEqual(m.cornerRadius, base.cornerRadius * scale, accuracy: 1e-9)
            XCTAssertEqual(m.horizontalPadding, base.horizontalPadding * scale, accuracy: 1e-9)
            XCTAssertEqual(m.height, base.height * scale, accuracy: 1e-9)
            XCTAssertEqual(m.spacing, base.spacing * scale, accuracy: 1e-9)
        }
    }

    /// The thread row's trailing strip is 18 pt × font scale; the row chip
    /// (13 pt × font scale) must fit it at every scale.
    func testRowChipFitsTheTrailingStrip() {
        for scale in [0.85, 1.0, 1.3, 1.6] {
            XCTAssertLessThanOrEqual(LabelChipMetrics(fontSize: 13 * scale).height, 18 * scale)
        }
    }
}
