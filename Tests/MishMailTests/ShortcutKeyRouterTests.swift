import XCTest

/// The mailbox key path below the window's key monitor: `MailStore.handleKey`
/// performs whatever `ShortcutKeyRouter` returns, using the real registry.
@MainActor
final class ShortcutKeyRouterTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "ShortcutKeyRouterTests"
    private var bindings: KeyBindings!
    private var router = ShortcutKeyRouter()
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        bindings = KeyBindings(defaults: defaults)
        router = ShortcutKeyRouter()
    }

    private func press(_ chars: String, after seconds: TimeInterval = 0)
        -> ShortcutKeyRouter.Route {
        let kb = bindings!
        return router.route(chars, now: t0.addingTimeInterval(seconds),
                            command: { kb.command(for: $0) })
    }

    func testPlainKeysRunTheirCommands() {
        XCTAssertEqual(press("e"), .command(.archive))
        XCTAssertEqual(press("u"), .command(.backToList))
        XCTAssertEqual(press("?"), .help)
        // `n` became Gmail's next message; `q` has no command.
        XCTAssertEqual(press("n"), .command(.nextMessage))
        XCTAssertEqual(press("q"), .unhandled)
    }

    func testGoToSequences() {
        XCTAssertEqual(press("g"), .armed(.goTo))
        XCTAssertTrue(router.hasPendingPrefix(now: t0))
        XCTAssertEqual(press("i", after: 0.3), .goTo(.inbox))
        XCTAssertFalse(router.hasPendingPrefix(now: t0.addingTimeInterval(0.3)))
        XCTAssertEqual(press("g", after: 1), .armed(.goTo))
        XCTAssertEqual(press("l", after: 1.2), .goTo(.labels))
    }

    /// Review finding: `*` needs Shift on US layouts, so the second key often
    /// arrives uppercase. `* A` used to miss the table and run Reply all.
    func testSecondKeyIsMatchedCaseInsensitively() {
        XCTAssertEqual(press("*"), .armed(.select))
        XCTAssertEqual(press("A", after: 0.2), .select(.selectAll))
        XCTAssertEqual(press("*", after: 1), .armed(.select))
        XCTAssertEqual(press("U", after: 1.1), .select(.unread))
        // Caps Lock on the prefix itself.
        XCTAssertEqual(press("G", after: 2), .armed(.goTo))
        XCTAssertEqual(press("I", after: 2.1), .goTo(.inbox))
    }

    /// Review finding: an unknown key after a prefix used to fall through
    /// and run as a shortcut (`* r` replied, `g l` opened the label picker,
    /// `g c` composed). It is now swallowed, and the key after it is normal.
    func testUnknownSecondKeyIsSwallowedNotRun() {
        for (prefix, key) in [("*", "e"), ("*", "x"), ("*", "#"),
                              ("g", "c"), ("g", "k"), ("g", "e"), ("g", "#")] {
            router = ShortcutKeyRouter()
            XCTAssertEqual(press(prefix), .armed(prefix == "g" ? .goTo : .select))
            XCTAssertEqual(press(key, after: 0.1), .swallowed, "\(prefix) \(key)")
            XCTAssertEqual(press("e", after: 0.2), .command(.archive),
                           "the prefix is spent after one key")
        }
        // `* r` / `* u` / `* s` are selections now, not reply / back / star.
        router = ShortcutKeyRouter()
        XCTAssertEqual(press("*"), .armed(.select))
        XCTAssertEqual(press("r", after: 0.1), .select(.read))
    }

    func testPrefixExpiresAfterTheTimeout() {
        XCTAssertEqual(press("g"), .armed(.goTo))
        let late = ShortcutSequences.timeout + 0.1
        XCTAssertFalse(router.hasPendingPrefix(now: t0.addingTimeInterval(late)))
        XCTAssertEqual(press("e", after: late), .command(.archive))
    }

    func testPrefixAfterPrefixRearms() {
        XCTAssertEqual(press("g"), .armed(.goTo))
        XCTAssertEqual(press("*", after: 0.1), .swallowed,
                       "`g *` is not a sequence; the * is eaten too")
        XCTAssertEqual(press("a", after: 0.2), .command(.replyAll))
    }

    func testReboundKeysRouteThroughTheRegistry() {
        XCTAssertEqual(bindings.rebind(.archive, to: "y"), .ok)
        XCTAssertEqual(press("y"), .command(.archive))
        XCTAssertEqual(press("e"), .unhandled)
    }
}

/// Gmail `[` / `]`: archive, then the previous (newer) or next (older) row.
final class ArchiveDirectionTests: XCTestCase {
    func testDefaultAdvanceGoesDownThenUp() {
        XCTAssertEqual(SelectionAdvance.neighborId(in: ["a", "b", "c"], removing: ["b"],
                                                   focus: "b"), "c")
        XCTAssertEqual(SelectionAdvance.neighborId(in: ["a", "b", "c"], removing: ["c"],
                                                   focus: "c"), "b")
    }

    func testPreferPreviousGoesUpThenDown() {
        XCTAssertEqual(SelectionAdvance.neighborId(in: ["a", "b", "c"], removing: ["b"],
                                                   focus: "b", preferPrevious: true), "a")
        XCTAssertEqual(SelectionAdvance.neighborId(in: ["a", "b", "c"], removing: ["a"],
                                                   focus: "a", preferPrevious: true), "b")
        XCTAssertNil(SelectionAdvance.neighborId(in: ["a"], removing: ["a"],
                                                 focus: "a", preferPrevious: true))
    }

    func testDestinationsCarryTheDirection() {
        let d = SelectionAdvance.destinations(in: ["a", "b", "c"], removing: ["b"],
                                              selected: "b", opened: "b",
                                              preferPrevious: true)
        XCTAssertEqual(d.selectedId, "a")
        XCTAssertEqual(d.openedId, "a")
    }

    /// `[` / `]` act on an open conversation only, never on the list.
    func testOnlyAnOpenConversationIsArchived() {
        XCTAssertTrue(BackToList.conversationOnScreen(layoutMode: .threadFocus, openedThread: true))
        XCTAssertTrue(BackToList.conversationOnScreen(layoutMode: .threePane, openedThread: true))
        XCTAssertTrue(BackToList.conversationOnScreen(layoutMode: .compactDetail, openedThread: true))
        XCTAssertFalse(BackToList.conversationOnScreen(layoutMode: .list, openedThread: true),
                       "full-window style on the list: the old opened id must not be archived")
        XCTAssertFalse(BackToList.conversationOnScreen(layoutMode: .threePane, openedThread: false))
    }
}
