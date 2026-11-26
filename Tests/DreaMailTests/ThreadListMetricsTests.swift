import AppKit
import SwiftUI
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

    /// The label "⋮" is no taller than the row's glyph, whatever the sidebar
    /// icon size, and its dots sit on whole points.
    func testLabelMenuDotsAreNoTallerThanTheGlyph() {
        for rowSize in [SidebarRowSize.small, .medium, .large] {
            let l = LabelMenuButton.layout(rowSize: rowSize)
            let glyph = MailIconMetrics(rowSize: rowSize).pointSize
            XCTAssertLessThanOrEqual(LabelMenuButton.size(rowSize: rowSize).height, glyph)
            XCTAssertGreaterThan(LabelMenuButton.size(rowSize: rowSize).height,
                                 LabelMenuButton.size(rowSize: rowSize).width)
            XCTAssertEqual(l.gap, l.gap.rounded())
            XCTAssertEqual(l.diameter, l.diameter.rounded())
        }
    }

    /// Titles that repeat (an empty name becomes "Signature"; one may be
    /// called "No signature") keep one menu item each, so the item picked is
    /// the signature stored.
    func testSignatureDefaultPopUpKeepsSameNamedItems() {
        let items: [SignatureDefaultPopUp.Item] = [
            .init(title: "No signature", value: .none),
            .init(title: "Signature", value: .signature(1)),
            .init(title: "Signature", value: .signature(2)),
            .init(title: "No signature", value: .signature(3)),
        ]
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        SignatureDefaultPopUp.fill(button, with: items)
        XCTAssertEqual(button.numberOfItems, items.count)
        var picked: SignatureDefaultChoice?
        let coordinator = SignatureDefaultPopUp.Coordinator()
        coordinator.items = items
        coordinator.onSelect = { picked = $0 }
        button.selectItem(at: 2)
        coordinator.changed(button)
        XCTAssertEqual(picked, .signature(2))
        button.selectItem(at: 3)
        coordinator.changed(button)
        XCTAssertEqual(picked, .signature(3))
    }
}
