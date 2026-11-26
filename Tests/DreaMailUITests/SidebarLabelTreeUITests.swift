import XCTest

/// The Gmail-style sidebar: system views, the "More" row, and the label tree
/// (demo mailbox: `Vendors` with the sublabel `Vendors/AWS`, `Research` on
/// the unread thread t2).
final class SidebarLabelTreeUITests: XCTestCase {
    private let account = "you@example.com"

    /// `tiny`: the shortest demo label list, 11 labels, a user with few
    /// labels. Without it the full, long list.
    /// `systemOrder`: a stored order of the system views, as the argument
    /// value (`(inbox,more,...)`); without it the default order.
    private func launch(tiny: Bool = false, systemOrder: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DREAMAIL_DEMO"] = "1"
        app.launchEnvironment["DREAMAIL_UI_TEST"] = "1"
        if tiny { app.launchEnvironment["DREAMAIL_DEMO_LABELS"] = "tiny" }
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-accentColor", "",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-threadOpenStyle", "readingPane",
                                // Start from Gmail's defaults: "More" closed,
                                // every parent label closed.
                                "-sidebar.more.expanded", "NO",
                                "-sidebar.labels.expanded.\(account)", "()"]
        if let systemOrder { app.launchArguments += ["-sidebar.system.order.\(account)", systemOrder] }
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

    /// The parent label on the 11-label list that failed in CI without a
    /// scroll (runs 45695638539 and 45699532362): one launch, one step (the
    /// others run on the full list).
    func testParentLabelOnTheShortList() {
        let app = launch(tiny: true)
        XCTContext.runActivity(named: "A parent label collapses its sublabels") { _ in
            stepParentLabelCollapsesItsSublabels(app)
        }
    }

