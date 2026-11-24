import XCTest

final class GmailMarkReadKeysTests: XCTestCase {
    func testShiftIChord() {
        XCTAssertEqual(GmailMarkReadKeys.chord(key: "I", shiftOnly: true), .shiftI)
        XCTAssertEqual(GmailMarkReadKeys.chord(key: "i", shiftOnly: true), .shiftI)
    }

    func testShiftUChord() {
        XCTAssertEqual(GmailMarkReadKeys.chord(key: "U", shiftOnly: true), .shiftU)
        XCTAssertEqual(GmailMarkReadKeys.chord(key: "u", shiftOnly: true), .shiftU)
    }

    func testPlainOrModifiedKeysIgnored() {
        XCTAssertNil(GmailMarkReadKeys.chord(key: "i", shiftOnly: false))
        XCTAssertNil(GmailMarkReadKeys.chord(key: "u", shiftOnly: false))
        XCTAssertNil(GmailMarkReadKeys.chord(key: "I", shiftOnly: false))
        XCTAssertNil(GmailMarkReadKeys.chord(key: "e", shiftOnly: true))
        XCTAssertNil(GmailMarkReadKeys.chord(key: "!", shiftOnly: true))
        XCTAssertNil(GmailMarkReadKeys.chord(key: "", shiftOnly: true))
        XCTAssertNil(GmailMarkReadKeys.chord(key: "ii", shiftOnly: true))
    }

    /// Gmail's Shift+I only ever marks read. It used to mark an already-read
    /// selection unread; that flip is now the separate `toggleRead` command.
    func testShiftIAlwaysMarksRead() {
        XCTAssertTrue(GmailMarkReadKeys.desiredRead(chord: .shiftI))
    }

    func testShiftUAlwaysMarksUnread() {
        XCTAssertFalse(GmailMarkReadKeys.desiredRead(chord: .shiftU))
    }

    /// Shift+N is Gmail's "update conversation" (MishMail: sync all).
    func testShiftNIsTheRefreshKey() {
        XCTAssertTrue(GmailRefreshKey.matches(key: "N", shiftOnly: true))
        XCTAssertTrue(GmailRefreshKey.matches(key: "n", shiftOnly: true))  // Caps Lock off quirks
        XCTAssertFalse(GmailRefreshKey.matches(key: "n", shiftOnly: false))
        XCTAssertFalse(GmailRefreshKey.matches(key: "m", shiftOnly: true))
        XCTAssertNil(GmailMarkReadKeys.chord(key: "N", shiftOnly: true))
    }
}
