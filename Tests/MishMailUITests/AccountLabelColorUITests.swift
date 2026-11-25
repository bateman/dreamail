import XCTest

/// "Edit Account Labels…" offers a label color per account (system color
/// picker, organizer swatches, Default) with a preview of the ringed
/// avatar, always enabled, and a pick survives Save and reopening. The
/// switcher shows the label as the account's title. Demo inbox only: its
/// one account carries a "Personal" label and sends as "Alex Rivera".
final class AccountLabelColorUITests: XCTestCase {
    private let account = "you@example.com"

    func testEditorPicksSavesAndResetsTheLabelColor() {
        let app = XCUIApplication()
        app.launchEnvironment["MISHMAIL_DEMO"] = "1"
        app.launchEnvironment["MISHMAIL_UI_TEST"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                // A saved accent must not change what this suite sees.
                                "-accentColor", "",
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

        // Choose the account: the switcher header's title is its label.
        let switcher = element(app, "accountSwitcher")
        XCTAssertTrue(switcher.waitForExistence(timeout: 5), "account switcher in the sidebar")
        switcher.click()
        let row = inPopover(app, "Personal")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the account row is in the switcher")
        row.click()
        XCTAssertTrue(app.popovers.firstMatch.waitForNonExistence(timeout: 5),
                      "choosing an account closes the switcher")
        XCTAssertTrue(switcher.label.contains("Personal"),
                      "the header's title is the label: \(switcher.label)")
        XCTAssertFalse(switcher.label.contains("Alex Rivera"),
                       "the header does not show the sender name: \(switcher.label)")

        openEditor(app) {
            // The switcher row's title is the label, not the sender name.
            XCTAssertTrue(self.inPopover(app, "Personal").waitForExistence(timeout: 5),
                          "the account row is titled with its label")
            XCTAssertFalse(self.inPopover(app, "Alex Rivera").exists,
                           "the sender name is not shown in the switcher")
        }
        let picker = element(app, "accountLabelColorPicker.\(account)")
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "the editor has a color picker")
        XCTAssertTrue(element(app, "accountLabelColorPreview.\(account)").exists,
                      "the color row previews the ringed avatar")
        XCTAssertTrue(picker.isEnabled)
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
        // Without "Send as" the color still shows (as the ring), so the
        // color row stays enabled. Cancel keeps the demo's sender name.
        let sendAs = element(app, "accountSenderName.\(account)")
        XCTAssertTrue(sendAs.exists, "the editor has the Send as field")
        sendAs.click()
        sendAs.typeKey("a", modifierFlags: .command)
        sendAs.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        XCTAssertTrue(picker.isEnabled, "the color row is enabled without a sender name")
        XCTAssertTrue(green.isEnabled, "the swatches are enabled without a sender name")
        green.click()
        XCTAssertTrue(defaultButton.isEnabled)
        app.buttons["Cancel"].click()
        XCTAssertTrue(picker.waitForNonExistence(timeout: 5))
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Any element in the switcher popover whose label mentions `text`.
    private func inPopover(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.popovers.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
    }

    /// Opens the switcher popover, runs `inPopover` while it is open, then
    /// chooses "Edit Account Labels…".
    private func openEditor(_ app: XCUIApplication, inPopover: () -> Void = {}) {
        let switcher = element(app, "accountSwitcher")
        XCTAssertTrue(switcher.waitForExistence(timeout: 5), "account switcher in the sidebar")
        switcher.click()
        inPopover()
        let edit = element(app, "editAccountLabels")
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "switcher offers Edit Account Labels…")
        edit.click()
    }
}
