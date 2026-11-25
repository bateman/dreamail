import XCTest

/// The Gmail-style sidebar: system views, the "More" row, and the label tree
/// (demo mailbox: `Vendors` with the sublabel `Vendors/AWS`, `Research` on
/// the unread thread t2).
final class SidebarLabelTreeUITests: XCTestCase {
    private let account = "you@example.com"

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MISHMAIL_DEMO"] = "1"
        app.launchEnvironment["MISHMAIL_UI_TEST"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-accentColor", "",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-threadOpenStyle", "readingPane",
                                // Start from Gmail's defaults: "More" closed,
                                // every parent label closed.
                                "-sidebar.more.expanded", "NO",
                                "-sidebar.categories.expanded", "NO",
                                "-sidebar.labels.expanded.\(account)", "()"]
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.activate()
        // Sidebar starts collapsed; → reveals it (see SidebarNavUITests).
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        return app
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !element.exists
    }

    func testSystemViewsAndMoreRow() {
        let app = launch()
        for id in ["inbox", "starred", "snoozed", "important", "sent", "drafts",
                   "allMail", "trash"] {
            XCTAssertTrue(element("sidebar.\(id)", in: app).waitForExistence(timeout: 5),
                          "sidebar.\(id) must be listed")
        }
        // The single all-labels view is no longer a sidebar row.
        XCTAssertFalse(element("sidebar.labels", in: app).exists)
        let spam = element("sidebar.spam", in: app)
        XCTAssertFalse(spam.exists, "Spam sits behind a closed More row")
        let more = element("sidebar.more", in: app)
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.click()
        XCTAssertTrue(spam.waitForExistence(timeout: 5), "More opens Spam")
        XCTAssertTrue(element("sidebar.reminders", in: app).exists)
        XCTAssertTrue(element("sidebar.categories", in: app).exists)
        more.click()
        XCTAssertTrue(waitForAbsence(spam), "Less closes it again")
    }

    func testLabelRowOpensItsView() {
        let app = launch()
        let unlabelled = element("threadRow.\(account):t3", in: app)
        XCTAssertTrue(unlabelled.waitForExistence(timeout: 10))
        let research = element("sidebar.label.\(account).Label_research", in: app)
        XCTAssertTrue(research.waitForExistence(timeout: 5))
        research.click()
        XCTAssertTrue(waitForAbsence(unlabelled),
                      "the Research view must not list an unlabelled thread")
        XCTAssertTrue(element("threadRow.\(account):t2", in: app).waitForExistence(timeout: 5),
                      "the Research view lists its thread")
    }

    func testParentLabelCollapsesItsSublabels() {
        let app = launch()
        let parent = element("sidebar.label.\(account).Label_vendors", in: app)
        XCTAssertTrue(parent.waitForExistence(timeout: 5))
        let child = element("sidebar.label.\(account).Label_vendors_aws", in: app)
        XCTAssertFalse(child.exists, "parents start closed, as in Gmail")
        // The disclosure triangle of the parent's outline row.
        let row = app.outlineRows.containing(.any, identifier: parent.identifier).firstMatch
        let triangle = row.disclosureTriangles.firstMatch
        XCTAssertTrue(triangle.waitForExistence(timeout: 5),
                      "a parent label has a disclosure triangle\n\(app.debugDescription)")
        triangle.click()
        XCTAssertTrue(child.waitForExistence(timeout: 5), "opening the parent shows AWS")
        triangle.click()
        XCTAssertTrue(waitForAbsence(child), "closing it hides AWS again")
    }

    func testClosedCategoriesHidesTheOpenCategory() {
        let app = launch()
        let more = element("sidebar.more", in: app)
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.click()
        let categories = element("sidebar.categories", in: app)
        XCTAssertTrue(categories.waitForExistence(timeout: 5))
        let row = app.outlineRows.containing(.any, identifier: categories.identifier).firstMatch
        let triangle = row.disclosureTriangles.firstMatch
        XCTAssertTrue(triangle.waitForExistence(timeout: 5),
                      "Categories has a disclosure triangle\n\(app.debugDescription)")
        let promotions = element("sidebar.promotions", in: app)
        XCTAssertFalse(promotions.exists, "Categories starts closed")
        triangle.click()
        XCTAssertTrue(promotions.waitForExistence(timeout: 5), "open Categories lists Promotions")
        promotions.click()
        triangle.click()
        XCTAssertTrue(waitForAbsence(promotions),
                      "a closed Categories hides the open category too")
        XCTAssertFalse(element("sidebar.social", in: app).exists)
        // Closing "More" must not bring it back.
        let spam = element("sidebar.spam", in: app)
        more.click()
        XCTAssertTrue(waitForAbsence(spam), "More is closed")
        XCTAssertFalse(promotions.exists)
        more.click()
        XCTAssertTrue(categories.waitForExistence(timeout: 5))
        triangle.click()
        XCTAssertTrue(promotions.waitForExistence(timeout: 5),
                      "reopening Categories shows Promotions again")
    }
}
