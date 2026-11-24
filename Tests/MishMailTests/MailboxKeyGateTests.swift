import AppKit
import XCTest

/// Mailbox single-key shortcuts (j, k, o, u, e, g i, * a, /, ?…) must never
/// fire while an editable text field owns the keyboard, nor outside the main
/// window or under an overlay.
final class MailboxKeyGateTests: XCTestCase {
    private let idle = MailboxKeyGate.Facts(
        unmodified: true, isMainWindow: true,
        commandPaletteOpen: false, labelPickerOpen: false, viewEditorOpen: false,
        hasComposeRequest: false, composeMinimized: false, composeFinishing: false,
        textEditing: false)

    func testIdleMailboxAllowsSingleKeys() {
        XCTAssertTrue(MailboxKeyGate.allowsSingleKeys(idle))
    }

    func testTypingInAFieldBlocksSingleKeys() {
        var facts = idle
        facts.textEditing = true   // search field, label query, Settings
        XCTAssertFalse(MailboxKeyGate.allowsSingleKeys(facts))
        facts.hasComposeRequest = true
        facts.composeMinimized = true   // minimized compose, but a field typing
        XCTAssertFalse(MailboxKeyGate.allowsSingleKeys(facts))
    }

    /// Against real AppKit responders: an editable field's text blocks the
    /// keys, selectable conversation text does not.
    func testRealRespondersThroughTextFocus() {
        var facts = idle
        let field = NSTextField(string: "")
        facts.textEditing = TextFocus.isEditing(field)
        XCTAssertFalse(MailboxKeyGate.allowsSingleKeys(facts))
        let editor = NSTextView(frame: .zero)
        editor.isEditable = true
        facts.textEditing = TextFocus.isEditing(editor)
        XCTAssertFalse(MailboxKeyGate.allowsSingleKeys(facts))
        let label = NSTextField(labelWithString: "Subject")
        label.isSelectable = true
        facts.textEditing = TextFocus.isEditing(label)
        XCTAssertTrue(MailboxKeyGate.allowsSingleKeys(facts))
    }

    func testExpandedComposeBlocksSingleKeys() {
        var facts = idle
        facts.hasComposeRequest = true
        XCTAssertFalse(MailboxKeyGate.allowsSingleKeys(facts))
        facts.composeMinimized = true
        XCTAssertTrue(MailboxKeyGate.allowsSingleKeys(facts))
    }

    /// After Send, a lagging body focus must not swallow the next key
    /// (ComposeKeyOwnership.textFocusBlocksMailboxKeys).
    func testFinishingComposeBypassesTextFocus() {
        var facts = idle
        facts.hasComposeRequest = true
        facts.composeFinishing = true
        facts.textEditing = true
        XCTAssertTrue(MailboxKeyGate.allowsSingleKeys(facts))
    }

    func testModifiersOverlaysAndOtherWindowsBlockSingleKeys() {
        var facts = idle
        facts.unmodified = false
        XCTAssertFalse(MailboxKeyGate.allowsSingleKeys(facts))
        facts = idle; facts.isMainWindow = false
        XCTAssertFalse(MailboxKeyGate.allowsSingleKeys(facts))
        facts = idle; facts.commandPaletteOpen = true
        XCTAssertFalse(MailboxKeyGate.allowsSingleKeys(facts))
        facts = idle; facts.labelPickerOpen = true
        XCTAssertFalse(MailboxKeyGate.allowsSingleKeys(facts))
        facts = idle; facts.viewEditorOpen = true
        XCTAssertFalse(MailboxKeyGate.allowsSingleKeys(facts))
    }
}

/// Gmail `u`, back to the conversation list, in each layout.
final class BackToListTests: XCTestCase {
    func testFullWindowConversationReturnsToTheList() {
        XCTAssertEqual(BackToList.action(layoutMode: .threadFocus, threadFocus: true),
                       .exitThreadFocus)
        // Center peek / ⌘↩ focus set the flag even before the layout settles.
        XCTAssertEqual(BackToList.action(layoutMode: .threePane, threadFocus: true),
                       .exitThreadFocus)
    }

    func testNarrowWindowClosesTheConversationCoveringTheList() {
        XCTAssertEqual(BackToList.action(layoutMode: .compactDetail, threadFocus: false),
                       .closeConversation)
    }

    func testListAlreadyVisibleDoesNothing() {
        XCTAssertEqual(BackToList.action(layoutMode: .threePane, threadFocus: false), .stay)
        XCTAssertEqual(BackToList.action(layoutMode: .list, threadFocus: false), .stay)
    }
}
