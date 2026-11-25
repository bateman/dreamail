import XCTest

/// F-11: by default a notification names no sender, subject or snippet;
/// one opt-in setting brings back sender and subject.
final class NotificationContentTests: XCTestCase {
    private let sender = "Ada Lovelace"
    private let subject = "Quarterly numbers, confidential"
    private let snippet = "the merger closes on Friday"

    private func item(_ n: Int = 1, account: String = "a@x.com") -> NotificationContent.MailItem {
        .init(accountId: account, threadId: "\(account):t\(n)",
              sender: "\(sender) \(n)", subject: "\(subject) \(n)")
    }

    private func assertGeneric(_ requests: [NotificationContent.Request],
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(requests.isEmpty, file: file, line: line)
        for r in requests {
            let text = r.title + "\n" + r.body
            for secret in [sender, "Quarterly", "confidential", snippet, "merger"] {
                XCTAssertFalse(text.contains(secret), "\(r) shows \(secret)",
                               file: file, line: line)
            }
        }
    }

    /// DEC-014: an account starts with generic notifications, and
    /// reauthorizing keeps what the user chose.
    func testSettingIsOffForANewAccount() {
        let fresh = AccountLifecycle.accountAfterSignIn(email: "n@x.com", name: "N", existing: nil)
        XCTAssertFalse(fresh.notificationDetails)
        var chosen = fresh
        chosen.notificationDetails = true
        let again = AccountLifecycle.accountAfterSignIn(email: "n@x.com", name: "N",
                                                        existing: chosen)
        XCTAssertTrue(again.notificationDetails, "reauthorizing keeps the account's choice")
    }

    func testLegacySwitchIsOffByDefault() throws {
        let suite = "NotificationContentTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(NotificationContent.legacyShowsDetails(defaults: defaults))
        defaults.set(true, forKey: NotificationContent.legacyShowDetailsKey)
        XCTAssertTrue(NotificationContent.legacyShowsDetails(defaults: defaults))
    }

    // MARK: - Default: generic

    func testDefaultNewMailIsGeneric() {
        let one = NotificationContent.newMail([item()], detailAccounts: [])
        assertGeneric(one)
        XCTAssertEqual(one.map(\.title), ["New mail"])
        XCTAssertEqual(one.map(\.body), [""])

        let several = NotificationContent.newMail((1...5).map { item($0) }, detailAccounts: [])
        assertGeneric(several)
        XCTAssertEqual(several.map(\.title), ["5 new messages"],
                       "several threads become one count, not five identical alerts")
    }

    func testDefaultReminderIsGeneric() {
        let one = NotificationContent.reminders([item()], detailAccounts: [])
        assertGeneric(one)
        XCTAssertEqual(one.map(\.title), ["Follow-up reminder"])

        let several = NotificationContent.reminders([item(1), item(2)], detailAccounts: [])
        assertGeneric(several)
        XCTAssertEqual(several.map(\.title), ["2 follow-up reminders"])
    }

    func testDefaultScheduledSendIsGeneric() {
        let r = NotificationContent.scheduledSent(
            accountId: "a@x.com", rowId: 3, subject: subject, showDetails: false)
        assertGeneric([r])
        XCTAssertEqual(r.title, "Scheduled message sent")
        XCTAssertEqual(r.body, "")
    }

    // MARK: - Opt-in: sender and subject

    func testOptInRestoresSenderAndSubject() {
        let mail = NotificationContent.newMail([item()], detailAccounts: ["a@x.com"])
        XCTAssertEqual(mail.map(\.title), ["\(sender) 1"])
        XCTAssertEqual(mail.map(\.body), ["\(subject) 1"])

        let reminder = NotificationContent.reminders([item()], detailAccounts: ["a@x.com"])
        XCTAssertEqual(reminder.map(\.title), ["Follow up: \(sender) 1"])
        XCTAssertEqual(reminder.map(\.body), ["\(subject) 1"])

        let sent = NotificationContent.scheduledSent(
            accountId: "a@x.com", rowId: 3, subject: subject, showDetails: true)
        XCTAssertEqual(sent.body, subject)
    }

    func testOptInKeepsTheThreeThreadCapAndCount() {
        let five = NotificationContent.newMail((1...5).map { item($0) },
                                               detailAccounts: ["a@x.com"])
        XCTAssertEqual(five.count, 4)
        XCTAssertEqual(five.prefix(3).map(\.title), ["\(sender) 1", "\(sender) 2", "\(sender) 3"])
        XCTAssertEqual(five.last?.body, "5 new messages")
    }

