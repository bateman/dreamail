import XCTest
import GRDB

/// Account removal hands MishMail snoozes back to Gmail's Inbox
/// (`SnoozeRelease`), after the purge and within a deadline; nothing in it
/// can block or undo the removal (`AccountLifecycle.runRemoval`).
final class SnoozeReleaseTests: XCTestCase {

    private actor Calls {
        private(set) var ids: [String] = []
        func add(_ id: String) { ids.append(id) }
    }

    func testReleasesEveryThreadInOrder() async {
        let calls = Calls()
        let left = await SnoozeRelease.release(["t1", "t2", "t3"], reachable: true) {
            await calls.add($0)
        }
        XCTAssertEqual(left, 0)
        let sent = await calls.ids
        XCTAssertEqual(sent, ["t1", "t2", "t3"])
        XCTAssertNil(SnoozeRelease.notReleasedMessage(left))
    }

    func testThreadGoneOnGmailIsSkipped() async {
        let calls = Calls()
        let left = await SnoozeRelease.release(["t1", "gone", "t3"], reachable: true) { id in
            await calls.add(id)
            if id == "gone" { throw GmailError.http(404, "not found") }
        }
        XCTAssertEqual(left, 0, "a 404 has nothing left to put back")
        let sent = await calls.ids
        XCTAssertEqual(sent, ["t1", "gone", "t3"])
    }

    func testStopsAtTransportOrAuthErrorAndCountsTheRest() async {
        // 0 = offline (URLError); otherwise the HTTP status Gmail answers.
        for code in [0, 401, 403, 429, 503] {
            let calls = Calls()
            let left = await SnoozeRelease.release(["t1", "t2", "t3", "t4"], reachable: true) { id in
                await calls.add(id)
                guard id == "t2" else { return }
                if code == 0 { throw URLError(.notConnectedToInternet) }
                throw GmailError.http(code, "")
            }
            let count = await calls.ids.count
            XCTAssertEqual(count, 2, "no run of calls that fail the same way: \(code)")
            XCTAssertEqual(left, 3, "\(code)")
        }
    }

    func testDeadlineEndsTheWholeRelease() async {
        let calls = Calls()
        let start = Date()
        let left = await SnoozeRelease.release(
            ["t1", "slow", "t3"], reachable: true, timeoutNanoseconds: 200_000_000
        ) { id in
            await calls.add(id)
            if id == "slow" { try await Task.sleep(nanoseconds: 30_000_000_000) }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "a hung call must not hold the removal")
        XCTAssertEqual(left, 2, "the hung call and the one after it")
        XCTAssertEqual(SnoozeRelease.timeoutNanoseconds, 10_000_000_000)
    }

    /// A call that ignores cancellation (like the shared token refresh)
    /// must not hold the removal past the deadline.
    func testDeadlineHoldsWhenACallIgnoresCancellation() async {
        let start = Date()
        let left = await SnoozeRelease.release(
            ["stuck", "t2"], reachable: true, timeoutNanoseconds: 200_000_000
        ) { _ in
            // Not cancellable: resumes only when the queue fires.
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { c.resume() }
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2,
                          "release must return at the deadline, not when the call ends")
        XCTAssertEqual(left, 2)
    }

    func testKnownOfflineSendsNothing() async {
        let calls = Calls()
        let left = await SnoozeRelease.release(["t1", "t2"], reachable: false) { await calls.add($0) }
        let count = await calls.ids.count
        XCTAssertEqual(count, 0)
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
        // Not "couldn't be reached": a refused sign-in or the deadline also end it.
        XCTAssertFalse(one.contains("reached"), one)
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

    // MARK: - Removal order (AccountLifecycle.runRemoval)

    @MainActor
    func testPurgeBeforeReleaseBeforeSignInGoes() async {
        var steps: [String] = []
        let outcome = await AccountLifecycle.runRemoval(
            markPending: { steps.append("mark") },
            purge: { steps.append("purge"); return ["t1", "t2"] },
            clearPending: { steps.append("clear") },
            release: { ids in steps.append("release \(ids.joined(separator: ","))"); return 1 },
            removeOutside: { steps.append("outside") })
        XCTAssertEqual(steps, ["mark", "purge", "release t1,t2", "outside"])
        XCTAssertEqual(outcome, .removed(notReleased: 1))
    }

    @MainActor
    func testPurgeFailureReleasesNothing() async {
        struct Refused: Error {}
        var steps: [String] = []
        let outcome = await AccountLifecycle.runRemoval(
            markPending: { steps.append("mark") },
            purge: { steps.append("purge"); throw Refused() },
            clearPending: { steps.append("clear") },
            release: { _ in steps.append("release"); return 0 },
            removeOutside: { steps.append("outside") })
        XCTAssertEqual(steps, ["mark", "purge", "clear"],
                       "nothing deleted: no Gmail change, sign-in kept")
        XCTAssertEqual(outcome, .purgeFailed)
    }

    // MARK: - Database half and quit in the middle

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        return q
    }

    private func thread(_ id: String, account: String, snoozeUntil: Date?,
                        inTrash: Bool = false, gmailSnoozed: Bool = false) -> MailThread {
        var t = MailThread(
            id: "\(account):\(id)", accountId: account, gmailThreadId: id,
            subject: id, snippet: "", fromDisplay: "F", lastDate: Date(),
            isUnread: false, isStarred: false, inInbox: false, inTrash: inTrash,
            labelIds: "", snoozeUntil: snoozeUntil, participants: "F",
            messageCount: 1, hasAttachment: false, reminderAt: nil)
        t.gmailSnoozed = gmailSnoozed
        return t
    }

    /// The snoozes are read in the purge's own transaction; a quit after it
    /// commits (during the release) finishes the removal at launch.
    func testPurgeReturnsSnoozesAndQuitDuringReleaseFinishesAtLaunch() throws {
        let q = try makeDB()
        let suite = "SnoozeReleaseTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let later = Date().addingTimeInterval(3600)
        try q.write { db in
            for account in ["a@x.com", "b@x.com"] {
                try Account(id: account, displayName: "A", historyId: nil,
                            lastSyncAt: nil, senderName: "").save(db)
            }
            try self.thread("mine", account: "a@x.com", snoozeUntil: later).insert(db)
            try self.thread("trashed", account: "a@x.com", snoozeUntil: later, inTrash: true).insert(db)
            try self.thread("gmail", account: "a@x.com", snoozeUntil: nil, gmailSnoozed: true).insert(db)
            try self.thread("other", account: "b@x.com", snoozeUntil: later).insert(db)
        }
        AccountLifecycle.markRemovalPending("a@x.com", defaults: defaults)
        let snoozed = try q.write { db in
            try AccountLifecycle.purgeAccountReturningSnoozes(db, id: "a@x.com")
        }
        XCTAssertEqual(snoozed, ["mine"])
        // The app quits here, before the release and the Keychain delete.
        let pending = AccountLifecycle.pendingRemovals(defaults: defaults)
        let removals = try q.read { try AccountLifecycle.removalsToFinish($0, pending: pending) }
        XCTAssertEqual(removals.finish, ["a@x.com"], "launch finishes the removal")
        XCTAssertEqual(removals.stale, [])
        try q.read { db in
            XCTAssertFalse(try Account.exists(db, key: "a@x.com"))
            XCTAssertEqual(try MailThread.fetchCount(db), 1, "only the other account's row")
        }
    }
}
