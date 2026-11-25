import XCTest

/// The compose body's ⌘ formatting chords, against Gmail's list.
final class ComposeFormatKeysTests: XCTestCase {
    private func format(_ chars: String, keyCode: UInt16 = 0, shift: Bool = false,
                        option: Bool = false, control: Bool = false,
                        command: Bool = true) -> ComposeFormatKeys.Format? {
        ComposeFormatKeys.format(keyCode: keyCode, characters: chars, command: command,
                                 shift: shift, option: option, control: control)
    }

    /// The Gmail chords the editor already has an action for.
    func testGmailChordsWithAnEditorAction() {
        XCTAssertEqual(format("b"), .bold)
        XCTAssertEqual(format("i"), .italic)
        // Shift+8 / Shift+9 by key position: `*` / `(` on a US keyboard,
        // `(` / `)` on an Italian one.
        XCTAssertEqual(format("*", keyCode: ComposeFormatKeys.keyCode8, shift: true), .bullet)
        XCTAssertEqual(format("(", keyCode: ComposeFormatKeys.keyCode8, shift: true), .bullet)
        XCTAssertEqual(format("(", keyCode: ComposeFormatKeys.keyCode9, shift: true), .quote)
        XCTAssertEqual(format(")", keyCode: ComposeFormatKeys.keyCode9, shift: true), .quote)
    }

    func testDreaMailChordsAreKept() {
        XCTAssertEqual(format(">", keyCode: ComposeFormatKeys.keyCodePeriod, shift: true), .quote)
        XCTAssertEqual(format("x", shift: true), .strikethrough)
        XCTAssertEqual(format("e"), .code)
        XCTAssertEqual(format("m", shift: true), .math)
        XCTAssertEqual(format("1", option: true), .heading1)
        XCTAssertEqual(format("2", option: true), .heading2)
        XCTAssertEqual(format("3", option: true), .heading3)
    }

    /// ⌘K belongs to the link sheet; other chords go to the text system.
    func testOtherChordsAreLeftAlone() {
        XCTAssertNil(format("k"), "⌘K opens the link sheet")
        XCTAssertNil(format("u"), "no underline in a Markdown body")
        XCTAssertNil(format("b", control: true))
        XCTAssertNil(format("b", command: false))
        XCTAssertNil(format("7", keyCode: 26, shift: true), "no numbered list")
    }

    func testReferenceTableMatchesTheChords() {
        let supported = ComposeFormatKeys.gmailReference.filter(\.supported).map(\.title)
        XCTAssertEqual(supported, ["Bold", "Italic", "Bulleted list", "Quote", "Insert link"])
        let missing = ComposeFormatKeys.gmailReference.filter { !$0.supported }.map(\.title)
        XCTAssertEqual(missing, ["Underline", "Numbered list", "Indent less", "Indent more",
                                 "Remove formatting"])
    }
}
