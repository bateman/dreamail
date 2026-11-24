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

    func testSettingIsOffByDefault() throws {
        let suite = "NotificationContentTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(NotificationContent.showsDetails(defaults: defaults))
        defaults.set(true, forKey: NotificationContent.showDetailsKey)
        XCTAssertTrue(NotificationContent.showsDetails(defaults: defaults))
    }

    // MARK: - Default: generic

    func testDefaultNewMailIsGeneric() {
        let one = NotificationContent.newMail([item()], showDetails: false)
        assertGeneric(one)
        XCTAssertEqual(one.map(\.title), ["New mail"])
        XCTAssertEqual(one.map(\.body), [""])

        let several = NotificationContent.newMail((1...5).map { item($0) }, showDetails: false)
        assertGeneric(several)
        XCTAssertEqual(several.map(\.title), ["5 new messages"],
                       "several threads become one count, not five identical alerts")
    }

    func testDefaultReminderIsGeneric() {
        let one = NotificationContent.reminders([item()], showDetails: false)
        assertGeneric(one)
        XCTAssertEqual(one.map(\.title), ["Follow-up reminder"])

        let several = NotificationContent.reminders([item(1), item(2)], showDetails: false)
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
        let mail = NotificationContent.newMail([item()], showDetails: true)
        XCTAssertEqual(mail.map(\.title), ["\(sender) 1"])
        XCTAssertEqual(mail.map(\.body), ["\(subject) 1"])

        let reminder = NotificationContent.reminders([item()], showDetails: true)
        XCTAssertEqual(reminder.map(\.title), ["Follow up: \(sender) 1"])
        XCTAssertEqual(reminder.map(\.body), ["\(subject) 1"])

        let sent = NotificationContent.scheduledSent(
            accountId: "a@x.com", rowId: 3, subject: subject, showDetails: true)
        XCTAssertEqual(sent.body, subject)
    }

    func testOptInKeepsTheThreeThreadCapAndCount() {
        let five = NotificationContent.newMail((1...5).map { item($0) }, showDetails: true)
        XCTAssertEqual(five.count, 4)
        XCTAssertEqual(five.prefix(3).map(\.title), ["\(sender) 1", "\(sender) 2", "\(sender) 3"])
        XCTAssertEqual(five.last?.body, "5 new messages")
    }

    /// The snippet was the fallback for an empty subject. It is never shown.
    func testEmptySubjectNeverFallsBackToTheSnippet() {
        let empty = NotificationContent.MailItem(accountId: "a@x.com", threadId: "a@x.com:t",
                                                 sender: sender, subject: "")
        XCTAssertEqual(NotificationContent.newMail([empty], showDetails: true).first?.body,
                       "(no subject)")
        XCTAssertEqual(NotificationContent.reminders([empty], showDetails: true).first?.body,
                       "(no subject)")
    }

    func testNothingToNotifyPostsNothing() {
        XCTAssertEqual(NotificationContent.newMail([], showDetails: false), [])
        XCTAssertEqual(NotificationContent.reminders([], showDetails: true), [])
    }

    // MARK: - Identifiers

    func testIdentifiersNameTheAccountAndStayDistinct() {
        let a = NotificationContent.newMail([item(1)], showDetails: false)[0].id
        let a2 = NotificationContent.newMail([item(2)], showDetails: false)[0].id
        let b = NotificationContent.newMail([item(1, account: "b@x.com")], showDetails: false)[0].id
        XCTAssertEqual(Set([a, a2, b]).count, 3)
        XCTAssertTrue(NotificationContent.belongs(a, toAccount: "a@x.com"))
        XCTAssertFalse(NotificationContent.belongs(b, toAccount: "a@x.com"))
        XCTAssertEqual(a, NotificationContent.newMail([item(1)], showDetails: true)[0].id,
                       "the setting changes the text, not which notification it replaces")
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
