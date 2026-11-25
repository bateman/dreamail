import XCTest

/// The conversation view lays messages out as flat rows (Gmail on the web):
/// collapsed rows of one height, about 80 pt, split by a hairline rather
/// than by card spacing, and opening a row keeps its header in place.
/// Demo t2 is a four-message conversation; its newest message opens
/// expanded, the three before it are collapsed.
final class ThreadMessageRowsUITests: XCTestCase {
    private func launchReadingPane() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DREAMAIL_DEMO"] = "1"
        app.launchEnvironment["DREAMAIL_UI_TEST"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                // A saved accent must not change what this suite sees.
                                "-accentColor", "",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-readingPaneHidden", "NO",
                                "-threadOpenStyle", "readingPane",
                                "-fontScale", "1.0"]
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.activate()
        return app
    }

    private func frames(_ identifier: String, in app: XCUIApplication) -> [CGRect] {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .allElementsBoundByIndex
            .map(\.frame)
            .filter { !$0.isEmpty }
            .sorted { $0.minY < $1.minY }
    }

    /// Frames once the layout has settled (two consecutive reads agree)
    /// and `ready` holds.
    private func settled(_ identifier: String, in app: XCUIApplication,
                         until ready: ([CGRect]) -> Bool,
                         file: StaticString = #filePath,
                         line: UInt = #line) -> [CGRect] {
        var last = frames(identifier, in: app)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            let now = frames(identifier, in: app)
            if now == last, ready(now) { return now }
            last = now
        }
        XCTFail("\(identifier) did not settle: \(last)", file: file, line: line)
        return last
    }

    private func readingPane(_ app: XCUIApplication) -> XCUIElement {
        app.scrollViews.containing(
            NSPredicate(format: "identifier == 'threadSubject'")).firstMatch
    }

    private func openConversation(_ app: XCUIApplication) {
        let row = app.descendants(matching: .any)
            .matching(identifier: "threadRow.you@example.com:t2").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        let subject = app.staticTexts.matching(identifier: "threadSubject").firstMatch
        XCTAssertTrue(subject.waitForExistence(timeout: 5))
        _ = settled("messageRowFrame", in: app) { $0.count == 4 }
        // The pane anchors the newest message at its top; bring the older
        // rows into view.
        let pane = readingPane(app)
        if pane.exists { pane.scroll(byDeltaX: 0, deltaY: 2000) }
    }

    /// Clicks the window at a point given in screen coordinates.
    private func click(_ app: XCUIApplication, x: CGFloat, y: CGFloat) {
        let window = app.windows.firstMatch
        let origin = window.frame.origin
        window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: x - origin.x, dy: y - origin.y))
            .click()
    }

    /// Opening the conversation scrolls its newest message to the top of
    /// the pane: the whole row must be visible, with its top padding, not
    /// clipped by the pane's edge.
    func testNewestRowOpensUnclippedAtThePaneTop() {
        let app = launchReadingPane()
        let row = app.descendants(matching: .any)
            .matching(identifier: "threadRow.you@example.com:t2").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        let rows = settled("messageRowFrame", in: app) { $0.count == 4 }
        guard rows.count == 4 else { return }
        let pane = readingPane(app)
        XCTAssertTrue(pane.exists)
        let senders = settled("messageSender", in: app) { $0.count == 4 }
        guard let newestName = senders.last else { return }
        let paneTop = pane.frame.minY
        print("ThreadMessageRows: pane top \(paneTop), newest row top \(rows[3].minY), its name top \(newestName.minY)")
        XCTAssertGreaterThanOrEqual(rows[3].minY, paneTop - 0.5,
                                    "the newest row must not start above the pane")
        // Name top = avatar top (both sit at the row's 20 pt top padding).
        XCTAssertGreaterThanOrEqual(newestName.minY - paneTop, 18,
                                    "the newest row's header must keep its top padding")
    }

    func testClickNearTheTopEdgeOfACollapsedRowOpensIt() {
        let app = launchReadingPane()
        openConversation(app)
        let rows = settled("messageRowFrame", in: app) { $0.count == 4 }
        guard rows.count == 4 else { return }
        let target = rows[1]
        click(app, x: target.midX, y: target.minY + 3)
        let after = settled("messageRowFrame", in: app) {
            $0.count == 4 && $0[1].height > target.height + 40
        }
        XCTAssertGreaterThan(after.count == 4 ? after[1].height : 0, target.height + 40,
                             "a click on the row's top edge must open it")
    }

    func testCollapsedRowsAreEvenAndSplitByAHairline() {
        let app = launchReadingPane()
        openConversation(app)

        let rows = settled("messageRowFrame", in: app) { $0.count == 4 }
        guard rows.count == 4 else { return }
        let dates = frames("messageHeaderDate", in: app)
        let detail = "rows \(rows.map { [$0.minY, $0.maxY] }); dates \(dates.map(\.minY))"
        let collapsed = Array(rows.prefix(3))
        let heights = collapsed.map(\.height)
        let gaps = zip(rows, rows.dropFirst()).map { $1.minY - $0.maxY }
        let pitches = zip(dates, dates.dropFirst()).map { $1.minY - $0.minY }
        // Numbers for the reviewer, in the test log.
        print("ThreadMessageRows: collapsed heights \(heights), gaps \(gaps), date pitch \(pitches)")

        XCTAssertLessThanOrEqual(heights.max()! - heights.min()!, 1,
                                 "collapsed rows must share one height; \(detail)")
        for h in heights {
            XCTAssertEqual(h, 80, accuracy: 8, "a collapsed row is about 80 pt; \(detail)")
        }
        // The hairline alone: no card spacing between rows.
        for gap in gaps {
            XCTAssertGreaterThanOrEqual(gap, -0.5, "rows must not overlap; \(detail)")
            XCTAssertLessThanOrEqual(gap, 2, "rows are split by a hairline only; \(detail)")
        }
        XCTAssertLessThanOrEqual(gaps.max()! - gaps.min()!, 0.5,
                                 "the hairline is the same between every two rows; \(detail)")
        // The open newest message is taller than a collapsed row.
        XCTAssertGreaterThan(rows[3].height, heights.max()! + 40, detail)
    }

    func testOpeningARowKeepsItsHeaderInPlace() {
        let app = launchReadingPane()
        openConversation(app)

        let rows = settled("messageRowFrame", in: app) { $0.count == 4 }
        guard rows.count == 4 else { return }
        let senders = frames("messageSender", in: app)
        XCTAssertFalse(senders.isEmpty, "the header names must be exposed")
        guard let nameBefore = senders.first else { return }

        // The first (collapsed) row's button: the whole header.
        let open = app.buttons.matching(identifier: "messageRowExpand")
            .allElementsBoundByIndex
            .min { $0.frame.minY < $1.frame.minY }
        XCTAssertNotNil(open, "a collapsed row must be a button")
        open?.click()

        // Open: the first row grows to its body, the newest collapses.
        let after = settled("messageRowFrame", in: app) {
            $0.count == 4 && $0[0].height > rows[0].height + 40
        }
        let nameAfter = frames("messageSender", in: app).first ?? .zero
        print("ThreadMessageRows: name top before \(nameBefore.minY), after \(nameAfter.minY); first row \(rows[0].height) -> \(after.first?.height ?? 0)")
        XCTAssertEqual(nameAfter.minY, nameBefore.minY, accuracy: 1,
                       "opening a message must not move its header")
        XCTAssertEqual(after.first?.minY ?? 0, rows[0].minY, accuracy: 1,
                       "the row itself stays where it was")
    }
}
