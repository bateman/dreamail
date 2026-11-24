import XCTest

/// The label chip's shape against Gmail's conversation list: 13 pt text in
/// a chip about 17-18 pt tall, ~4 pt corners, 5-6 pt side padding, ~6 pt
/// between chips.
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

    /// The thread row's chip, at its own font size, fits the row's
    /// trailing strip (both scale with the font scale alike).
    func testRowChipFitsTheTrailingStrip() {
        let chip = LabelChipMetrics(fontSize: ThreadRowChipLayout.fontSize)
        XCTAssertLessThanOrEqual(chip.height, ThreadRowChipLayout.trailingStripHeight)
        // The width cap leaves room for a few words, not a single letter.
        XCTAssertGreaterThan(ThreadRowChipLayout.maxWidth, 6 * ThreadRowChipLayout.fontSize)
    }
}
