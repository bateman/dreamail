import XCTest

/// Baseline measurement of the conversation view on demo t2 (four messages):
/// prints the collapsed messages' pitch. Replaced by the layout assertions.
final class ThreadMessageRowsUITests: XCTestCase {
    func testMeasureCollapsedMessages() {
        let app = XCUIApplication()
        app.launchEnvironment["MISHMAIL_DEMO"] = "1"
        app.launchEnvironment["MISHMAIL_UI_TEST"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-readingPaneHidden", "NO",
                                "-threadOpenStyle", "readingPane",
                                "-fontScale", "1.0"]
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.activate()
        let row = app.descendants(matching: .any)
            .matching(identifier: "threadRow.you@example.com:t2").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        let dates = app.descendants(matching: .any).matching(identifier: "messageHeaderDate")
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, dates.count < 4 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let ys = dates.allElementsBoundByIndex.map(\.frame).sorted { $0.minY < $1.minY }
        let pitches = zip(ys, ys.dropFirst()).map { $1.minY - $0.minY }
        print("ThreadMessageRows BEFORE: date frames \(ys), pitch \(pitches)")
        XCTAssertEqual(ys.count, 4)
    }
}