    /// Scrolls the sidebar until `element` can be clicked. On a short list
    /// the Vendors row sits at the bottom edge of the window: it exists, but
    /// its frame is empty and a click on its triangle lands outside the
    /// visible list (CI logs, November 2026), so the click did nothing.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let sidebar = app.outlines.firstMatch
        for step in [-300.0, 300.0] {
            var tries = 0
            while !(element.exists && element.isHittable), tries < 15 {
                sidebar.scroll(byDeltaX: 0, deltaY: step)
                tries += 1
            }
            if element.exists && element.isHittable { return }
        }
    }

    /// One launch for the four checks, in an order where each finds the
    /// state it starts from: the sidebar scrolled to its top for the three
    /// that use rows near it (More, Research), the inbox still listed for
    /// the label view, and the parent label last: Vendors sits below the
    /// fold of the full demo list, so reaching it scrolls More out of view.
    func testSidebarTree() {
        let app = launch()
        let steps: [(String, (XCUIApplication) -> Void)] = [
            ("System views and the More row", stepSystemViewsAndMoreRow),
            ("A label row opens its view", stepLabelRowOpensItsView),
            ("A closed More lists nothing under it", stepClosedMoreHidesEverythingUnderIt),
            ("A parent label collapses its sublabels", stepParentLabelCollapsesItsSublabels),
        ]
        for (name, step) in steps {
            XCTContext.runActivity(named: name) { _ in step(app) }
        }
    }

    private func stepSystemViewsAndMoreRow(_ app: XCUIApplication) {
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
        // The categories are plain rows above Spam, with no "Categories" group.
        XCTAssertFalse(element("sidebar.categories", in: app).exists)
        let promotions = element("sidebar.promotions", in: app)
        let social = element("sidebar.social", in: app)
        XCTAssertTrue(promotions.exists && social.exists, "More lists Promotions and Social")
        XCTAssertLessThan(promotions.frame.minY, social.frame.minY)
        XCTAssertLessThan(social.frame.minY, spam.frame.minY, "the categories sit above Spam")
        more.click()
        XCTAssertTrue(waitForAbsence(spam), "Less closes it again")
    }

    private func stepLabelRowOpensItsView(_ app: XCUIApplication) {
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

    private func stepParentLabelCollapsesItsSublabels(_ app: XCUIApplication) {
        let parent = element("sidebar.label.\(account).Label_vendors", in: app)
        XCTAssertTrue(parent.waitForExistence(timeout: 5))
        let child = element("sidebar.label.\(account).Label_vendors_aws", in: app)
        XCTAssertFalse(child.exists, "parents start closed, as in Gmail")
        // The disclosure triangle of the parent's outline row.
        let row = app.outlineRows.containing(.any, identifier: parent.identifier).firstMatch
        let triangle = row.disclosureTriangles.firstMatch
        XCTAssertTrue(triangle.waitForExistence(timeout: 5),
                      "a parent label has a disclosure triangle\n\(app.debugDescription)")
        reveal(parent, in: app)
        XCTAssertTrue(triangle.isHittable, "the parent's triangle is on screen")
        triangle.click()
        XCTAssertTrue(child.waitForExistence(timeout: 5), "opening the parent shows AWS")
        triangle.click()
        XCTAssertTrue(waitForAbsence(child), "closing it hides AWS again")
    }

    /// A closed More hides everything under it, the open view included: the
    /// view stays open, the sidebar just has no row for it. `g p` opens
    /// Promotions with More closed and still lists nothing.
    private func stepClosedMoreHidesEverythingUnderIt(_ app: XCUIApplication) {
        let more = element("sidebar.more", in: app)
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.click()
        let promotions = element("sidebar.promotions", in: app)
        XCTAssertTrue(promotions.waitForExistence(timeout: 5), "More lists Promotions")
        XCTAssertFalse(element("sidebar.categories", in: app).exists, "no Categories row")
        promotions.click()
        more.click()
        let social = element("sidebar.social", in: app)
        let spam = element("sidebar.spam", in: app)
        XCTAssertTrue(waitForAbsence(promotions), "Less hides the open category too")
        XCTAssertTrue(waitForAbsence(social), "Less hides the other categories")
        XCTAssertTrue(waitForAbsence(spam), "Less hides Spam")
        // `g i` leaves it, `g p` opens it again with More closed: still not listed.
        app.typeKey("g", modifierFlags: [])
        app.typeKey("i", modifierFlags: [])
        app.typeKey("g", modifierFlags: [])
        app.typeKey("p", modifierFlags: [])
        XCTAssertTrue(waitForAbsence(promotions),
                      "g p lists no Promotions row under a closed More")
        XCTAssertTrue(more.exists, "the More row stays")
    }

    /// A stored order puts Promotions above Drafts, out of More; the other
    /// rows of More stay behind it. (The drag itself is not driven: it is
    /// flaky in XCUITest; the logic is `SidebarSystemOrderTests`.)
    func testStoredSystemOrderIsApplied() {
        let app = launch(systemOrder: "(inbox,starred,snoozed,important,sent,promotions,"
            + "drafts,allMail,trash,outbox,more,scheduled,reminders,social,spam)")
        let promotions = element("sidebar.promotions", in: app)
        let drafts = element("sidebar.drafts", in: app)
        XCTAssertTrue(promotions.waitForExistence(timeout: 10),
                      "Promotions is listed with More closed")
        XCTAssertTrue(drafts.exists)
        XCTAssertLessThan(promotions.frame.minY, drafts.frame.minY, "Promotions sits above Drafts")
        XCTAssertFalse(element("sidebar.social", in: app).exists, "Social stays under More")
        let more = element("sidebar.more", in: app)
        XCTAssertTrue(more.exists)
        more.click()
        XCTAssertTrue(element("sidebar.social", in: app).waitForExistence(timeout: 5))
        XCTAssertLessThan(drafts.frame.minY, more.frame.minY)
        XCTAssertLessThan(promotions.frame.minY, more.frame.minY, "Promotions is not under More")
    }
}