    /// The snippet was the fallback for an empty subject. It is never shown.
    func testEmptySubjectNeverFallsBackToTheSnippet() {
        let empty = NotificationContent.MailItem(accountId: "a@x.com", threadId: "a@x.com:t",
                                                 sender: sender, subject: "")
        XCTAssertEqual(NotificationContent.newMail([empty], detailAccounts: ["a@x.com"]).first?.body,
                       "(no subject)")
        XCTAssertEqual(NotificationContent.reminders([empty], detailAccounts: ["a@x.com"]).first?.body,
                       "(no subject)")
    }

    func testNothingToNotifyPostsNothing() {
        XCTAssertEqual(NotificationContent.newMail([], detailAccounts: []), [])
        XCTAssertEqual(NotificationContent.reminders([], detailAccounts: ["a@x.com"]), [])
    }

    // MARK: - Per account

    private let work = "w@x.com"
    private let home = "h@x.com"

    private func assertShows(_ r: NotificationContent.Request, _ n: Int, account: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue((r.title + r.body).contains("\(subject) \(n)") ||
                      (r.title + r.body).contains("\(sender) \(n)"), "\(r)",
                      file: file, line: line)
        XCTAssertTrue(NotificationContent.belongs(r.id, toAccount: account), file: file, line: line)
    }

