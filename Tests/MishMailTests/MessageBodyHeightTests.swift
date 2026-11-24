import XCTest

/// Hostless suite: the height an expanded card gives its HTML body before
/// and after the body measures itself, and the pre-render's height estimate.
final class MessageBodyHeightTests: XCTestCase {

    func testUnmeasuredBodyUsesTheCachedHeightInItsFirstFrame() {
        // A body measured before (re-open, pre-rendered neighbor) must size
        // the first frame at its length, not at the placeholder.
        XCTAssertEqual(MessageBodyHeight.display(measured: nil, cached: 1_840), 1_840)
    }

    func testLiveMeasurementWinsOverTheCache() {
        XCTAssertEqual(MessageBodyHeight.display(measured: 960, cached: 1_840), 960)
    }

    func testNeverMeasuredBodyStartsAtThePlaceholder() {
        XCTAssertEqual(MessageBodyHeight.display(measured: nil, cached: nil),
                       MessageBodyHeight.placeholder)
        XCTAssertEqual(MessageBodyHeight.display(measured: 0, cached: 0),
                       MessageBodyHeight.placeholder)
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
}
