import AppKit
import XCTest

/// The compose signature menu, as in Gmail (Manage signatures, No
/// signature, each signature by name), a Gmail signature shown once and
/// rendered (with "Edit signature as text"), and Settings → Signatures
/// without a manual import. The demo account's Gmail signature arrives by itself at
/// launch (`DemoSeed.gmailSignatures`, no network); "Short" is made in the app.
final class SignatureMenuUITests: XCTestCase {
    private let gmailName = "you@example.com"
    private let gmailText = "Example Studio"
    private let shortText = "Alex · Example Studio"

    private func launchDemo(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DREAMAIL_DEMO"] = "1"
        app.launchEnvironment["DREAMAIL_UI_TEST"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-accentColor", "",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-readingPaneHidden", "NO"] + extra
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.activate()
        return app
    }

    private func body(_ app: XCUIApplication) -> String {
        let byId = app.textViews.matching(identifier: "compose.body").firstMatch
        let view = byId.exists ? byId : app.textViews.firstMatch
        return view.value as? String ?? ""
    }

    private func waitForBody(_ app: XCUIApplication, timeout: TimeInterval = 5,
                             _ condition: (String) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition(body(app)) { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition(body(app))
    }

    /// Opens the menu once the Gmail signature has arrived (the launch
    /// refresh runs in the background).
    private func openMenu(_ app: XCUIApplication) {
        let button = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == 'compose.signature' OR label == 'Insert signature'")).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        let deadline = Date().addingTimeInterval(15)
        repeat {
            button.click()
            if app.menuItems[gmailName].waitForExistence(timeout: 2) { return }
            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        } while Date() < deadline
        XCTFail("the Gmail signature should be in the menu")
    }

    func testComposeMenuSwapsRemovesAndManagesSignatures() {
        let app = launchDemo()
        let thread = app.descendants(matching: .any)
            .matching(identifier: "threadRow.you@example.com:t1").firstMatch
        XCTAssertTrue(thread.waitForExistence(timeout: 10))
        app.typeKey("c", modifierFlags: [])
        let compose = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier IN {'composeCard', 'composeInline'}")).firstMatch
        XCTAssertTrue(compose.waitForExistence(timeout: 5))

        // Gmail's order: Manage signatures, then No signature and each one.
        openMenu(app)
        XCTAssertTrue(app.menuItems["Manage signatures"].exists)
        XCTAssertTrue(app.menuItems["No signature"].exists)
        XCTAssertTrue(app.menuItems["Short"].exists)

        app.menuItems["Short"].click()
        XCTAssertTrue(waitForBody(app) { $0.contains(self.shortText) },
                      "choosing a signature puts it in the body")
        // A signature made here is text only: nothing rendered under it.
        let block = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == 'compose.richSignature' OR label == 'Signature'")).firstMatch
        XCTAssertFalse(block.exists, "a text signature has no rendered block")

        // "Edit signature as text" only while a rendered signature is shown.
        openMenu(app)
        XCTAssertFalse(app.menuItems["Edit signature as text"].exists)
        app.menuItems[gmailName].click()
        // The Gmail signature is shown once, rendered, and not in the text.
        XCTAssertTrue(block.waitForExistence(timeout: 5),
                      "a Gmail signature is shown as it is sent")
        XCTAssertTrue(waitForBody(app) {
            !$0.contains("Alex Rivera") && !$0.contains(self.shortText) && !$0.contains("-- ")
        }, "choosing the Gmail signature replaces the first, outside the editor text")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == 'compose.signaturePreview' OR label CONTAINS 'signature as sent'"))
            .firstMatch.exists, "no second copy labelled as sent")

        // Edit signature as text: the text comes back, the block goes.
        openMenu(app)
        XCTAssertTrue(app.menuItems["Edit signature as text"].exists)
        app.menuItems["Edit signature as text"].click()
        XCTAssertTrue(waitForBody(app) { $0.contains("Alex Rivera") && $0.contains("-- ") },
                      "Edit signature as text puts it in the body")
        XCTAssertFalse(block.waitForExistence(timeout: 1), "and the rendered block goes")

        // Rendered again: the text it left is swapped for the block.
        openMenu(app)
        app.menuItems[gmailName].click()
        XCTAssertTrue(block.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForBody(app) { !$0.contains("Alex Rivera") })

        openMenu(app)
        app.menuItems["No signature"].click()
        XCTAssertTrue(waitForBody(app) { !$0.contains(self.gmailText) && !$0.contains("-- ") },
                      "No signature takes it out")
        let deadline = Date().addingTimeInterval(5)
        while block.exists, Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertFalse(block.exists, "no signature, no rendered block")

        openMenu(app)
        app.menuItems["Manage signatures"].click()
        let settings = app.windows.matching(
            NSPredicate(format: "title CONTAINS 'Settings'")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(settings.descendants(matching: .any)
            .matching(identifier: "settings.signatures.refresh").firstMatch
            .waitForExistence(timeout: 5), "Manage signatures opens Settings → Signatures")
    }

    func testSettingsShowTheGmailSignatureWithoutAnImportButton() {
        let app = launchDemo(["-settingsPane", "signatures"])
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(
            NSPredicate(format: "title CONTAINS 'Settings'")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        let refresh = settings.descendants(matching: .any)
            .matching(identifier: "settings.signatures.refresh").firstMatch
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        XCTAssertFalse(settings.descendants(matching: .any)
            .matching(identifier: "settings.signatures.import").firstMatch.exists)
        XCTAssertFalse(settings.buttons["Import from Gmail…"].exists)
        // The Gmail signature arrived by itself, named after the address.
        XCTAssertTrue(settings.staticTexts["From Gmail."].waitForExistence(timeout: 15))
        XCTAssertTrue(settings.staticTexts["Short"].exists)
        refresh.click()
        XCTAssertTrue(settings.staticTexts["From Gmail."].waitForExistence(timeout: 10))

        // A signature copied from Gmail keeps its look when pasted.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("<meta charset='utf-8'><!--StartFragment--><div class=\"x\">"
                             + "<div style=\"color:#1a73e8\"><b>Ada Example</b></div>"
                             + "<div>Example Lab</div></div><!--EndFragment-->", forType: .html)
        pasteboard.setString("Ada Example\nExample Lab", forType: .string)
        let new = settings.descendants(matching: .any)
            .matching(identifier: "settings.signatures.new").firstMatch
        XCTAssertTrue(new.waitForExistence(timeout: 5))
        new.click()
        let editor = app.textViews.matching(identifier: "settings.signatures.body").firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        app.typeKey("v", modifierFlags: .command)
        let look = app.descendants(matching: .any)
            .matching(identifier: "settings.signatures.look").firstMatch
        XCTAssertTrue(look.waitForExistence(timeout: 5), "a rich paste shows how it is sent")
        XCTAssertTrue((editor.value as? String ?? "").contains("**Ada Example**"))
        app.buttons["Remove formatting"].click()
        XCTAssertFalse(look.waitForExistence(timeout: 1), "Remove formatting leaves the text only")
        XCTAssertTrue((editor.value as? String ?? "").contains("Ada Example"))
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    }
}
