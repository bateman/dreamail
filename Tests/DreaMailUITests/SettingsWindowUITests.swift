import XCTest

/// The Settings window: its title, the sidebar density setting (measured on
/// real rows, both ways) and the layout of Signatures → Defaults.
final class SettingsWindowUITests: XCTestCase {
    private let account = "you@example.com"

    private func launch(alias: Bool = false, sidebar: Bool = false, extra: [String] = []) -> XCUIApplication {
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
        // The sidebar starts collapsed; → reveals it (see SidebarNavUITests).
        if sidebar { app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: []) }
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
        // Another pane, close, reopen: still "Settings" (a pane change or a
        // reopen must not bring the system's title back).
        let pane = element("settings.pane.appearance", in: settings)
        XCTAssertTrue(pane.waitForExistence(timeout: 5))
        pane.click()
        XCTAssertEqual(settings.title, "Settings")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 5), "Settings closes")
        let again = openSettings(app)
        XCTAssertEqual(again.title, "Settings")
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

    /// Sizes of what a row draws, in order: its texts (title and count) and
    /// its images (icon, tag). Compact must leave them as they are.
    private func glyphSizes(_ id: String, in app: XCUIApplication) -> [CGSize] {
        let row = element(id, in: app)
        return (row.staticTexts.allElementsBoundByIndex + row.images.allElementsBoundByIndex)
            .map { CGSize(width: $0.frame.width.rounded(), height: $0.frame.height.rounded()) }
    }

    func testSidebarDensityShortensEverySidebarRowAndComfortableRestoresThem() {
        let app = launch(sidebar: true)
        let systemUpper = "sidebar.inbox", systemLower = "sidebar.starred"
        let labelUpper = "sidebar.label.\(account).Label_work"
        let labelLower = "sidebar.label.\(account).Label_research"
        for id in [systemUpper, systemLower, labelUpper, labelLower] {
            XCTAssertTrue(element(id, in: app).waitForExistence(timeout: 10), id)
        }
        let addView = app.buttons["Add view"]
        XCTAssertTrue(addView.waitForExistence(timeout: 10))
        let measured = [systemUpper, labelUpper, labelLower]
        let before = measured.map { glyphSizes($0, in: app) }
        let addViewBefore = (addView.staticTexts.allElementsBoundByIndex + addView.images.allElementsBoundByIndex)
            .map { CGSize(width: $0.frame.width.rounded(), height: $0.frame.height.rounded()) }
        XCTAssertFalse(before[0].isEmpty, "the Inbox row exposes its title: \(before)")
        XCTAssertFalse(addViewBefore.isEmpty, "Add view exposes its text and glyph")
        print("SidebarDensity: glyph sizes before \(before), Add view \(addViewBefore)")
        let systemBase = pitch(app, systemUpper, systemLower)
        let labelBase = pitch(app, labelUpper, labelLower)

        pickSidebarDensity(app, "Compact")
        XCTAssertTrue(waitUntil { systemBase - self.pitch(app, systemUpper, systemLower) >= 4 },
                      "compact system rows: \(systemBase) → \(pitch(app, systemUpper, systemLower)) pt")
        XCTAssertTrue(waitUntil { labelBase - self.pitch(app, labelUpper, labelLower) >= 4 },
                      "compact label rows: \(labelBase) → \(pitch(app, labelUpper, labelLower)) pt")
        // Fonts and icons do not change in Compact (±0.5 pt, rounded above).
        for (id, was) in zip(measured, before) {
            let now = glyphSizes(id, in: app)
            XCTAssertEqual(now.count, was.count, "\(id): the same texts and images")
            for (a, b) in zip(now, was) {
                XCTAssertEqual(a.height, b.height, accuracy: 1, "\(id): \(now) vs \(was)")
                XCTAssertEqual(a.width, b.width, accuracy: 1, "\(id): \(now) vs \(was)")
            }
        }
        let addViewNow = (addView.staticTexts.allElementsBoundByIndex + addView.images.allElementsBoundByIndex)
            .map { CGSize(width: $0.frame.width.rounded(), height: $0.frame.height.rounded()) }
        XCTAssertEqual(addViewNow.count, addViewBefore.count)
        for (a, b) in zip(addViewNow, addViewBefore) {
            XCTAssertEqual(a.height, b.height, accuracy: 1, "Add view: \(addViewNow) vs \(addViewBefore)")
            XCTAssertEqual(a.width, b.width, accuracy: 1, "Add view: \(addViewNow) vs \(addViewBefore)")
        }
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
