import XCTest

/// A resized main window comes back at that size after a relaunch.
final class WindowFrameRestoreUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DREAMAIL_DEMO"] = "1"
        app.launchEnvironment["DREAMAIL_UI_TEST"] = "1"
        // The short label list: a ~70-row sidebar makes every query slow.
        app.launchEnvironment["DREAMAIL_DEMO_LABELS"] = "small"
        app.launchArguments += ["-accentColor", ""]
        app.launch()
        return app
    }

    /// Drags the bottom-right corner by `delta` points.
    private func dragCorner(of window: XCUIElement, by delta: CGVector) {
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
        corner.withOffset(CGVector(dx: -2, dy: -2))
            .press(forDuration: 0.2,
                   thenDragTo: corner.withOffset(
                       CGVector(dx: -2 + delta.dx, dy: -2 + delta.dy)))
    }

    func testResizedWindowReopensAtSameSize() {
        let first = launch()
        let window = first.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let original = window.frame

        // Always put the saved frame back, so later tests and later local
        // runs start from the size this one found.
        addTeardownBlock {
            let app = self.launch()
            let w = app.windows.firstMatch
            if w.waitForExistence(timeout: 10) {
                let now = w.frame
                self.dragCorner(of: w, by: CGVector(dx: original.width - now.width,
                                                    dy: original.height - now.height))
            }
            app.terminate()
        }

        dragCorner(of: window, by: CGVector(dx: -40, dy: -30))
        let after = window.frame
        XCTAssertTrue(after.width <= original.width - 20 || after.height <= original.height - 20,
                      "window did not resize: \(original) -> \(after)")
        first.terminate()

        let second = launch()
        addTeardownBlock { second.terminate() }
        let reopened = second.windows.firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 10))
        XCTAssertEqual(reopened.frame.width, after.width, accuracy: 2)
        XCTAssertEqual(reopened.frame.height, after.height, accuracy: 2)
    }
}
