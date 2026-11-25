import XCTest

@MainActor
final class KeyBindingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "KeyBindingsTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    func testDefaultLookups() {
        let kb = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb.key(for: .archive), "e")
        XCTAssertEqual(kb.key(for: .trash), "#")
        XCTAssertEqual(kb.key(for: .markSpam), "!")
        XCTAssertEqual(kb.command(for: "j"), .next)
        XCTAssertEqual(kb.command(for: "k"), .prev)
        XCTAssertEqual(kb.command(for: "!"), .markSpam)
        XCTAssertEqual(kb.command(for: "x"), .toggleCheck)
        XCTAssertNil(kb.command(for: "g"))  // reserved, never a command
    }

    func testCatalogCoversAllCommandsWithUniqueDefaults() {
        XCTAssertEqual(Set(KeyBindings.catalog.map(\.command)), Set(ShortcutCommand.allCases))
        let keys = KeyBindings.catalog.compactMap(\.defaultKey)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertTrue(Set(keys).isDisjoint(with: KeyBindings.reservedKeys))
    }

    func testRebindUpdatesBothDirectionsAndPersists() {
        let kb = KeyBindings(defaults: defaults)
        // "q" is free (x is the default multi-select toggle).
        XCTAssertEqual(kb.rebind(.archive, to: "q"), .ok)
        XCTAssertEqual(kb.key(for: .archive), "q")
        XCTAssertEqual(kb.command(for: "q"), .archive)
        XCTAssertNil(kb.command(for: "e"))  // old key freed
        // A fresh instance over the same defaults sees the override.
        let kb2 = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb2.key(for: .archive), "q")
    }

    func testConflictRefusedAndUnchanged() {
        let kb = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb.rebind(.snooze, to: "e"), .conflict(.archive))
        XCTAssertEqual(kb.key(for: .snooze), "b")
        XCTAssertEqual(kb.command(for: "e"), .archive)
    }

    func testReservedAndInvalidRejected() {
        let kb = KeyBindings(defaults: defaults)
        guard case .rejected = kb.rebind(.archive, to: "g") else { return XCTFail("g must be rejected") }
        guard case .rejected = kb.rebind(.archive, to: "?") else { return XCTFail("? must be rejected") }
        guard case .rejected = kb.rebind(.archive, to: "ab") else { return XCTFail("multi-char must be rejected") }
        guard case .rejected = kb.rebind(.archive, to: " ") else { return XCTFail("space must be rejected") }
        XCTAssertEqual(kb.key(for: .archive), "e")
    }

    /// The main-window key monitor consumes `/` (search), Return, Tab,
    /// Delete, the arrows, Home/End and the function keys before the
    /// registry is consulted. A rebind to one of them would leave the
    /// command with no working key.
    func testKeysTheMonitorNeverDeliversAreRejected() {
        let kb = KeyBindings(defaults: defaults)
        let undeliverable = ["/", "\r", "\t", "\u{3}", "\u{7F}", "\u{1B}",
                             "\u{F700}", "\u{F701}", "\u{F729}", "\u{F72B}",
                             "\u{F704}", "\u{F8FF}"]
        for key in undeliverable {
            guard case .rejected = kb.rebind(.archive, to: key) else {
                return XCTFail("\(key.unicodeScalars.map { String($0.value, radix: 16) }) must be rejected")
            }
        }
        XCTAssertEqual(kb.key(for: .archive), "e")
        XCTAssertEqual(kb.command(for: "e"), .archive)
        XCTAssertNil(kb.command(for: "/"))
    }

    /// An override stored before the rule existed must not keep the command
    /// without a key: it falls back to the catalog default on load.
    func testStoredUndeliverableOverrideFallsBackToDefault() {
        let raw = ["archive": "/", "trash": "\r", "snooze": "q"]
        defaults.set(try! JSONEncoder().encode(raw), forKey: "keyBindings")
        let kb = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb.key(for: .archive), "e")
        XCTAssertEqual(kb.key(for: .trash), "#")
        XCTAssertEqual(kb.key(for: .snooze), "q")
        XCTAssertEqual(kb.command(for: "e"), .archive)
        // The cleaned set is persisted.
        let kb2 = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb2.key(for: .archive), "e")
        let stored = try! JSONDecoder().decode(
            [String: String].self, from: defaults.data(forKey: "keyBindings")!)
        XCTAssertEqual(stored, ["snooze": "q"])
    }

    func testAliasKeyTriggersCommandUntilRebound() {
        let kb = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb.command(for: "b"), .snooze)
        XCTAssertEqual(kb.command(for: "h"), .snooze)  // built-in alias
        // A rebind to the alias key wins over the alias.
        XCTAssertEqual(kb.rebind(.archive, to: "h"), .ok)
        XCTAssertEqual(kb.command(for: "h"), .archive)
    }

    func testRebindToOwnKeyIsOk() {
        let kb = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb.rebind(.archive, to: "e"), .ok)
        XCTAssertEqual(kb.key(for: .archive), "e")
    }

    func testResetToDefaults() {
        let kb = KeyBindings(defaults: defaults)
        _ = kb.rebind(.archive, to: "q")
        kb.resetToDefaults()
        XCTAssertEqual(kb.key(for: .archive), "e")
        let kb2 = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb2.key(for: .archive), "e")
    }

    /// Ship-blocker: a pre-existing archive→x rebind must not be stolen by the
    /// toggleCheck default of x. Collision rule: the override keeps its key and
    /// the default-only command is left unbound (not moved to another key).
    func testExistingOverrideToXWinsOverNewToggleCheckDefault() {
        // Simulate prefs written before toggleCheck existed.
        let raw = ["archive": "x"]
        let data = try! JSONEncoder().encode(raw)
        defaults.set(data, forKey: "keyBindings")

        let kb = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb.command(for: "x"), .archive)
        XCTAssertEqual(kb.key(for: .archive), "x")
        XCTAssertNil(kb.key(for: .toggleCheck),
                     "the shadowed default is left unbound, not parked elsewhere")
        XCTAssertEqual(kb.displayKey(for: .toggleCheck), KeyBindings.unboundLabel)
        XCTAssertEqual(kb.defaultKeyHolder(for: .toggleCheck), .archive)
        XCTAssertNil(kb.command(for: "e"), "archive's old default is free")
        // Nothing is rewritten: the stored overrides are exactly the user's.
        let stored = try! JSONDecoder().decode(
            [String: String].self, from: defaults.data(forKey: "keyBindings")!)
        XCTAssertEqual(stored, ["archive": "x"])
        let kb2 = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb2.command(for: "x"), .archive)
        XCTAssertNil(kb2.key(for: .toggleCheck))
    }

    func testOverrideWinsOverDefaultAtLookupWithoutMigrationNeed() {
        let kb = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb.rebind(.trash, to: "q"), .ok)
        // Default snooze is still b; q is only trash.
        XCTAssertEqual(kb.command(for: "q"), .trash)
        XCTAssertEqual(kb.command(for: "b"), .snooze)
    }

    /// Caps Lock / Shift yields uppercase `charactersIgnoringModifiers` for
    /// letters; single-key actions must still resolve.
    func testLetterKeysAreCaseInsensitive() {
        let kb = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb.command(for: "O"), .open)
        XCTAssertEqual(kb.command(for: "E"), .archive)
        XCTAssertEqual(kb.rebind(.archive, to: "Q"), .ok)
        XCTAssertEqual(kb.key(for: .archive), "q")
        XCTAssertEqual(kb.command(for: "Q"), .archive)
        // Symbol keys still need their Shift form (US layout).
        XCTAssertEqual(kb.command(for: "!"), .markSpam)
        XCTAssertEqual(kb.command(for: "#"), .trash)
    }

    /// Pre-normalize rebinds could persist uppercase letters (Shift/Caps Lock
    /// during capture). Load must lowercase them so lookups and Settings agree.
    func testLegacyUppercaseOverrideIsNormalizedOnLoad() {
        let raw = ["archive": "Q"]
        let data = try! JSONEncoder().encode(raw)
        defaults.set(data, forKey: "keyBindings")

        let kb = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb.key(for: .archive), "q")
        XCTAssertEqual(kb.command(for: "q"), .archive)
        XCTAssertEqual(kb.command(for: "Q"), .archive)
        // Rewritten so the next launch doesn't re-normalize every time.
        let kb2 = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb2.key(for: .archive), "q")
    }

    // MARK: - Gmail defaults: stored overrides and collisions

    /// Overrides saved by the previous release survive unchanged. The read
    /// toggle kept its raw value, so a user who had moved it keeps that key.
    func testStoredReadToggleOverrideSurvivesTheDefaultChange() {
        let raw = ["toggleRead": "q", "archive": "y"]
        defaults.set(try! JSONEncoder().encode(raw), forKey: "keyBindings")
        let kb = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb.key(for: .toggleRead), "q")
        XCTAssertEqual(kb.command(for: "q"), .toggleRead)
        XCTAssertEqual(kb.key(for: .archive), "y")
        // The new defaults still apply where nothing collides.
        XCTAssertEqual(kb.command(for: "u"), .backToList)
        XCTAssertEqual(kb.command(for: "o"), .open)
        let stored = try! JSONDecoder().decode(
            [String: String].self, from: defaults.data(forKey: "keyBindings")!)
        XCTAssertEqual(stored, raw)
    }

    /// A user who moved the toggle off `u` and gave `u` to another command
    /// keeps that: the new `u` default (back to list) is left unbound.
    func testOverrideOnNewDefaultKeyWinsAndLeavesTheDefaultUnbound() {
        let raw = ["toggleRead": "q", "label": "u", "trash": "o"]
        defaults.set(try! JSONEncoder().encode(raw), forKey: "keyBindings")
        let kb = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb.command(for: "u"), .label)
        XCTAssertEqual(kb.command(for: "o"), .trash)
        XCTAssertNil(kb.key(for: .backToList))
        XCTAssertNil(kb.key(for: .open))
        XCTAssertEqual(kb.defaultKeyHolder(for: .backToList), .label)
        XCTAssertEqual(kb.defaultKeyHolder(for: .open), .trash)
        XCTAssertNil(kb.defaultKeyHolder(for: .archive))
        // Neither command stole the key, and none was moved to another.
        XCTAssertNil(kb.command(for: "l"), "label's old default is free")
        XCTAssertEqual(kb.overrides.count, 3)
        // Rebinding the shadowed command onto its default is a conflict…
        XCTAssertEqual(kb.rebind(.backToList, to: "u"), .conflict(.label))
        // …but once the override moves away, the default comes back.
        XCTAssertEqual(kb.rebind(.label, to: "l"), .ok)
        XCTAssertEqual(kb.key(for: .backToList), "u")
        XCTAssertEqual(kb.command(for: "u"), .backToList)
        XCTAssertNil(kb.defaultKeyHolder(for: .backToList))
    }

    /// An unbound command can be given any free key in Settings.
    func testUnboundCommandCanBeBound() {
        let raw = ["label": "u"]
        defaults.set(try! JSONEncoder().encode(raw), forKey: "keyBindings")
        let kb = KeyBindings(defaults: defaults)
        XCTAssertNil(kb.key(for: .backToList))
        XCTAssertEqual(kb.rebind(.backToList, to: "y"), .ok)
        XCTAssertEqual(kb.command(for: "y"), .backToList)
        XCTAssertEqual(kb.command(for: "u"), .label)
    }

    /// `*` became a reserved prefix. An override stored on it can no longer
    /// fire, so it is dropped and the command gets its default back.
    func testStoredOverrideOnNewlyReservedStarFallsBackToDefault() {
        let raw = ["archive": "*", "snooze": "q"]
        defaults.set(try! JSONEncoder().encode(raw), forKey: "keyBindings")
        let kb = KeyBindings(defaults: defaults)
        XCTAssertEqual(kb.key(for: .archive), "e")
        XCTAssertNil(kb.command(for: "*"))
        let stored = try! JSONDecoder().decode(
            [String: String].self, from: defaults.data(forKey: "keyBindings")!)
        XCTAssertEqual(stored, ["snooze": "q"])
    }

    func testResetRestoresGmailDefaultsAfterACollision() {
        let raw = ["label": "u"]
        defaults.set(try! JSONEncoder().encode(raw), forKey: "keyBindings")
        let kb = KeyBindings(defaults: defaults)
        kb.resetToDefaults()
        XCTAssertEqual(kb.key(for: .backToList), "u")
        XCTAssertEqual(kb.key(for: .label), "l")
        XCTAssertNil(kb.key(for: .toggleRead))
    }

    // MARK: - New defaults against stored overrides (rule of PR #17)

    /// A user who put a command on `m`, `v`, `n`, `p`, `;`, `:`, `+` or `-`
    /// before these defaults existed keeps it; the new command is left
    /// unbound, not moved, and nothing stored is rewritten.
    func testNewDefaultsNeverTakeAUserKey() {
        let raw = ["archive": "m", "trash": "v", "label": "n", "snooze": "p",
                   "reply": ";", "forward": ":", "toggleStar": "+", "compose": "-"]
        defaults.set(try! JSONEncoder().encode(raw), forKey: "keyBindings")
        let kb = KeyBindings(defaults: defaults)
        let shadowed: [(ShortcutCommand, ShortcutCommand, String)] = [
            (.mute, .archive, "m"), (.moveTo, .trash, "v"),
            (.nextMessage, .label, "n"), (.previousMessage, .snooze, "p"),
            (.expandAll, .reply, ";"), (.collapseAll, .forward, ":"),
            (.markImportant, .toggleStar, "+"), (.markNotImportant, .compose, "-"),
        ]
        for (command, holder, key) in shadowed {
            XCTAssertNil(kb.key(for: command), "\(command) must be unbound")
            XCTAssertEqual(kb.displayKey(for: command), KeyBindings.unboundLabel)
            XCTAssertEqual(kb.defaultKeyHolder(for: command), holder)
            XCTAssertEqual(kb.command(for: key), holder, "\(key) keeps firing \(holder)")
        }
        let stored = try! JSONDecoder().decode(
            [String: String].self, from: defaults.data(forKey: "keyBindings")!)
        XCTAssertEqual(stored, raw)
        // The new commands can still be bound to a free key.
        XCTAssertEqual(kb.rebind(.mute, to: "y"), .ok)
        XCTAssertEqual(kb.command(for: "y"), .mute)
    }

    func testNewDefaultsWithoutOverrides() {
        let kb = KeyBindings(defaults: defaults)
        let expected: [String: ShortcutCommand] = [
            "m": .mute, "v": .moveTo, "+": .markImportant, "-": .markNotImportant,
            "n": .nextMessage, "p": .previousMessage, ";": .expandAll, ":": .collapseAll,
        ]
        for (key, command) in expected {
            XCTAssertEqual(kb.command(for: key), command, key)
            XCTAssertEqual(kb.key(for: command), key)
        }
        // Shift+N stays the fixed refresh chord, ahead of the registry.
        XCTAssertTrue(GmailRefreshKey.matches(key: "N", shiftOnly: true))
        XCTAssertFalse(GmailRefreshKey.matches(key: "n", shiftOnly: false))
    }
}
