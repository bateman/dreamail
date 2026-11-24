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

    /// Spacing between two rows of the same section: the List's row insets.
    private struct RowSpacing { let gap: CGFloat; let pitch: CGFloat }

    @discardableResult
    private func assertCompactSectionBreaks(_ app: XCUIApplication,
                                            baseline: RowSpacing? = nil,
                                            maxHeaderShare: CGFloat = 0.7,
                                            file: StaticString = #filePath,
                                            line: UInt = #line) -> RowSpacing? {
        let (rows, headers) = settledLayout(app, file: file, line: line)
        let detail = "rows \(rows.map { [$0.minX, $0.minY, $0.maxY] }); headers \(headers.map { [$0.minX, $0.minY, $0.maxY] })"
        XCTAssertGreaterThanOrEqual(rows.count, 4, "demo rows must be visible; \(detail)",
                                    file: file, line: line)
        guard rows.count >= 2 else { return nil }
        // A gap with a header in it is a section break; any other gap is
        // the List's own spacing between two rows of one section.
        var plainGaps: [CGFloat] = []
        var breaks: [(above: CGRect, below: CGRect, headers: [CGRect])] = []
        for (above, below) in zip(rows, rows.dropFirst()) {
            let inside = headers.filter { $0.midY > above.midY && $0.midY < below.midY }
            if inside.isEmpty { plainGaps.append(below.minY - above.maxY) }
            else { breaks.append((above, below, inside)) }
        }
        guard let spacing = plainGaps.min().map({ RowSpacing(gap: $0, pitch: medianRowHeight(rows) + $0) })
                ?? baseline else {
            XCTFail("no two rows of one section on screen; \(detail)", file: file, line: line)
            return nil
        }
        XCTAssertFalse(breaks.isEmpty, "expected a section break among the visible rows; \(detail)",
                       file: file, line: line)
        for (above, below, inside) in breaks {
            let gap = below.minY - above.maxY
            // One row as the eye sees it: the row's frame plus its insets.
            XCTAssertLessThan(gap, spacing.pitch,
                              "a section break must be shorter than one row (\(spacing.pitch) pt); \(detail)",
                              file: file, line: line)
            // The header band itself (break minus the normal row spacing).
            XCTAssertLessThanOrEqual(gap - spacing.gap, maxHeaderShare * spacing.pitch,
                                     "the section header must be about half a row (\(spacing.pitch) pt); \(detail)",
                                     file: file, line: line)
            // The header lies wholly in the gap: no title or pill on a row.
            for header in inside {
                XCTAssertGreaterThanOrEqual(header.minY, above.maxY - 0.5,
                                            "header overlaps the row above; \(detail)",
                                            file: file, line: line)
                XCTAssertLessThanOrEqual(header.maxY, below.minY + 0.5,
                                         "header overlaps the row below; \(detail)",
                                         file: file, line: line)
            }
        }
        return spacing
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
        // Every demo label holds one conversation, so no two rows share a
        // section there: take the row spacing from the inbox first.
        let inbox = assertCompactSectionBreaks(app)
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
        // The pill is 4 pt taller than a plain title.
        assertCompactSectionBreaks(app, baseline: inbox, maxHeaderShare: 0.8)
    }
}
