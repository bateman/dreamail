import XCTest

/// Gmail's "Label as…" picker: Return applies the highlighted label and
/// closes in one keystroke; clicking checkboxes toggles without closing and
/// Esc closes with every pick applied. Demo inbox only.
final class LabelPickerUITests: XCTestCase {
    private let thread = "you@example.com:t3"
    private let rowPrefix = "labelPicker.row."

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func search(_ app: XCUIApplication) -> XCUIElement {
        element(app, "labelPicker.search")
    }

    /// The picker's label rows, top to bottom.
    private func rows(_ app: XCUIApplication) -> [XCUIElement] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", rowPrefix))
            .allElementsBoundByIndex
            .sorted { $0.frame.minY < $1.frame.minY }
    }

    private func openPicker(_ app: XCUIApplication) {
        app.typeKey("l", modifierFlags: [])
        XCTAssertTrue(search(app).waitForExistence(timeout: 5), "the picker opens")
        XCTAssertTrue(rows(app).count >= 3, "the picker lists labels")
    }

    func testReturnAppliesAndClosesButClicksKeepItOpenUntilEsc() {
        let app = XCUIApplication()
        app.launchEnvironment["MISHMAIL_DEMO"] = "1"
        app.launchEnvironment["MISHMAIL_UI_TEST"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-accentColor", "",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-threadOpenStyle", "readingPane"]
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.activate()
        let row = element(app, "threadRow.\(thread)")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "demo inbox should load")
        row.click()

        // Return: arrow to the second label, apply, picker closed.
        openPicker(app)
        let secondName = rows(app)[1].label
        let before = rows(app)[1].value as? String
        app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(search(app).waitForNonExistence(timeout: 5),
                      "Return closes the picker")

        openPicker(app)
        let after = rows(app).first { $0.label == secondName }?.value as? String
        XCTAssertNotEqual(before, after, "Return toggled the highlighted label")

        // Clicks toggle without closing; Esc closes with both applied.
        let first = rows(app)[0], third = rows(app)[2]
        let firstBefore = first.value as? String, thirdBefore = third.value as? String
        first.click()
        third.click()
        XCTAssertTrue(search(app).exists, "clicking keeps the picker open")
        XCTAssertNotEqual(firstBefore, rows(app)[0].value as? String)
        XCTAssertNotEqual(thirdBefore, rows(app)[2].value as? String)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(search(app).waitForNonExistence(timeout: 5), "Esc closes")

        openPicker(app)
        XCTAssertNotEqual(firstBefore, rows(app)[0].value as? String, "first pick stayed applied")
        XCTAssertNotEqual(thirdBefore, rows(app)[2].value as? String, "second pick stayed applied")
    }
}
