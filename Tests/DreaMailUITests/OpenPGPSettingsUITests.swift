import XCTest

/// OpenPGP (step 4B) is off in the tracked build configuration: Settings
/// has no OpenPGP pane, and a pane remembered from a build with it on
/// opens something else, so nothing of it can be reached.
final class OpenPGPSettingsUITests: XCTestCase {

    func testSettingsHaveNoOpenPGPPaneWithTheSwitchOff() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DREAMAIL_DEMO"] = "1"
        app.launchEnvironment["DREAMAIL_UI_TEST"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                // As if a build with OpenPGP on had left it open.
                                "-settingsPane", "openPGP"]
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }
        let main = app.windows.matching(
            NSPredicate(format: "NOT (title CONTAINS 'Settings')")).firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 10))
        app.activate()

        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(
            NSPredicate(format: "title CONTAINS 'Settings'")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        // The per-account section is there…
        XCTAssertTrue(settings.descendants(matching: .any)
            .matching(identifier: "settings.pane.signatures").firstMatch.waitForExistence(timeout: 5))
        // …without the OpenPGP row or pane.
        XCTAssertFalse(settings.descendants(matching: .any)
            .matching(identifier: "settings.pane.openPGP").firstMatch.exists)
        XCTAssertFalse(settings.staticTexts["OpenPGP keys"].exists)
        XCTAssertFalse(settings.buttons["Import public key…"].exists)
    }
}
