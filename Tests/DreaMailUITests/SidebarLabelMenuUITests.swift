import XCTest

/// The sidebar's label menu, as Gmail's (demo mailbox: `Vendors` with the
/// sublabels `Vendors/AWS` and `Vendors/Stripe`; `Research`). The demo
/// mailbox has no Gmail behind it, so the edits stay local.
final class SidebarLabelMenuUITests: XCTestCase {
    private let account = "you@example.com"

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DREAMAIL_DEMO"] = "1"
        app.launchEnvironment["DREAMAIL_UI_TEST"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-accentColor", "",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-threadOpenStyle", "readingPane",
                                "-sidebar.more.expanded", "NO",
                                // Vendors open, so its sublabels are rows.
                                "-sidebar.labels.expanded.\(account)", "(Label_vendors)",
                                "-sidebar.labels.more.\(account)", "NO"]
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

    private func label(_ gmailId: String, in app: XCUIApplication) -> XCUIElement {
        element("sidebar.label.\(account).\(gmailId)", in: app)
    }

    /// A menu item by identifier, or by title where the menu does not carry
    /// SwiftUI's identifier. The first match is the first in menu order.
    private func menuItem(_ id: String, _ title: String, in app: XCUIApplication) -> XCUIElement {
        app.menuItems.matching(NSPredicate(format: "identifier == %@ OR title == %@", id, title)).firstMatch
    }

    /// Scrolls the sidebar until `element` can be clicked: the demo has
    /// some 70 labels, so Vendors and the labels' More row start below the
    /// fold.
    @discardableResult
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let sidebar = app.outlines.firstMatch
        for step in [-300.0, 300.0] {
            var tries = 0
            while !(element.exists && element.isHittable), tries < 15 {
                sidebar.scroll(byDeltaX: 0, deltaY: step)
                tries += 1
            }
            if element.exists && element.isHittable { return true }
        }
        return element.exists && element.isHittable
    }

    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !element.exists
    }

    func testMenuOpensFromTheDotsAndFromRightClickWithGmailsItems() {
        let app = launch()
        let research = label("Label_research", in: app)
        XCTAssertTrue(research.waitForExistence(timeout: 10))
        research.hover()
        let dots = element("sidebar.label.menu.\(account).Label_research", in: app)
        XCTAssertTrue(dots.waitForExistence(timeout: 5), "hovering a label shows its ⋮")
        dots.click()
        let items: [(String, String)] = [
            ("labelMenu.color", "Label color"),
            ("labelMenu.labelList.show", "Show"),
            ("labelMenu.labelList.showIfUnread", "Show if unread"),
            ("labelMenu.labelList.hide", "Hide"),
            ("labelMenu.edit", "Edit"),
            ("labelMenu.remove", "Remove label"),
            ("labelMenu.addSublabel", "Add sublabel"),
            ("labelMenu.organize", "Organize Labels…"),
        ]
        for (id, title) in items {
            XCTAssertTrue(menuItem(id, title, in: app).waitForExistence(timeout: 5),
                          "\(title) must be in the ⋮ menu\n\(app.debugDescription)")
        }
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])

        research.rightClick()
        for (id, title) in items {
            XCTAssertTrue(menuItem(id, title, in: app).waitForExistence(timeout: 5),
                          "\(title) must be in the context menu")
        }
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    }

    /// On the open label, "⋮" opens the menu only: it must not also run
    /// the row's tap, which would reopen the label and close the open
    /// conversation.
    func testDotsOnTheOpenLabelDoNotReopenIt() {
        let app = launch()
        let research = label("Label_research", in: app)
        XCTAssertTrue(research.waitForExistence(timeout: 10))
        research.click()
        let row = element("threadRow.\(account):t2", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        let subject = app.staticTexts.matching(identifier: "threadSubject").firstMatch
        XCTAssertTrue(subject.waitForExistence(timeout: 5), "the conversation is open")

        research.hover()
        let dots = element("sidebar.label.menu.\(account).Label_research", in: app)
        XCTAssertTrue(dots.waitForExistence(timeout: 5), "the open label shows its ⋮")
        dots.click()
        XCTAssertTrue(menuItem("labelMenu.edit", "Edit", in: app).waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(subject.exists, "the ⋮ click did not reopen the label")
    }

    func testParentColorGoesToItsSublabels() {
        let app = launch()
        let vendors = label("Label_vendors", in: app)
        let aws = label("Label_vendors_aws", in: app)
        XCTAssertTrue(vendors.waitForExistence(timeout: 10))
        XCTAssertTrue(reveal(vendors, in: app), "Vendors can be scrolled to")
        XCTAssertTrue(aws.waitForExistence(timeout: 5), "Vendors starts open")

        vendors.rightClick()
        let color = menuItem("labelMenu.color", "Label color", in: app)
        XCTAssertTrue(color.waitForExistence(timeout: 5))
        color.hover()
        let choose = menuItem("labelMenu.color.choose", "Choose color…", in: app)
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        choose.click()
        let red = element("labelColor.mac.#EB5757", in: app)
        XCTAssertTrue(red.waitForExistence(timeout: 5), "the organizer's palette opens")
        red.click()
        XCTAssertTrue(waitForAbsence(red), "picking a color closes the palette")

        // The sublabel now has the same color: its palette checks it.
        XCTAssertTrue(reveal(aws, in: app))
        aws.rightClick()
        XCTAssertTrue(color.waitForExistence(timeout: 5))
        color.hover()
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        choose.click()
        XCTAssertTrue(red.waitForExistence(timeout: 5))
        XCTAssertTrue(red.isSelected, "the parent's color went to Vendors/AWS")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    }

    func testHideInLabelListMovesTheLabelUnderMore() {
        let app = launch()
        let research = label("Label_research", in: app)
        XCTAssertTrue(research.waitForExistence(timeout: 10))
        let more = element("sidebar.labels.more.\(account)", in: app)
        XCTAssertFalse(more.exists, "every demo label is shown: no labels' More row")

        research.rightClick()
        let hide = menuItem("labelMenu.labelList.hide", "Hide", in: app)
        XCTAssertTrue(hide.waitForExistence(timeout: 5))
        hide.click()

        XCTAssertTrue(waitForAbsence(research), "a hidden label leaves the list")
        XCTAssertTrue(more.waitForExistence(timeout: 5), "and goes behind the labels' More row")
        XCTAssertTrue(reveal(more, in: app), "the labels' More row can be scrolled to")
        more.click()
        XCTAssertTrue(research.waitForExistence(timeout: 5), "More shows it")
    }

    /// Remove asks first, and Cancel keeps the label.
    func testRemoveAsksAndCancelKeepsTheLabel() {
        let app = launch()
        let vendors = label("Label_vendors", in: app)
        XCTAssertTrue(vendors.waitForExistence(timeout: 10))
        XCTAssertTrue(reveal(vendors, in: app))
        vendors.rightClick()
        let remove = menuItem("labelMenu.remove", "Remove label", in: app)
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.click()
        let cancel = app.buttons.matching(NSPredicate(
            format: "identifier == %@ OR title == %@", "labelRemove.cancel", "Cancel")).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "Remove asks for confirmation")
        // Return presses the default button, Cancel.
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(waitForAbsence(cancel))
        XCTAssertTrue(vendors.exists, "Cancel keeps the label")
        XCTAssertTrue(reveal(vendors, in: app))
        XCTAssertTrue(label("Label_vendors_aws", in: app).exists)
    }
}
