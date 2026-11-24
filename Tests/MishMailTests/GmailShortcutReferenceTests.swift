import XCTest

/// Pins every default shortcut to Gmail's published list
/// (support.google.com/mail/answer/6594, keyboard shortcuts on). Changing a
/// default means editing this table on purpose.
@MainActor
final class GmailShortcutReferenceTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "GmailShortcutReferenceTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    /// Gmail key → the rebindable command MishMail ships on it. nil: the
    /// command has no Gmail key and ships unbound.
    private static let registryDefaults: [ShortcutCommand: String?] = [
        .next: "j",            // Older conversation
        .prev: "k",            // Newer conversation
        .open: "o",            // Open conversation (Enter is fixed)
        .backToList: "u",      // Back to threadlist
        .toggleCheck: "x",     // Select conversation
        .archive: "e",         // Archive
        .trash: "#",           // Delete
        .toggleStar: "s",      // Toggle star
        .snooze: "b",          // Snooze
        .markSpam: "!",        // Report as spam
        .reply: "r",           // Reply
        .replyAll: "a",        // Reply all
        .forward: "f",         // Forward
        .label: "l",           // Open "label as" menu
        .undo: "z",            // Undo last action
        .compose: "c",         // Compose
        .toggleRead: nil,      // Gmail: Shift+I / Shift+U instead
    ]

    func testEveryRegistryDefaultMatchesGmail() {
        XCTAssertEqual(Set(Self.registryDefaults.keys), Set(ShortcutCommand.allCases),
                       "every command needs a row in the reference table")
        for spec in KeyBindings.catalog {
            XCTAssertEqual(spec.defaultKey, Self.registryDefaults[spec.command] ?? nil,
                           "default for \(spec.command)")
        }
        let kb = KeyBindings(defaults: defaults)
        for (command, key) in Self.registryDefaults {
            XCTAssertEqual(kb.key(for: command), key, "effective key for \(command)")
            if let key {
                XCTAssertEqual(kb.command(for: key), command, "\(key) fires \(command)")
            }
        }
    }

    /// The old default: `u` was mark read / unread. In Gmail it is "back to
    /// threadlist", and read / unread are Shift+I / Shift+U.
    func testUIsBackToListAndReadToggleHasNoKey() {
        let kb = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb.command(for: "u"), .backToList)
        XCTAssertNil(kb.key(for: .toggleRead))
        XCTAssertEqual(kb.displayKey(for: .toggleRead), KeyBindings.unboundLabel)
        // The toggle is still a command: the user can bind it.
        XCTAssertEqual(kb.rebind(.toggleRead, to: "q"), .ok)
        XCTAssertEqual(kb.command(for: "q"), .toggleRead)
    }

    func testBuiltInAliases() {
        // `]`: Gmail's archive-and-next; archive already auto-advances.
        XCTAssertEqual(KeyBindings.aliases, ["h": .snooze, "]": .archive])
        let kb = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb.command(for: "]"), .archive)
        XCTAssertNil(kb.command(for: "["), "[ (archive and go newer) is not implemented")
    }

    func testGoToSequencesMatchGmail() {
        let table = ShortcutSequences.goTo.map { "\($0.key)=\($0.view.title)" }
        XCTAssertEqual(table, ["i=Inbox", "s=Starred", "b=Snoozed", "t=Sent",
                               "d=Drafts", "a=All Mail", "p=Promotions"])
        XCTAssertEqual(ShortcutSequences.goToTarget("b"), .snoozed)
        XCTAssertNil(ShortcutSequences.goToTarget("k"), "g k (Tasks) has no mailbox")
    }

    func testSelectSequencesMatchGmail() {
        XCTAssertEqual(ShortcutSequences.select.map(\.key), ["a", "n"])
        XCTAssertEqual(ShortcutSequences.selection("a"), .selectAll)
        XCTAssertEqual(ShortcutSequences.selection("n"), .deselectAll)
        XCTAssertNil(ShortcutSequences.selection("r"))
    }

    func testSequencePrefixesAreReservedInTheRegistry() {
        XCTAssertEqual(Set(ShortcutSequences.Prefix.allRawValues), ["g", "*"])
        for prefix in ShortcutSequences.Prefix.allRawValues {
            XCTAssertTrue(KeyBindings.reservedKeys.contains(prefix))
            let kb = KeyBindings(defaults: defaults)
            guard case .rejected = kb.rebind(.archive, to: prefix) else {
                return XCTFail("\(prefix) must be rejected")
            }
            XCTAssertNil(kb.command(for: prefix))
        }
    }

    // MARK: - Shift-modified keys

    /// Shift+I / Shift+U reach the key monitor as "I" / "U". They are the
    /// fixed mark-read / mark-unread chords, consulted before the registry,
    /// so the registry's `u` (back to list) never sees Shift+U.
    func testShiftReadChordsAreCaughtBeforeTheRegistry() {
        XCTAssertEqual(GmailMarkReadKeys.chord(key: "I", shiftOnly: true), .shiftI)
        XCTAssertEqual(GmailMarkReadKeys.chord(key: "U", shiftOnly: true), .shiftU)
        XCTAssertNil(GmailMarkReadKeys.chord(key: "u", shiftOnly: false),
                     "plain u is left to the registry")
        XCTAssertEqual(GmailMarkReadKeys.desiredRead(chord: .shiftI, anyUnread: true), true)
        XCTAssertEqual(GmailMarkReadKeys.desiredRead(chord: .shiftU, anyUnread: true), false)
    }

    /// Other Shift+letter keys are lowercased by the registry, so a held
    /// Shift or Caps Lock does not orphan them (Shift+O still opens).
    func testOtherShiftLettersFallBackToTheirPlainKey() {
        let kb = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb.command(for: "O"), .open)
        XCTAssertEqual(kb.command(for: "E"), .archive)
        // Symbols keep their Shift form: `#` and `!` are distinct keys.
        XCTAssertEqual(kb.command(for: "#"), .trash)
        XCTAssertNil(kb.command(for: "3"))
    }
}

private extension ShortcutSequences.Prefix {
    static var allRawValues: [String] { [Self.goTo.rawValue, Self.select.rawValue] }
}
