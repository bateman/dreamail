import XCTest

/// Hostless suite: the height an expanded card gives its HTML body before
/// and after the body measures itself, and the pre-render's height estimate.
final class MessageBodyHeightTests: XCTestCase {

    func testUnmeasuredBodyUsesTheCachedHeightInItsFirstFrame() {
        // A body measured before (re-open, pre-rendered neighbor) must size
        // the first frame at its length, not at the placeholder.
        XCTAssertEqual(MessageBodyHeight.webViewHeight(measured: nil, cached: 1_840), 1_840)
        XCTAssertEqual(
            MessageBodyHeight.containerHeight(measured: nil, cached: 1_840, reserve: 700),
            1_840, "a known height is never replaced by the reservation")
    }

    func testLiveMeasurementWinsOverTheCache() {
        XCTAssertEqual(MessageBodyHeight.webViewHeight(measured: 960, cached: 1_840), 960)
    }

    func testNeverMeasuredBodyStartsAtThePlaceholder() {
        XCTAssertEqual(MessageBodyHeight.webViewHeight(measured: nil, cached: nil),
                       MessageBodyHeight.placeholder)
        XCTAssertEqual(MessageBodyHeight.webViewHeight(measured: 0, cached: 0),
                       MessageBodyHeight.placeholder)
    }

    /// The reported symptom: the open card of a never-seen HTML message was a
    /// 120 pt box for the whole WebKit load. It must fill the pane instead.
    func testUnmeasuredOpenCardFillsThePane() {
        let reserve = MessageBodyHeight.paneReserve(viewportHeight: 800, chromeHeight: 96)
        XCTAssertEqual(reserve, 704)
        XCTAssertEqual(
            MessageBodyHeight.containerHeight(measured: nil, cached: nil, reserve: reserve),
            704)
        // The web view itself keeps its frame, so WebKit measures as before.
        XCTAssertEqual(MessageBodyHeight.webViewHeight(measured: nil, cached: nil),
                       MessageBodyHeight.placeholder)
    }

    func testFirstReportReplacesTheReservationBothWays() {
        // Taller body: grows past the pane in one step.
        XCTAssertEqual(
            MessageBodyHeight.containerHeight(measured: 2_400, cached: nil, reserve: 704),
            2_400)
        // Shorter body: shrinks to its content, no blank tail.
        XCTAssertEqual(
            MessageBodyHeight.containerHeight(measured: 260, cached: nil, reserve: 704),
            260)
    }

    func testCardsThatDoNotFillThePaneKeepThePlaceholder() {
        XCTAssertEqual(
            MessageBodyHeight.containerHeight(measured: nil, cached: nil, reserve: nil),
            MessageBodyHeight.placeholder)
    }

    func testPaneReserveIsBoundedAndNeedsALaidOutPane() {
        XCTAssertNil(MessageBodyHeight.paneReserve(viewportHeight: 0, chromeHeight: 96))
        XCTAssertEqual(MessageBodyHeight.paneReserve(viewportHeight: 150, chromeHeight: 96),
                       MessageBodyHeight.placeholder, "never below the placeholder")
        XCTAssertEqual(MessageBodyHeight.paneReserve(viewportHeight: 600, chromeHeight: -5),
                       600)
    }

    func testScriptResultBridgesEveryNumericType() {
        XCTAssertEqual(HTMLBodyLayout.measuredHeight(fromScriptResult: NSNumber(value: 512)), 512)
        XCTAssertEqual(HTMLBodyLayout.measuredHeight(fromScriptResult: 640.0), 640)
        XCTAssertEqual(HTMLBodyLayout.measuredHeight(fromScriptResult: 700), 700)
        XCTAssertEqual(HTMLBodyLayout.measuredHeight(fromScriptResult: CGFloat(320)), 320)
    }

    func testScriptResultRejectsNonHeights() {
        XCTAssertNil(HTMLBodyLayout.measuredHeight(fromScriptResult: nil))
        XCTAssertNil(HTMLBodyLayout.measuredHeight(fromScriptResult: "512"))
        XCTAssertNil(HTMLBodyLayout.measuredHeight(fromScriptResult: 0))
        XCTAssertNil(HTMLBodyLayout.measuredHeight(fromScriptResult: -4.0))
        XCTAssertNil(HTMLBodyLayout.measuredHeight(fromScriptResult: Double.nan))
    }

    func testScriptResultIsClampedLikeLiveReports() {
        XCTAssertEqual(HTMLBodyLayout.measuredHeight(fromScriptResult: 3),
                       CGFloat(HTMLBodyLayout.minContentHeight))
        XCTAssertEqual(HTMLBodyLayout.measuredHeight(fromScriptResult: 10_000_000),
                       CGFloat(HTMLBodyLayout.maxContentHeight))
    }

    func testPrerenderEstimateFillsAnEmptySlot() {
        var cache = HTMLBodyHeightCache(capacity: 4)
        let key = HTMLBodyHeightCache.key(contentID: "m1:full", fontScale: 1.0)
        cache.storeIfAbsent(900, width: 720, for: key)
        // Pre-layout lookup (width unknown) takes the estimate.
        XCTAssertEqual(cache.height(for: key, width: nil), 900)
    }

    func testPrerenderEstimateNeverReplacesAPaneMeasurement() {
        var cache = HTMLBodyHeightCache(capacity: 4)
        let key = HTMLBodyHeightCache.key(contentID: "m1:full", fontScale: 1.0)
        cache.store(1_100, width: 560, for: key)
        cache.storeIfAbsent(900, width: 720, for: key)
        XCTAssertEqual(cache.height(for: key, width: 560), 1_100)
    }

    func testPrerenderEstimatesAreEvictedBeforeMeasurements() {
        var cache = HTMLBodyHeightCache(capacity: 2)
        cache.store(500, width: 560, for: "measured")
        cache.storeIfAbsent(900, width: 560, for: "estimate")
        cache.store(700, width: 560, for: "measured2")
        XCTAssertNil(cache.height(for: "estimate", width: 560),
                     "the estimate goes first")
        XCTAssertEqual(cache.height(for: "measured", width: 560), 500)
        XCTAssertEqual(cache.height(for: "measured2", width: 560), 700)
    }

    func testPrerenderEstimateIsRejectedAtAnotherWidth() {
        var cache = HTMLBodyHeightCache(capacity: 4)
        cache.storeIfAbsent(900, width: 720, for: "m1:full")
        XCTAssertNil(cache.height(for: "m1:full", width: 500),
                     "a 720 pt estimate must not size a 500 pt pane")
        XCTAssertEqual(cache.height(for: "m1:full", width: 720), 900)
    }
}
