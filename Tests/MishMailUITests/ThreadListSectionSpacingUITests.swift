import XCTest

/// Regression: between two date sections of the thread list ("Today",
/// "Yesterday", …) sat an empty band about two rows tall — a 40 pt footer
/// row, then a full-height header. A section break must cost less than one
/// row: the next section's first row follows the previous section's last
/// row after only a small gap and the header line.
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

    /// Frames of the visible thread rows, top to bottom, one per thread.
    private func rowFrames(in app: XCUIApplication) -> [CGRect] {
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'threadRow.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        // Let the first layout pass settle.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let window = app.windows.firstMatch.frame
        var byId: [String: CGRect] = [:]
        for row in rows.allElementsBoundByIndex {
            let frame = row.frame
            guard !frame.isEmpty, window.contains(frame) else { continue }
            // A row may expose its identifier on nested elements: keep the
            // tallest (the row itself).
            if let kept = byId[row.identifier], kept.height >= frame.height { continue }
            byId[row.identifier] = frame
        }
        return byId.values.sorted { $0.minY < $1.minY }
    }

    private func assertCompactSectionBreaks(_ app: XCUIApplication,
                                            file: StaticString = #filePath,
                                            line: UInt = #line) {
        let frames = rowFrames(in: app)
        XCTAssertGreaterThanOrEqual(frames.count, 4, "demo inbox rows must be visible",
                                    file: file, line: line)
        guard frames.count >= 2 else { return }
        let gaps = zip(frames, frames.dropFirst()).map { $1.minY - $0.maxY }
        // Rows inside one section are separated only by the List's row
        // insets (the narrowest gap); a section break is clearly wider. The
        // demo inbox spans Priority, Today, Yesterday and older sections,
        // so at least one break is on screen.
        let rowGap = gaps.min() ?? 0
        let widest = gaps.max() ?? 0
        // One row as the eye sees it: the row's frame plus its insets.
        let rowPitch = frames.map(\.height).sorted()[frames.count / 2] + rowGap
        XCTAssertGreaterThan(widest - rowGap, 4,
                             "expected at least one section break among the visible rows; gaps \(gaps)",
                             file: file, line: line)
        XCTAssertLessThan(widest, rowPitch,
                          "a section break must be shorter than one row (\(rowPitch) pt); gaps \(gaps)",
                          file: file, line: line)
        // The header band itself (break minus the normal row spacing) is
        // about half a row.
        XCTAssertLessThanOrEqual(widest - rowGap, 0.7 * rowPitch,
                                 "the section header must be about half a row (\(rowPitch) pt); gaps \(gaps)",
                                 file: file, line: line)
    }

    func testSectionBreakIsShorterThanARowInFullWidthList() {
        assertCompactSectionBreaks(launch(readingPane: false))
    }

    func testSectionBreakIsShorterThanARowBesideTheReadingPane() {
        assertCompactSectionBreaks(launch(readingPane: true))
    }

    func testSectionBreakStaysCompactAtALargerFontScale() {
        assertCompactSectionBreaks(launch(readingPane: true, fontScale: 1.5))
    }
}
