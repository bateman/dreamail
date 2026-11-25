import XCTest

/// Settings → Appearance → "Opening a conversation": a new install opens
/// conversations in a reading pane (Gmail's layout); a stored choice wins.
final class ThreadOpenStyleDefaultTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "ThreadOpenStyleDefaultTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testDefaultIsReadingPane() {
        XCTAssertEqual(ThreadOpenStyle.defaultStyle, .readingPane)
    }

    func testNoStoredChoiceUsesTheReadingPane() {
        XCTAssertNil(defaults.string(forKey: ThreadOpenStyle.storageKey))
        XCTAssertEqual(ThreadOpenStyle.resolved(storedRaw: defaults.string(forKey: ThreadOpenStyle.storageKey)), .readingPane)
        XCTAssertEqual(ThreadOpenStyle.resolved(storedRaw: nil), .readingPane)
    }

    func testStoredChoiceIsRespected() {
        for style in ThreadOpenStyle.allCases {
            defaults.set(style.rawValue, forKey: ThreadOpenStyle.storageKey)
            XCTAssertEqual(ThreadOpenStyle.resolved(storedRaw: defaults.string(forKey: ThreadOpenStyle.storageKey)), style)
        }
    }

    func testUnknownStoredValueFallsBackToTheDefault() {
        defaults.set("someFutureStyle", forKey: ThreadOpenStyle.storageKey)
        XCTAssertEqual(ThreadOpenStyle.resolved(storedRaw: defaults.string(forKey: ThreadOpenStyle.storageKey)), .readingPane)
    }

    /// The first window must be wide enough for the default to show as three
    /// panes; at the old 1000 pt it swapped list and conversation instead.
    func testFirstLaunchWindowShowsThreePanesWithTheDefault() {
        XCTAssertGreaterThanOrEqual(MailLayout.defaultWindowWidth,
                                    MailLayout.threePaneMinimumWidth)
        let fullWindow = ThreadOpenStyle.resolved(storedRaw: nil) != .readingPane
        XCTAssertEqual(MailLayout.mode(width: MailLayout.defaultWindowWidth,
                                       readingPaneHidden: false,
                                       hasSelection: true,
                                       fullWindowThreads: fullWindow),
                       .threePane)
    }
}
