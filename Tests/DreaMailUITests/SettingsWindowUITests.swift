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

    /// Height of the text drawn for `title`: the smallest element carrying
    /// that label (a row's own element can be taller than its text, and the
    /// rows' texts are not always exposed as children of the row).
    private func titleHeight(_ title: String, in app: XCUIApplication) -> CGFloat? {
        app.windows.firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", title))
            .allElementsBoundByIndex
            .map(\.frame)
            .filter { !$0.isEmpty }
            .map(\.height)
            .min()
    }

    /// "Add view" sits below the fold: scroll to it, read its text height,
    /// scroll back to the top.
    private func addViewHeight(_ app: XCUIApplication) -> CGFloat? {
        let sidebar = app.outlines.firstMatch
        var tries = 0
        while titleHeight("Add view", in: app) == nil, tries < 15 {
            sidebar.scroll(byDeltaX: 0, deltaY: -300)
            tries += 1
        }
        // The row can exist with an empty frame for a moment (the sidebar
        // lays out again): read until it has one, for up to 5 s.
        var height = titleHeight("Add view", in: app)
        let deadline = Date().addingTimeInterval(5)
        while height == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            height = titleHeight("Add view", in: app)
        }
        tries = 0
        while !element("sidebar.inbox", in: app).isHittable, tries < 15 {
            sidebar.scroll(byDeltaX: 0, deltaY: 300)
            tries += 1
        }
        return height
    }

    func testSidebarDensityShortensEverySidebarRowAndComfortableRestoresThem() {
        let app = launch(sidebar: true)
        let systemUpper = "sidebar.inbox", systemLower = "sidebar.starred"
        let labelUpper = "sidebar.label.\(account).Label_work"
        let labelLower = "sidebar.label.\(account).Label_research"
        for id in [systemUpper, systemLower, labelUpper, labelLower] {
            XCTAssertTrue(element(id, in: app).waitForExistence(timeout: 10), id)
        }
        // Fonts do not change in Compact: the text of a system row, a label
        // row and "Add view" keeps its height. (Icons and tags are not
        // exposed as elements: only a Mac shows them.)
        let titles = ["Inbox", "Work", "Research", "Add view"]
        var before = titles.dropLast().map { titleHeight($0, in: app) }
        before.append(addViewHeight(app))
        print("SidebarDensity: title heights before \(before)")
        XCTAssertFalse(before.contains { $0 == nil }, "every title is exposed: \(before)")
        let systemBase = pitch(app, systemUpper, systemLower)
        let labelBase = pitch(app, labelUpper, labelLower)

        pickSidebarDensity(app, "Compact")
        XCTAssertTrue(waitUntil { systemBase - self.pitch(app, systemUpper, systemLower) >= 4 },
                      "compact system rows: \(systemBase) → \(pitch(app, systemUpper, systemLower)) pt")
        XCTAssertTrue(waitUntil { labelBase - self.pitch(app, labelUpper, labelLower) >= 4 },
                      "compact label rows: \(labelBase) → \(pitch(app, labelUpper, labelLower)) pt")
        var after = titles.dropLast().map { titleHeight($0, in: app) }
        after.append(addViewHeight(app))
        print("SidebarDensity: title heights compact \(after)")
        for (title, (was, now)) in zip(titles, zip(before, after)) {
            guard let was, let now else { continue }
            XCTAssertEqual(now, was, accuracy: 1, "\(title): the text is \(now) pt high in Compact, \(was) before")
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

    /// Every pane fits the fixed Settings window: the sidebar (first row and
    /// the "Per account" header) is not cut on the left, and no control of the
    /// pane reaches past the right edge. Two addresses of different lengths
    /// make the Signatures defaults grid as wide as it gets.
    func testEveryPaneFitsTheSettingsWindow() {
        let app = launch(alias: true)
        let settings = openSettings(app)
        let window = settings.frame
        XCTAssertGreaterThan(window.width, 0)

        let rows = settings.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'settings.pane.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        var ids = [String]()
        for i in 0..<rows.count {
            let id = rows.element(boundBy: i).identifier
            if !ids.contains(id) { ids.append(id) }
        }
        XCTAssertGreaterThanOrEqual(ids.count, 9, "every pane has a sidebar row: \(ids)")

        for id in ids {
            let row = element(id, in: settings)
            XCTAssertTrue(row.waitForExistence(timeout: 5), id)
            row.click()
            if id == "settings.pane.signatures" {
                XCTAssertTrue(element("settings.signatures.new", in: settings).waitForExistence(timeout: 10))
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))

            // Sidebar: the first row and the section header lie inside the window.
            let first = element(ids[0], in: settings).frame
            XCTAssertGreaterThanOrEqual(first.minX, window.minX - 0.5, "\(id): first sidebar row cut on the left")
            // A sidebar section header is not always a static text: match any
            // element that carries the title, in any case.
            let header = settings.descendants(matching: .any).matching(NSPredicate(
                format: "label ==[c] 'Per account' OR title ==[c] 'Per account' OR value ==[c] 'Per account'")).firstMatch
            XCTAssertTrue(header.exists, "\(id): the 'Per account' header")
            XCTAssertGreaterThanOrEqual(header.frame.minX, window.minX - 0.5, "\(id): section header cut on the left")
            XCTAssertLessThanOrEqual(row.frame.maxX, window.maxX + 0.5, "\(id): sidebar row outside the window")

            // Pane: no control past the right edge.
            for type in [XCUIElement.ElementType.button, .popUpButton, .textField, .checkBox, .staticText] {
                let query = settings.descendants(matching: type)
                for i in 0..<min(query.count, 200) {
                    let f = query.element(boundBy: i).frame
                    guard f.width > 0, f.height > 0 else { continue }
                    XCTAssertLessThanOrEqual(f.maxX, window.maxX + 0.5,
                                             "\(id): \(type) '\(query.element(boundBy: i).label)' is cut on the right")
                    XCTAssertGreaterThanOrEqual(f.minX, window.minX - 0.5,
                                                "\(id): \(type) '\(query.element(boundBy: i).label)' is cut on the left")
                }
            }
            if id == "settings.pane.signatures" {
                let new = element("settings.signatures.new", in: settings).frame
                XCTAssertLessThanOrEqual(new.maxX, window.maxX + 0.5, "New signature is cut on the right")
            }
        }
    }
}
