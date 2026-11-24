import XCTest

/// Regression: between two sections of the thread list ("Today",
/// "Yesterday", …) sat an empty band about two rows tall — a 40 pt footer
/// row, then a full-height header. A section break must cost less than one
/// row, and the header must sit inside the break: never on a row.
final class ThreadListSectionSpacingUITests: XCTestCase {
    private func launch(readingPane: Bool, fontScale: Double = 1.0) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MISHMAIL_DEMO"] = "1"
        app.launchEnvironment["MISHMAIL_UI_TEST"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-readingPaneHidden", readingPane ? "NO" : "YES",
                                "-threadOpenStyle", "readingPane",
                                "-groupBy", "date",
                                "-fontScale", String(fontScale)]
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.activate()
        return app
    }

    /// Frames of every element whose identifier starts with `prefix`, inside
    /// the window, top to bottom. An identifier can sit on nested elements
    /// too: a frame inside another frame with the same identifier is dropped.
    /// The same thread can appear in two sections (Labels view), so frames
    /// are not merged by identifier.
    private func frames(_ prefix: String, in app: XCUIApplication) -> [CGRect] {
        let window = app.windows.firstMatch.frame
        let all = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .allElementsBoundByIndex
            .map { ($0.identifier, $0.frame) }
            .filter { !$0.1.isEmpty && window.contains($0.1) }
        let outer = all.filter { id, frame in
            !all.contains { $0.0 == id && $0.1 != frame && $0.1.contains(frame) }
        }
        var seen: [CGRect] = []
        for (_, frame) in outer where !seen.contains(frame) { seen.append(frame) }
        return seen.sorted { $0.minY < $1.minY }
    }

    /// Row and header frames once the layout has settled: two consecutive
    /// reads agree.
    private func settledLayout(_ app: XCUIApplication,
                               file: StaticString = #filePath,
                               line: UInt = #line) -> (rows: [CGRect], headers: [CGRect]) {
        let first = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'threadRow.'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10), file: file, line: line)
        var last = (rows: frames("threadRow.", in: app),
                    headers: frames("threadSectionHeader.", in: app))
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            let now = (rows: frames("threadRow.", in: app),
                       headers: frames("threadSectionHeader.", in: app))
            if now.rows == last.rows, now.headers == last.headers, !now.rows.isEmpty {
                return now
            }
            last = now
        }
        XCTFail("the thread list layout did not settle", file: file, line: line)
        return last
    }

    private func medianRowHeight(_ rows: [CGRect]) -> CGFloat {
        rows.isEmpty ? 0 : rows.map(\.height).sorted()[rows.count / 2]
    }

    private func assertCompactSectionBreaks(_ app: XCUIApplication,
                                            checkAlignment: Bool = true,
                                            file: StaticString = #filePath,
                                            line: UInt = #line) {
        let (rows, headers) = settledLayout(app, file: file, line: line)
        XCTAssertGreaterThanOrEqual(rows.count, 4, "demo rows must be visible",
                                    file: file, line: line)
        guard rows.count >= 2 else { return }
        let gaps = zip(rows, rows.dropFirst()).map { $1.minY - $0.maxY }
        // Rows inside one section are separated only by the List's row
        // insets (the narrowest gap); a section break is clearly wider.
        let rowGap = gaps.min() ?? 0
        let widest = gaps.max() ?? 0
        // One row as the eye sees it: the row's frame plus its insets.
        let rowPitch = medianRowHeight(rows) + rowGap
        let detail = "rows \(rows.map { [$0.minY, $0.maxY] }); headers \(headers.map { [$0.minX, $0.minY, $0.maxY] })"
        XCTAssertGreaterThan(widest - rowGap, 4,
                             "expected a section break among the visible rows; \(detail)",
                             file: file, line: line)
        XCTAssertLessThan(widest, rowPitch,
                          "a section break must be shorter than one row (\(rowPitch) pt); \(detail)",
                          file: file, line: line)
        XCTAssertLessThanOrEqual(widest - rowGap, 0.7 * rowPitch,
                                 "the section header must be about half a row (\(rowPitch) pt); \(detail)",
                                 file: file, line: line)

        // Every header between two rows lies wholly in the gap between them:
        // no title or pill drawn over a row.
        var checked = 0
        for header in headers {
            guard let above = rows.last(where: { $0.midY < header.midY }),
                  let below = rows.first(where: { $0.midY > header.midY }) else { continue }
            checked += 1
            XCTAssertGreaterThanOrEqual(header.minY, above.maxY - 0.5,
                                        "header overlaps the row above; \(detail)",
                                        file: file, line: line)
            XCTAssertLessThanOrEqual(header.maxY, below.minY + 0.5,
                                     "header overlaps the row below; \(detail)",
                                     file: file, line: line)
        }
        XCTAssertGreaterThan(checked, 0, "expected a header between two rows; \(detail)",
                             file: file, line: line)
        // The header text starts where the row content starts.
        if checkAlignment, let header = headers.first, let row = rows.first {
            XCTAssertEqual(header.minX, row.minX, accuracy: 3,
                           "header text must align with the rows; \(detail)",
                           file: file, line: line)
        }
    }

    func testSectionBreakIsShorterThanARowInFullWidthList() {
        assertCompactSectionBreaks(launch(readingPane: false))
    }

    func testSectionBreakIsShorterThanARowBesideTheReadingPane() {
        assertCompactSectionBreaks(launch(readingPane: true))
    }

    func testSectionBreakStaysCompactAtALargerFontScale() {
        let base = medianRowHeight(settledLayout(launch(readingPane: true)).rows)
        let app = launch(readingPane: true, fontScale: 1.6)
        let scaled = medianRowHeight(settledLayout(app).rows)
        // The setting must take effect, or this test checks scale 1 twice.
        XCTAssertGreaterThan(scaled, 1.15 * base,
                             "font scale 1.6 did not reach the list (rows \(base) → \(scaled) pt)")
        assertCompactSectionBreaks(app)
    }

    /// Labels view: each header is the label's coloured pill, taller than a
    /// plain title. It must fit the break too.
    func testLabelPillHeadersFitTheBreak() {
        let app = launch(readingPane: true)
        let anyRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'threadRow.'")).firstMatch
        XCTAssertTrue(anyRow.waitForExistence(timeout: 10))
        // Sidebar starts collapsed; → reveals it (see SidebarNavUITests).
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        let labels = app.descendants(matching: .any)
            .matching(identifier: "sidebar.labels").firstMatch
        XCTAssertTrue(labels.waitForExistence(timeout: 5))
        labels.click()
        // A header that is not one of the inbox's date sections.
        let inboxSections = ["Priority", "Today", "Yesterday", "Last 7 days",
                             "Last 30 days", "Older"].map { "threadSectionHeader.\($0)" }
        let pill = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'threadSectionHeader.' AND NOT (identifier IN %@)",
                                  inboxSections)).firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "Labels view must show section headers")
        // The pill's capsule starts left of its text: alignment is checked
        // in the date views only.
        assertCompactSectionBreaks(app, checkAlignment: false)
    }
}
