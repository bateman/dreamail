import XCTest

final class AskAILayoutTests: XCTestCase {

    func testPanelWidthClampsToBounds() {
        XCTAssertEqual(AskAILayout.panelWidth(hostWidth: 500), 320)   // floor
        XCTAssertEqual(AskAILayout.panelWidth(hostWidth: 2000), 480)  // ceiling
        XCTAssertEqual(AskAILayout.panelWidth(hostWidth: 1250), 400)  // 0.32 in range
    }

    /// An unmeasured host (first frame) must not collapse the panel below the
    /// floor, and must not report a negative width.
    func testPanelWidthOnUnmeasuredHost() {
        XCTAssertEqual(AskAILayout.panelWidth(hostWidth: 0), 320)
        XCTAssertEqual(AskAILayout.panelWidth(hostWidth: -100), 320)
    }

    func testPanelHiddenOnNarrowHosts() {
        XCTAssertFalse(AskAILayout.showsPanel(hostWidth: 800, enabled: true))
        XCTAssertTrue(AskAILayout.showsPanel(hostWidth: 1200, enabled: true))
        XCTAssertFalse(AskAILayout.showsPanel(hostWidth: 1200, enabled: false))
    }

    /// The host floor is inclusive, and an unmeasured host keeps the panel
    /// hidden instead of flashing it at the floor width.
    func testPanelVisibilityAtBoundaries() {
        XCTAssertTrue(AskAILayout.showsPanel(hostWidth: AskAILayout.minHostWidth,
                                               enabled: true))
        XCTAssertFalse(AskAILayout.showsPanel(
            hostWidth: AskAILayout.minHostWidth - 1, enabled: true))
        XCTAssertFalse(AskAILayout.showsPanel(hostWidth: 0, enabled: true))
    }

    /// The mailbox keeps at least the panel floor for itself, so opening the
    /// panel never squeezes the list out of the window.
    func testMailboxKeepsRoomForItself() {
        let hostWidth: CGFloat = 1200
        let panel = AskAILayout.panelWidth(hostWidth: hostWidth)
        XCTAssertGreaterThanOrEqual(hostWidth - panel, AskAILayout.minPanelWidth)
    }


    // MARK: - Transcript near-bottom

    func testNearBottomWithinSlack() {
        XCTAssertTrue(AskAILayout.isNearBottom(.init(offsetY: 560, containerHeight: 400,
                                                        contentHeight: 1_000)))
        XCTAssertFalse(AskAILayout.isNearBottom(.init(offsetY: 100, containerHeight: 400,
                                                         contentHeight: 1_000)))
        // Short content is always at the bottom.
        XCTAssertTrue(AskAILayout.isNearBottom(.init(offsetY: 0, containerHeight: 400,
                                                        contentHeight: 200)))
    }

    func testContentGrowthAloneDoesNotChangeNearBottom() {
        let old = AskAILayout.ScrollMetrics(offsetY: 600, containerHeight: 400,
                                              contentHeight: 1_000)
        let grown = AskAILayout.ScrollMetrics(offsetY: 600, containerHeight: 400,
                                                contentHeight: 1_400)
        XCTAssertNil(AskAILayout.nearBottomAfterScroll(from: old, to: grown))
    }

    func testWheelScrollUpAndBackDownUpdatesNearBottom() {
        let bottom = AskAILayout.ScrollMetrics(offsetY: 600, containerHeight: 400,
                                                 contentHeight: 1_000)
        let up = AskAILayout.ScrollMetrics(offsetY: 200, containerHeight: 400,
                                             contentHeight: 1_000)
        XCTAssertEqual(AskAILayout.nearBottomAfterScroll(from: bottom, to: up), false)
        XCTAssertEqual(AskAILayout.nearBottomAfterScroll(from: up, to: bottom), true)
    }
}
