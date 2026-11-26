import XCTest

/// The Settings window: its title, the sidebar density setting (measured on
/// real rows, both ways) and the layout of Signatures → Defaults.
final class SettingsWindowUITests: XCTestCase {
    private let account = "you@example.com"

    private func launch(alias: Bool = false, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DREAMAIL_DEMO"] = "1"
        app.launchEnvironment["DREAMAIL_UI_TEST"] = "1"
        app.launchEnvironment["DREAMAIL_DEMO_LABELS"] = "small"
        if alias { app.launchEnvironment["DREAMAIL_DEMO_ALIAS"] = "1" }
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-accentColor", "",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-threadOpenStyle", "readingPane"] + extra
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.activate()
        return app
    }

    private func element(_ id: String, in app: XCUIElement) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func openSettings(_ app: XCUIApplication) -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(
            NSPredicate(format: "title CONTAINS 'Settings'")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        return settings
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return true
    }

    func testSettingsWindowIsJustCalledSettings() {
        let app = launch()
        let settings = openSettings(app)
        XCTAssertEqual(settings.title, "Settings")
        // ⌘, again reuses the one window.
        app.typeKey(",", modifierFlags: .command)
        XCTAssertEqual(app.windows.matching(NSPredicate(format: "title == 'Settings'")).count, 1)
    }

    /// Distance from one row's top to the next one's: the row's height with
    /// its spacing, whatever the frame of the label inside it.
    private func pitch(_ app: XCUIApplication, _ upper: String, _ lower: String) -> CGFloat {
        element(lower, in: app).frame.minY - element(upper, in: app).frame.minY
    }

    private func pickSidebarDensity(_ app: XCUIApplication, _ title: String) {
        let settings = openSettings(app)
        let pane = element("settings.pane.appearance", in: settings)
        XCTAssertTrue(pane.waitForExistence(timeout: 5))
        pane.click()
        let choice = settings.descendants(matching: .any).matching(identifier: "settings.sidebarDensity")
            .firstMatch.radioButtons[title]
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "Sidebar density has a \(title) choice")
        choice.click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 5), "Settings closes")
    }

    func testSidebarDensityShortensEverySidebarRowAndComfortableRestoresThem() {
        let app = launch()
        let systemUpper = "sidebar.inbox", systemLower = "sidebar.starred"
        let labelUpper = "sidebar.label.\(account).Label_work"
        let labelLower = "sidebar.label.\(account).Label_research"
        for id in [systemUpper, systemLower, labelUpper, labelLower] {
            XCTAssertTrue(element(id, in: app).waitForExistence(timeout: 10), id)
        }
        let systemBase = pitch(app, systemUpper, systemLower)
        let labelBase = pitch(app, labelUpper, labelLower)

        pickSidebarDensity(app, "Compact")
        XCTAssertTrue(waitUntil { systemBase - self.pitch(app, systemUpper, systemLower) >= 4 },
                      "compact system rows: \(systemBase) → \(pitch(app, systemUpper, systemLower)) pt")
        XCTAssertTrue(waitUntil { labelBase - self.pitch(app, labelUpper, labelLower) >= 4 },
                      "compact label rows: \(labelBase) → \(pitch(app, labelUpper, labelLower)) pt")
        print("SidebarDensity: system \(systemBase) → \(pitch(app, systemUpper, systemLower)) pt, "
              + "label \(labelBase) → \(pitch(app, labelUpper, labelLower)) pt")

        pickSidebarDensity(app, "Comfortable")
        XCTAssertTrue(waitUntil { abs(self.pitch(app, systemUpper, systemLower) - systemBase) <= 0.5 },
                      "comfortable restores the system rows")
        XCTAssertTrue(waitUntil { abs(self.pitch(app, labelUpper, labelLower) - labelBase) <= 0.5 },
                      "comfortable restores the label rows")
    }

    func testSignatureDefaultPickersAlignAcrossRows() {
        let app = launch(alias: true, extra: ["-settingsPane", "signatures"])
        let settings = openSettings(app)
        let alias = "team.alias.with.a.long.address@example.com"
        func picker(_ use: String, _ email: String) -> XCUIElement {
            element("settings.signatures.default.\(use).\(email)", in: settings)
        }
        for use in ["new", "reply"] {
            for email in [account, alias] {
                XCTAssertTrue(picker(use, email).waitForExistence(timeout: 10), "\(use) \(email)")
            }
        }
        for use in ["new", "reply"] {
            let a = picker(use, account).frame, b = picker(use, alias).frame
            XCTAssertEqual(a.minX, b.minX, accuracy: 0.5, "\(use) pickers share a left edge")
            XCTAssertEqual(a.width, b.width, accuracy: 0.5, "\(use) pickers share a width")
        }
        XCTAssertEqual(picker("new", account).frame.width, picker("reply", alias).frame.width,
                       accuracy: 0.5, "both columns use the same width")
    }
}
