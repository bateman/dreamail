import XCTest

/// Gmail's "Label as…" picker: Return applies the highlighted label and
/// closes in one keystroke (and only closes once a box was changed in this
/// opening); Space and clicks toggle without closing; Esc closes with every
/// pick applied. Demo inbox only: it has the labels Work, Research, Travel,
/// Family and Friends, each the only match for its own name.
final class LabelPickerUITests: XCTestCase {
    private let thread = "you@example.com:t3"
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["DREAMAIL_DEMO"] = "1"
        app.launchEnvironment["DREAMAIL_UI_TEST"] = "1"
        // No DREAMAIL_DEMO_LABELS=small: the picker's filtering needs the
        // demo's full, long label list.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-accentColor", "",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-threadOpenStyle", "readingPane"]
        app.terminate()
        app.launch()
        addTeardownBlock { [app] in app?.terminate() }
        XCTAssertTrue(app.windows.firstMatch.appears(timeout: 10))
        app.activate()
        let row = element("threadRow.\(thread)")
        XCTAssertTrue(row.appears(timeout: 10), "demo inbox should load")
        row.click()
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private var search: XCUIElement { element("labelPicker.search") }
    private func row(_ name: String) -> XCUIElement { element("labelPicker.row.\(name)") }

    private func wait(_ element: XCUIElement, value: String, _ message: String,
                      file: StaticString = #filePath, line: UInt = #line) {
        let done = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: 5), .completed, message,
                       file: file, line: line)
    }

    private func value(_ name: String) -> String { (row(name).value as? String) ?? "" }

    /// Opens the picker and types a filter that leaves one row, so the
    /// highlight is on it whatever the pointer does.
    private func openPicker(filter: String? = nil) {
        app.typeKey("l", modifierFlags: [])
        XCTAssertTrue(search.appears(timeout: 5), "the picker opens")
        if let filter {
            app.typeText(filter)
            XCTAssertTrue(row(filter).appears(timeout: 5), "filtered to \(filter)")
        }
    }

    private func close() { app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: []) }

    private func flipped(_ v: String) -> String { v == "on" ? "off" : "on" }

    /// One launch for the four checks: each works on its own labels
    /// (Family, Travel, Friends, then Work and Research) and reads its
    /// "before" state itself, so none depends on another's outcome. Each
    /// ends with the picker open on its check; Esc closes it before the next.
    func testReturnSpaceClicksAndEsc() {
        let steps: [(String, () -> Void)] = [
            ("Return applies and closes", stepReturnAppliesAndCloses),
            ("Return after Space keeps the label on", stepReturnAfterSpaceKeepsTheLabelOn),
            ("Return after a click keeps the label on", stepReturnAfterAClickKeepsTheLabelOn),
            ("Clicks keep the picker open, Esc closes with both applied",
             stepClicksKeepThePickerOpenAndEscClosesWithBothApplied),
        ]
        for (name, step) in steps {
            XCTContext.runActivity(named: name) { _ in step() }
            close()
            XCTAssertTrue(search.waitForNonExistence(timeout: 5), "Esc closes the picker after: \(name)")
        }
    }

    private func stepReturnAppliesAndCloses() {
        openPicker(filter: "Family")
        let before = value("Family")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5), "Return closes the picker")
        openPicker(filter: "Family")
        wait(row("Family"), value: flipped(before), "Return toggled the highlighted label")
    }

    private func stepReturnAfterSpaceKeepsTheLabelOn() {
        openPicker(filter: "Travel")
        let before = value("Travel")
        // Arrows mark the list as navigated, so Space toggles instead of typing.
        app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: [])
        app.typeKey(" ", modifierFlags: [])
        wait(row("Travel"), value: flipped(before), "Space toggled without closing")
        XCTAssertTrue(search.exists, "Space keeps the picker open")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5), "Return closes")
        openPicker(filter: "Travel")
        wait(row("Travel"), value: flipped(before), "Return after Space did not undo the pick")
    }

    private func stepReturnAfterAClickKeepsTheLabelOn() {
        openPicker(filter: "Friends")
        let before = value("Friends")
        row("Friends").click()
        wait(row("Friends"), value: flipped(before), "the click toggled the label")
        XCTAssertTrue(search.exists, "clicking keeps the picker open")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5), "Return closes")
        openPicker(filter: "Friends")
        wait(row("Friends"), value: flipped(before), "Return after a click did not undo it")
    }

    private func stepClicksKeepThePickerOpenAndEscClosesWithBothApplied() {
        openPicker()
        XCTAssertTrue(row("Work").appears(timeout: 5))
        let work = value("Work"), research = value("Research")
        row("Work").click()
        wait(row("Work"), value: flipped(work), "first click toggled")
        row("Research").click()
        wait(row("Research"), value: flipped(research), "second click toggled")
        XCTAssertTrue(search.exists, "clicking keeps the picker open")
        close()
        XCTAssertTrue(search.waitForNonExistence(timeout: 5), "Esc closes")
        openPicker()
        wait(row("Work"), value: flipped(work), "first pick stayed applied")
        wait(row("Research"), value: flipped(research), "second pick stayed applied")
    }
}
