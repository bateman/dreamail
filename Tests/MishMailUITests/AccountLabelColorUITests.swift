import XCTest

/// "Edit Account Labels…" offers a label color per account (system color
/// picker, organizer swatches, Default), and a pick survives Save and
/// reopening. Demo inbox only: its one account carries a "Personal" label.
final class AccountLabelColorUITests: XCTestCase {
    private let account = "you@example.com"

    func testEditorPicksSavesAndResetsTheLabelColor() {
        let app = XCUIApplication()
        app.launchEnvironment["MISHMAIL_DEMO"] = "1"
        app.launchEnvironment["MISHMAIL_UI_TEST"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-threadOpenStyle", "readingPane"]
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.activate()
        XCTAssertTrue(element(app, "threadRow.\(account):t3").waitForExistence(timeout: 10),
                      "demo inbox should load")
        // Sidebar starts collapsed; → reveals it (as in SidebarNavUITests).
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])

        openEditor(app)
        let picker = element(app, "accountLabelColorPicker.\(account)")
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "the editor has a color picker")
        let defaultButton = element(app, "accountLabelColorDefault.\(account)")
        XCTAssertTrue(defaultButton.exists)
        XCTAssertFalse(defaultButton.isEnabled, "a new account uses the default color")

        let green = element(app, "accountLabelSwatch.\(account).Green")
        XCTAssertTrue(green.exists, "the organizer swatches are offered")
        green.click()
        XCTAssertTrue(defaultButton.isEnabled, "a chosen color can be reset")
        app.buttons["Save"].click()
        XCTAssertTrue(picker.waitForNonExistence(timeout: 5), "Save closes the editor")

        openEditor(app)
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(defaultButton.isEnabled, "the chosen color was saved")
        defaultButton.click()
        XCTAssertFalse(defaultButton.isEnabled)
        app.buttons["Save"].click()
        XCTAssertTrue(picker.waitForNonExistence(timeout: 5))

        openEditor(app)
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertFalse(defaultButton.isEnabled, "the reset to default was saved")
        app.buttons["Cancel"].click()
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func openEditor(_ app: XCUIApplication) {
        let switcher = element(app, "accountSwitcher")
        XCTAssertTrue(switcher.waitForExistence(timeout: 5), "account switcher in the sidebar")
        switcher.click()
        let edit = element(app, "editAccountLabels")
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "switcher offers Edit Account Labels…")
        edit.click()
    }
}
