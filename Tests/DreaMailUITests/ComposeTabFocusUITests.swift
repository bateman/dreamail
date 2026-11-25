import XCTest

/// Regression: Tab from the To field must land keyboard focus on the Subject
/// field, and typed text must go there — in both the autocomplete-suggestion
/// and the plain-address case.
///
/// 2026-08-04: typing a recipient, pressing Tab, then typing the subject
/// intermittently left the subject unfocused (or the text landed back in the
/// To field). Two coupled causes: Tab-with-suggestions accepted the pick but
/// swallowed the traversal, and the blur-side commitDraft mutated the token
/// row mid-traversal.
final class ComposeTabFocusUITests: XCTestCase {
    private func launchDemo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DREAMAIL_DEMO"] = "1"
        app.launchEnvironment["DREAMAIL_UI_TEST"] = "1"
        // The short label list: a ~70-row sidebar makes every query slow.
        app.launchEnvironment["DREAMAIL_DEMO_LABELS"] = "small"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                // A saved accent must not change what this suite sees.
                                "-accentColor", "",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-readingPaneHidden", "NO"]
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.activate()
        return app
    }

    private func openCompose(_ app: XCUIApplication) -> (to: XCUIElement, subject: XCUIElement) {
        // Let the thread list settle, then `c` for new mail.
        let demoThread = app.descendants(matching: .any)
            .matching(identifier: "threadRow.you@example.com:t1").firstMatch
        XCTAssertTrue(demoThread.waitForExistence(timeout: 10))
        app.typeKey("c", modifierFlags: [])

        let compose = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier IN {'composeCard', 'composeInline'}")).firstMatch
        XCTAssertTrue(compose.waitForExistence(timeout: 5))

        let to = app.textFields.matching(identifier: "addressField.To").firstMatch
        XCTAssertTrue(to.waitForExistence(timeout: 5))
        let subject = app.textFields.matching(
            NSPredicate(format: "placeholderValue == 'Subject' OR identifier == 'composeSubject'")).firstMatch
        XCTAssertTrue(subject.waitForExistence(timeout: 5))

        // The To field auto-focuses ~0.1s after mount; wait for it.
        XCTAssertTrue(waitForKeyboardFocus(to, timeout: 5),
                      "To field should auto-focus on new compose")
        return (to, subject)
    }

    private func hasKeyboardFocus(_ element: XCUIElement) -> Bool {
        (element.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }

    private func waitForKeyboardFocus(_ element: XCUIElement,
                                      timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if hasKeyboardFocus(element) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return hasKeyboardFocus(element)
    }

    /// Wait out the 1.5s autosave debounce plus slack, then confirm the
    /// subject still holds focus and its text — the reported glitch was a
    /// delayed "unselect" shortly after typing began.
    private func assertSubjectKeepsFocusAndText(_ subject: XCUIElement,
                                                expected: String) {
        XCTAssertEqual(subject.value as? String, expected,
                       "typed text should land in the subject")
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertTrue(hasKeyboardFocus(subject),
                      "subject must keep keyboard focus after autosave settles")
        XCTAssertEqual(subject.value as? String, expected)
    }

    /// One launch for the four checks. Each opens a new compose with `c`;
    /// Esc then saves and closes it (a first Esc may only close the contact
    /// suggestions), so the next starts from the mailbox again.
    func testRecipientFocusAndTab() {
        let app = launchDemo()
        let steps: [(String, (XCUIApplication) -> Void)] = [
            ("Tab with a suggestion accepts and moves to Subject", stepTabWithSuggestionAcceptsAndMovesToSubject),
            ("Tab with a plain address moves to Subject", stepTabWithPlainAddressMovesToSubject),
            ("Comma-committed recipients keep To focused", stepCommaCommittedRecipientsKeepToFocused),
            ("A clicked suggestion returns focus to the recipient draft", stepClickedSuggestionReturnsFocusToRecipientDraft),
        ]
        for (name, step) in steps {
            XCTContext.runActivity(named: name) { _ in step(app) }
            closeCompose(app, after: name)
        }
    }

    private func closeCompose(_ app: XCUIApplication, after step: String) {
        let compose = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier IN {'composeCard', 'composeInline'}")).firstMatch
        for _ in 0..<3 where compose.exists {
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            _ = compose.waitForNonExistence(timeout: 2)
        }
        XCTAssertFalse(compose.exists, "Esc closes the compose after: \(step)")
    }

    /// Tab while the contact autocomplete is showing: accept the pick AND
    /// move to the subject (Gmail behavior).
    private func stepTabWithSuggestionAcceptsAndMovesToSubject(_ app: XCUIApplication) {
        let (to, subject) = openCompose(app)

        to.typeText("dana")   // matches dana@brightloop.io in the demo seed
        app.typeKey("\t", modifierFlags: [])

        XCTAssertTrue(waitForKeyboardFocus(subject, timeout: 3),
                      "Tab should move keyboard focus to the subject")

        app.typeText("Hello there")
        assertSubjectKeepsFocusAndText(subject, expected: "Hello there")
        // The pick became a chip; the To draft must not contain subject text.
        XCTAssertEqual(to.value as? String ?? "", "")
    }

    /// Tab with a plain typed address (no matching contact): commit the chip
    /// and land on the subject without dropping focus.
    private func stepTabWithPlainAddressMovesToSubject(_ app: XCUIApplication) {
        let (to, subject) = openCompose(app)

        to.typeText("nobody-matches-this@example.net")
        app.typeKey("\t", modifierFlags: [])

        XCTAssertTrue(waitForKeyboardFocus(subject, timeout: 3),
                      "Tab should move keyboard focus to the subject")

        app.typeText("Quarterly plan")
        assertSubjectKeepsFocusAndText(subject, expected: "Quarterly plan")
        XCTAssertEqual(to.value as? String ?? "", "")
    }

    /// Committing one recipient must leave the insertion point in To so the
    /// next address can be typed immediately. This is the normal multi-address
    /// flow: type an address, comma, then continue with the next address.
    private func stepCommaCommittedRecipientsKeepToFocused(_ app: XCUIApplication) {
        let (to, _) = openCompose(app)

        for address in ["first@example.net", "second@example.net", "third@example.net"] {
            app.typeText(address + ",")
            XCTAssertTrue(waitForKeyboardFocus(to, timeout: 1),
                          "To should keep keyboard focus after committing \(address)")
            XCTAssertEqual(to.value as? String ?? "", "",
                           "the committed address should become a chip")
        }

        app.typeText("next@example.net")
        XCTAssertTrue(hasKeyboardFocus(to))
        XCTAssertEqual(to.value as? String, "next@example.net",
                       "typing should continue naturally after several chips")
    }

    /// A mouse-picked autocomplete suggestion should behave like Return: it
    /// commits the chip and leaves To ready for the next recipient.
    private func stepClickedSuggestionReturnsFocusToRecipientDraft(_ app: XCUIApplication) {
        let (to, _) = openCompose(app)

        app.typeText("dana")
        // SwiftUI hands the enclosing card's accessibilityIdentifier down to
        // the floating suggestion rows, so the row's own identifier never
        // reaches the AX tree (it reads "composeCard"). Match the label too.
        let suggestion = app.buttons.matching(NSPredicate(
            format: "identifier == 'addressSuggestion.To.dana@brightloop.io' "
                + "OR label CONTAINS 'dana@brightloop.io'")).firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 10),
                      "recipient suggestion should appear once contacts are mined")
        suggestion.click()

        XCTAssertTrue(waitForKeyboardFocus(to, timeout: 2),
                      "To should regain focus after clicking a suggestion")
        app.typeText("next@example.net")
        XCTAssertEqual(to.value as? String, "next@example.net")
    }
}
