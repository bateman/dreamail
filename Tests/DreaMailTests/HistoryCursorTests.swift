import XCTest

/// Where an incremental sync resumes. Gmail's `history.list` answers with
/// the mailbox's current `historyId`, which can be ahead of the records it
/// has made visible yet; resuming from it stepped over a message whose
/// record was listed only later, and that message was never fetched.
final class HistoryCursorTests: XCTestCase {

    /// The reported case: the response says 2000, the records end at 1500,
    /// and the message added at 1700 is listed only by the next read. The
    /// cursor must stay at 1500 so that read (records after 1500) sees it.
    func testCursorIsTheLastReturnedRecordNotTheResponseHistoryId() {
        XCTAssertEqual(SyncEngine.historyCursor(since: "1000", recordIds: ["1200", "1500"]), "1500")
    }

    func testNoRecordKeepsTheCursor() {
        XCTAssertEqual(SyncEngine.historyCursor(since: "1000", recordIds: []), "1000")
    }

    /// Compared as numbers, not strings ("999" sorts after "1000" as text).
    func testRecordsAreComparedAsNumbers() {
        XCTAssertEqual(SyncEngine.historyCursor(since: "900", recordIds: ["1000", "999"]), "1000")
    }

    func testCursorNeverMovesBack() {
        XCTAssertEqual(SyncEngine.historyCursor(since: "1000", recordIds: ["999"]), "1000")
    }

    func testCatchUpListsTwoWeeksOrTheShorterWindow() {
        XCTAssertEqual(SyncEngine.recentCatchUpQuery(windowDays: 90), "newer_than:14d")
        XCTAssertEqual(SyncEngine.recentCatchUpQuery(windowDays: 0), "newer_than:14d")
        XCTAssertEqual(SyncEngine.recentCatchUpQuery(windowDays: 7), "newer_than:7d")
    }
}
