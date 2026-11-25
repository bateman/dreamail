import XCTest

final class WindowFramePlacementTests: XCTestCase {
    private let main = CGRect(x: 0, y: 0, width: 1_440, height: 860)
    private let right = CGRect(x: 1_440, y: 0, width: 1_920, height: 1_040)
    private let minSize = CGSize(width: 900, height: 560)

    private func fit(_ f: CGRect, _ screens: [CGRect]) -> CGRect {
        WindowFramePlacement.fit(f, in: screens, minSize: minSize)
    }

    func testFittingFrameIsUnchanged() {
        let f = CGRect(x: 100, y: 100, width: 1_000, height: 600)
        XCTAssertEqual(fit(f, [main]), f)
    }

    func testFrameOnSecondDisplayStays() {
        let f = CGRect(x: 1_600, y: 100, width: 1_200, height: 700)
        XCTAssertEqual(fit(f, [main, right]), f)
    }

    func testPartlyOffScreenIsMovedInside() {
        let f = CGRect(x: 1_000, y: 500, width: 1_000, height: 600)
        XCTAssertEqual(fit(f, [main]), CGRect(x: 440, y: 260, width: 1_000, height: 600))
    }

    func testDisplayGoneMovesToMainDisplay() {
        let f = CGRect(x: 1_600, y: 100, width: 1_200, height: 700)
        XCTAssertEqual(fit(f, [main]), CGRect(x: 240, y: 100, width: 1_200, height: 700))
    }

    func testSmallerDisplayShrinksToVisibleArea() {
        let small = CGRect(x: 0, y: 0, width: 1_100, height: 700)
        let f = CGRect(x: 50, y: 50, width: 1_800, height: 1_000)
        XCTAssertEqual(fit(f, [small]), small)
    }

    func testMinimumSizeWinsOverTinySavedFrame() {
        let f = CGRect(x: 100, y: 100, width: 300, height: 200)
        XCTAssertEqual(fit(f, [main]).size, minSize)
    }

    func testNoScreensKeepsFrame() {
        let f = CGRect(x: 5, y: 5, width: 1_000, height: 600)
        XCTAssertEqual(fit(f, []), f)
    }
}