    /// New mail of an account that allows details shows them; mail of one
    /// that does not, in the same sync, stays generic.
    func testNewMailFollowsEachMessagesAccount() {
        let requests = NotificationContent.newMail(
            [item(1, account: work), item(2, account: home)], detailAccounts: [work])
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].title, "\(sender) 1")
        XCTAssertEqual(requests[0].body, "\(subject) 1")
        assertShows(requests[0], 1, account: work)
        assertGeneric([requests[1]])
        XCTAssertEqual(requests[1].title, "New mail")
        XCTAssertTrue(NotificationContent.belongs(requests[1].id, toAccount: home))
        XCTAssertFalse(NotificationContent.belongs(requests[1].id, toAccount: work))

        let swapped = NotificationContent.newMail(
            [item(1, account: work), item(2, account: home)], detailAccounts: [home])
        assertGeneric([swapped[1]])
        XCTAssertEqual(swapped[0].title, "\(sender) 2")
    }

    /// A count covers only accounts that all allow details, or only
    /// accounts that do not: an account that keeps details off is never
    /// folded into a detailed notification.
    func testSummaryShowsDetailsOnlyIfAllItsAccountsAllowThem() {
        let homeMail = (1...3).map { item($0, account: home) }
        let workMail = (4...8).map { item($0, account: work) }
        let mixed = NotificationContent.newMail(workMail + homeMail, detailAccounts: [work])
        // Work: three detailed, then a count of its five.
        XCTAssertEqual(mixed.prefix(3).map(\.title), ["\(sender) 4", "\(sender) 5", "\(sender) 6"])
        XCTAssertEqual(mixed[3].body, "5 new messages")
        XCTAssertTrue(NotificationContent.belongs(mixed[3].id, toAccount: work))
        XCTAssertFalse(NotificationContent.belongs(mixed[3].id, toAccount: home))
        // Home: one generic count of its three.
        XCTAssertEqual(mixed.count, 5)
        assertGeneric([mixed[4]])
        XCTAssertEqual(mixed[4].title, "3 new messages")
        XCTAssertTrue(NotificationContent.belongs(mixed[4].id, toAccount: home))
        XCTAssertFalse(NotificationContent.belongs(mixed[4].id, toAccount: work))

        // Both allow: one detailed summary over both accounts.
        let both = NotificationContent.newMail(workMail + homeMail, detailAccounts: [work, home])
        XCTAssertEqual(both.count, 4)
        XCTAssertEqual(both[3].body, "8 new messages")
        XCTAssertTrue(NotificationContent.belongs(both[3].id, toAccount: work))
        XCTAssertTrue(NotificationContent.belongs(both[3].id, toAccount: home))

        // Neither allows: one generic count over both, as before.
        let neither = NotificationContent.newMail(workMail + homeMail, detailAccounts: [])
        assertGeneric(neither)
        XCTAssertEqual(neither.map(\.title), ["8 new messages"])
    }

    func testRemindersFollowEachThreadsAccount() {
        let one = NotificationContent.reminders(
            [item(1, account: work), item(2, account: home)], detailAccounts: [work])
        XCTAssertEqual(one.map(\.title), ["Follow up: \(sender) 1", "Follow-up reminder"])
        assertShows(one[0], 1, account: work)
        assertGeneric([one[1]])
        XCTAssertTrue(NotificationContent.belongs(one[1].id, toAccount: home))

        let several = NotificationContent.reminders(
            [item(1, account: work), item(2, account: home), item(3, account: home)],
            detailAccounts: [work])
        XCTAssertEqual(several.count, 2)
        assertGeneric([several[1]])
        XCTAssertEqual(several[1].title, "2 follow-up reminders")
        XCTAssertFalse(NotificationContent.belongs(several[1].id, toAccount: work),
                       "the generic count covers only the account that keeps details off")

        let none = NotificationContent.reminders(
            [item(1, account: work), item(2, account: home)], detailAccounts: [])
        assertGeneric(none)
        XCTAssertEqual(none.map(\.title), ["2 follow-up reminders"])
    }

    /// The scheduled-send notice follows the account that sent it.
    func testScheduledSendFollowsTheSendingAccount() {
        let allowed: Set<String> = [work]
        let fromWork = NotificationContent.scheduledSent(
            accountId: work, rowId: 1, subject: subject, showDetails: allowed.contains(work))
        let fromHome = NotificationContent.scheduledSent(
            accountId: home, rowId: 2, subject: subject, showDetails: allowed.contains(home))
        XCTAssertEqual(fromWork.body, subject)
        assertGeneric([fromHome])
    }

    // MARK: - Identifiers

    func testIdentifiersNameTheAccountAndStayDistinct() {
        let a = NotificationContent.newMail([item(1)], detailAccounts: [])[0].id
        let a2 = NotificationContent.newMail([item(2)], detailAccounts: [])[0].id
        let b = NotificationContent.newMail([item(1, account: "b@x.com")], detailAccounts: [])[0].id
        XCTAssertEqual(Set([a, a2, b]).count, 3)
        XCTAssertTrue(NotificationContent.belongs(a, toAccount: "a@x.com"))
        XCTAssertFalse(NotificationContent.belongs(b, toAccount: "a@x.com"))
        XCTAssertEqual(a, NotificationContent.newMail([item(1)], detailAccounts: ["a@x.com"])[0].id,
                       "the setting changes the text, not which notification it replaces")
    }

    /// The system stores identifiers whatever the setting: they carry no
    /// address and no thread id, only salted hashes.
    func testIdentifiersCarryNoAddressOrThreadId() {
        let a = item(1)
        var ids = NotificationContent.newMail([a], detailAccounts: [], salt: "s1").map(\.id)
        ids += NotificationContent.newMail([a], detailAccounts: ["a@x.com"], salt: "s1").map(\.id)
        ids += NotificationContent.newMail((1...5).map { item($0) }, detailAccounts: ["a@x.com"],
                                           salt: "s1").map(\.id)
        ids += NotificationContent.reminders([a], detailAccounts: [], salt: "s1").map(\.id)
        ids.append(NotificationContent.scheduledSent(
            accountId: "a@x.com", rowId: 3, subject: "s", showDetails: true, salt: "s1").id)
        for id in ids {
            for leak in ["a@x.com", "a%40x", "@", "x.com", ":t1"] {
                XCTAssertFalse(id.contains(leak), "\(id) contains \(leak)")
            }
            XCTAssertTrue(NotificationContent.belongs(id, toAccount: "a@x.com", salt: "s1"), id)
        }
        let otherInstall = NotificationContent.newMail([a], detailAccounts: [], salt: "s2")[0].id
        XCTAssertNotEqual(ids[0], otherInstall, "the hash depends on the per-install salt")
        XCTAssertFalse(NotificationContent.belongs(otherInstall, toAccount: "a@x.com", salt: "s1"))
    }

    /// The same accounts in another order must give the same batch id, so a
    /// newer count replaces the older one.
    func testBatchIdentifierIgnoresAccountOrder() {
        let ab = NotificationContent.newMail(
            [item(1, account: "a@x.com"), item(2, account: "b@x.com")],
            detailAccounts: [], salt: "s")
        let ba = NotificationContent.newMail(
            [item(3, account: "b@x.com"), item(4, account: "a@x.com"), item(5, account: "b@x.com")],
            detailAccounts: [], salt: "s")
        XCTAssertEqual(ab.map(\.id), ba.map(\.id))
        XCTAssertEqual(NotificationContent.identifier(kind: .reminder, accounts: ["a", "b"],
                                                      key: "batch", salt: "s"),
                       NotificationContent.identifier(kind: .reminder, accounts: ["b", "a", "a"],
                                                      key: "batch", salt: "s"))
    }

    /// Separators inside an address must not split or widen the match.
    func testAddressesWithSeparatorsAreEncoded() {
        let odd = "x/y,z.w@q.com"
        let id = NotificationContent.identifier(kind: .reminder, accounts: [odd], key: "k/1")
        XCTAssertEqual(id.split(separator: "/", maxSplits: 2).count, 3)
        XCTAssertTrue(NotificationContent.belongs(id, toAccount: odd))
        XCTAssertFalse(NotificationContent.belongs(id, toAccount: "x"))
        XCTAssertFalse(NotificationContent.belongs(id, toAccount: "z.w@q.com"))
        XCTAssertFalse(NotificationContent.belongs(id, toAccount: "x/y,z.w@q.co"))
    }
}
