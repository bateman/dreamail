import XCTest

final class UnifiedInboxTests: XCTestCase {
    private let rail = ["a@example.com", "b@example.com", "c@example.com"]

    func testOnIsTheDefaultAndSurvivesAReadBack() throws {
        let suite = "unified-inbox-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(UnifiedInbox.isEnabled(defaults), "nothing stored: on, as before the setting")
        defaults.set(false, forKey: UnifiedInbox.enabledKey)
        XCTAssertFalse(UnifiedInbox.isEnabled(defaults))
        defaults.set(true, forKey: UnifiedInbox.enabledKey)
        XCTAssertTrue(UnifiedInbox.isEnabled(defaults))
    }

    func testOnLeavesTheRequestedScopeAlone() {
        XCTAssertNil(UnifiedInbox.scope(requested: nil, enabled: true, railOrder: rail))
        XCTAssertEqual(UnifiedInbox.scope(requested: "b@example.com", enabled: true, railOrder: rail),
                       "b@example.com")
    }

    func testOffTurnsTheUnifiedRequestIntoTheFirstAccountInRailOrder() {
        XCTAssertEqual(UnifiedInbox.scope(requested: nil, enabled: false, railOrder: rail),
                       "a@example.com")
        XCTAssertEqual(UnifiedInbox.scope(requested: nil, enabled: false,
                                          railOrder: ["z@example.com", "a@example.com"]),
                       "z@example.com", "rail order, not alphabetical")
        XCTAssertEqual(UnifiedInbox.scope(requested: "c@example.com", enabled: false, railOrder: rail),
                       "c@example.com", "an account request stands")
        XCTAssertNil(UnifiedInbox.scope(requested: nil, enabled: false, railOrder: []),
                     "no account at all: nothing to scope to")
    }

    func testRailEntryNeedsTheSettingAndSeveralAccounts() {
        XCTAssertTrue(UnifiedInbox.railShowsEntry(enabled: true, accountCount: 2))
        XCTAssertFalse(UnifiedInbox.railShowsEntry(enabled: true, accountCount: 1),
                       "one account: no entry, as before the setting")
        XCTAssertFalse(UnifiedInbox.railShowsEntry(enabled: true, accountCount: 0))
        XCTAssertFalse(UnifiedInbox.railShowsEntry(enabled: false, accountCount: 3))
    }

    func testSavedViewsOfAllAccountsAreHiddenOnlyWhileOff() {
        XCTAssertTrue(UnifiedInbox.savedViewVisible(accountId: nil, enabled: true))
        XCTAssertFalse(UnifiedInbox.savedViewVisible(accountId: nil, enabled: false))
        XCTAssertTrue(UnifiedInbox.savedViewVisible(accountId: "a@example.com", enabled: false))
        XCTAssertTrue(UnifiedInbox.savedViewVisible(accountId: "a@example.com", enabled: true))
    }

    func testShortcutsOn() {
        XCTAssertEqual(UnifiedInbox.shortcut(digit: 1, enabled: true, railOrder: rail), .unified)
        XCTAssertEqual(UnifiedInbox.shortcut(digit: 2, enabled: true, railOrder: rail),
                       .account("a@example.com"))
        XCTAssertEqual(UnifiedInbox.shortcut(digit: 4, enabled: true, railOrder: rail),
                       .account("c@example.com"))
        XCTAssertEqual(UnifiedInbox.shortcut(digit: 5, enabled: true, railOrder: rail), .none)
    }

    func testShortcutsOffNeverReachTheUnifiedScope() {
        for digit in 1...9 {
            XCTAssertNotEqual(UnifiedInbox.shortcut(digit: digit, enabled: false, railOrder: rail),
                              .unified, "⌘\(digit)")
        }
        XCTAssertEqual(UnifiedInbox.shortcut(digit: 1, enabled: false, railOrder: rail),
                       .account("a@example.com"))
        XCTAssertEqual(UnifiedInbox.shortcut(digit: 3, enabled: false, railOrder: rail),
                       .account("c@example.com"))
        XCTAssertEqual(UnifiedInbox.shortcut(digit: 4, enabled: false, railOrder: rail), .none)
        XCTAssertEqual(UnifiedInbox.shortcut(digit: 1, enabled: false, railOrder: []), .none)
    }

    func testTooltipDigitMatchesTheShortcut() {
        for enabled in [true, false] {
            for (index, id) in rail.enumerated() {
                let digit = UnifiedInbox.shortcutDigit(forAccountAt: index, enabled: enabled)
                XCTAssertEqual(UnifiedInbox.shortcut(digit: digit, enabled: enabled, railOrder: rail),
                               .account(id))
            }
        }
    }

