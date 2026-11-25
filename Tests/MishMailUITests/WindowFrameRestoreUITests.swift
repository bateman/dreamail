import XCTest

/// A resized main window comes back at that size after a relaunch.
final class WindowFrameRestoreUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MISHMAIL_DEMO"] = "1"
        app.launchEnvironment["MISHMAIL_UI_TEST"] = "1"
        app.launchEnvironment["MISHMAIL_UI_TEST_RESTORE_FRAME"] = "1"
        app.launchArguments += ["-accentColor", ""]
        app.launch()
        return app
    }

    func testResizedWindowReopensAtSameSize() {
        let first = launch()
        let window = first.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let before = window.frame
        // Drag the bottom-right corner inwards, staying above the minimum.
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
        corner.withOffset(CGVector(dx: -2, dy: -2))
            .press(forDuration: 0.2,
                   thenDragTo: corner.withOffset(CGVector(dx: -102, dy: -62)))
        let after = window.frame
        XCTAssertLessThan(after.width, before.width - 50, "window did not resize")
        first.terminate()

        let second = launch()
        addTeardownBlock { second.terminate() }
        let reopened = second.windows.firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 10))
        XCTAssertEqual(reopened.frame.width, after.width, accuracy: 2)
        XCTAssertEqual(reopened.frame.height, after.height, accuracy: 2)
    }
}
