import XCTest

/// Account removal hands MishMail snoozes back to Gmail's Inbox first
/// (`SnoozeRelease`); a failure never blocks the removal and is reported.
final class SnoozeReleaseTests: XCTestCase {

    private struct Offline: Error {}

    func testReleasesEveryThreadInOrder() async {
        var sent: [String] = []
        let left = await SnoozeRelease.release(["t1", "t2", "t3"], reachable: true) {
            sent.append($0)
        }
        XCTAssertEqual(left, 0)
        XCTAssertEqual(sent, ["t1", "t2", "t3"])
        XCTAssertNil(SnoozeRelease.notReleasedMessage(left))
    }

    func testStopsAtFirstFailureAndCountsTheRest() async {
        var calls = 0
        let left = await SnoozeRelease.release(["t1", "t2", "t3", "t4"], reachable: true) { _ in
            calls += 1
            if calls == 2 { throw Offline() }
        }
        XCTAssertEqual(calls, 2, "no run of calls that fail the same way")
        XCTAssertEqual(left, 3)
    }

    func testKnownOfflineSendsNothing() async {
        var calls = 0
        let left = await SnoozeRelease.release(["t1", "t2"], reachable: false) { _ in calls += 1 }
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(left, 2)
    }

    func testNothingSnoozedNothingSaid() async {
        let left = await SnoozeRelease.release([], reachable: false) { _ in XCTFail("no call") }
        XCTAssertEqual(left, 0)
        XCTAssertNil(SnoozeRelease.notReleasedMessage(0))
    }

    func testMessageNamesCountAndWhereToFindThem() throws {
        let one = try XCTUnwrap(SnoozeRelease.notReleasedMessage(1))
        XCTAssertTrue(one.contains("1 conversation snoozed in MishMail"), one)
        XCTAssertTrue(one.contains("All Mail"), one)
        let many = try XCTUnwrap(SnoozeRelease.notReleasedMessage(4))
        XCTAssertTrue(many.contains("4 conversations"), many)
        XCTAssertTrue(many.contains("they stay archived"), many)
    }

    func testConfirmationTellsWhatHappensToSnoozes() {
        for ai in [false, true] {
            let text = AccountLifecycle.removalConfirmationMessage(aiFeaturesEnabled: ai)
            XCTAssertTrue(text.contains("snoozed in MishMail are first put back in the Gmail Inbox"), text)
            XCTAssertTrue(text.contains("All Mail"), text)
        }
    }
}