    func testAnAccountThatIsGoneIsNoRequest() {
        // The demo left, or the active account was removed.
        XCTAssertNil(UnifiedInbox.scope(requested: "gone@example.com", enabled: true, railOrder: rail))
        XCTAssertEqual(UnifiedInbox.scope(requested: "gone@example.com", enabled: false, railOrder: rail),
                       "a@example.com", "off: the first account in rail order")
        XCTAssertNil(UnifiedInbox.scope(requested: "gone@example.com", enabled: false, railOrder: []),
                     "left the demo with no account yet")
        XCTAssertEqual(UnifiedInbox.scope(requested: "gone@example.com", enabled: false,
                                          railOrder: ["real@example.com"]), "real@example.com")
    }

    func testRemovingTheActiveAccountWhileOffLandsOnTheFirstRemaining() {
        let after = ["b@example.com", "c@example.com"]
        XCTAssertEqual(UnifiedInbox.scope(requested: nil, enabled: false, railOrder: after),
                       "b@example.com")
    }

    func testFirstAccountAddedWhileOffTakesTheScope() {
        XCTAssertNil(UnifiedInbox.scope(requested: nil, enabled: false, railOrder: []))
        XCTAssertEqual(UnifiedInbox.scope(requested: nil, enabled: false, railOrder: ["new@example.com"]),
                       "new@example.com")
    }

    func testOneAccountOnAndOff() {
        let one = ["a@example.com"]
        XCTAssertFalse(UnifiedInbox.railShowsEntry(enabled: true, accountCount: 1))
        XCTAssertFalse(UnifiedInbox.railShowsEntry(enabled: false, accountCount: 1))
        XCTAssertNil(UnifiedInbox.scope(requested: nil, enabled: true, railOrder: one))
        XCTAssertEqual(UnifiedInbox.scope(requested: nil, enabled: false, railOrder: one), "a@example.com")
        XCTAssertEqual(UnifiedInbox.shortcut(digit: 1, enabled: false, railOrder: one), .account("a@example.com"))
        XCTAssertEqual(UnifiedInbox.shortcut(digit: 2, enabled: true, railOrder: one), .account("a@example.com"))
    }

    func testNewViewsBelongToAnAccountWhileOff() {
        // On: as chosen (nil = all accounts).
        XCTAssertNil(UnifiedInbox.accountForNewView(requested: nil, enabled: true,
                                                    active: "b@example.com", railOrder: rail))
        // Off: the account on screen, else the first; a chosen account stands.
        XCTAssertEqual(UnifiedInbox.accountForNewView(requested: nil, enabled: false,
                                                      active: "b@example.com", railOrder: rail), "b@example.com")
        XCTAssertEqual(UnifiedInbox.accountForNewView(requested: nil, enabled: false,
                                                      active: nil, railOrder: rail), "a@example.com")
        XCTAssertEqual(UnifiedInbox.accountForNewView(requested: "c@example.com", enabled: false,
                                                      active: "b@example.com", railOrder: rail), "c@example.com")
    }

    func testHiddenSavedViewsStayInTheListAndLeaveEveryMenu() {
        var all = SavedView.empty(); all.id = 1; all.name = "Everything"
        var one = SavedView.empty(); one.id = 2; one.name = "Mine"; one.accountId = "a@example.com"
        let views = [all, one]
        XCTAssertEqual(UnifiedInbox.visible(views, accountId: \.accountId, enabled: true).map(\.name),
                       ["Everything", "Mine"])
        let shown = UnifiedInbox.visible(views, accountId: \.accountId, enabled: false)
        XCTAssertEqual(shown.map(\.name), ["Mine"])
        XCTAssertEqual(views.count, 2, "hidden, not deleted")
        // The command palette lists what the sidebar and Go menu list.
        let entries = PaletteCommands.entries(.init(
            focused: nil, savedViews: shown.map { .init(id: $0.id ?? -1, name: $0.name) }))
        XCTAssertTrue(entries.contains { $0.id == "saved.2" })
        XCTAssertFalse(entries.contains { $0.id == "saved.1" })
    }

    func testDemoSecondAccountIsDemoOwned() {
        XCTAssertTrue(DemoSeed.canActivate(accountIDs: [DemoSeed.account, DemoSeed.secondAccount]))
        XCTAssertFalse(DemoSeed.canActivate(accountIDs: [DemoSeed.secondAccount, "person@example.org"]))
    }
}
