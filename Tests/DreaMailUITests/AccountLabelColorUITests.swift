import XCTest

/// "Edit Account Labels…" offers a label color per account (system color
/// picker, organizer swatches, Default) with a preview of the ringed
/// avatar, always enabled, and a pick survives Save and reopening. The
/// rail names the account avatar by its label. Demo inbox only: its
/// one account carries a "Personal" label and sends as "Alex Rivera".
final class AccountLabelColorUITests: XCTestCase {
    private let account = "you@example.com"

    func testEditorPicksSavesAndResetsTheLabelColor() {
        let app = XCUIApplication()
        app.launchEnvironment["DREAMAIL_DEMO"] = "1"
        app.launchEnvironment["DREAMAIL_UI_TEST"] = "1"
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
        // Choose the account in the rail (always visible): its tooltip and
        // VoiceOver name is the label, not the sender name.
        let avatar = element(app, "accountRail.account.\(account)")
        XCTAssertTrue(avatar.waitForExistence(timeout: 5), "account avatar in the rail")
        avatar.click()
        XCTAssertTrue(avatar.label.contains("Personal"),
                      "the avatar's name is the label: \(avatar.label)")
        XCTAssertFalse(avatar.label.contains("Alex Rivera"),
                       "the avatar does not show the sender name: \(avatar.label)")

        openEditor(app)
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

    /// Opens "Edit Account Labels…" from the account avatar's context menu.
    private func openEditor(_ app: XCUIApplication) {
        let avatar = element(app, "accountRail.account.\(account)")
        XCTAssertTrue(avatar.waitForExistence(timeout: 5), "account avatar in the rail")
        avatar.rightClick()
        let edit = app.menuItems["Edit Account Labels…"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "context menu offers Edit Account Labels…")
        edit.click()
    }
}
