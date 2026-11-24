import XCTest

/// Hostless suite: the conversation view's message rows (Gmail-style flat
/// rows) — geometry per font scale, the narrow-pane date rule, and which
/// avatar a message gets.
final class ThreadMessageRowLayoutTests: XCTestCase {

    // MARK: Geometry

    func testCollapsedRowIsAboutEightyPointsAtTheDefaultSize() {
        let m = ThreadMessageRowMetrics(fontScale: 1)
        XCTAssertEqual(m.collapsedRowHeight, 80, accuracy: 0.5)
        // The avatar, not the two text lines, sets the height.
        XCTAssertGreaterThan(m.avatarSize,
                             m.nameFontSize * 1.25 + m.lineSpacing + m.secondaryFontSize * 1.25)
    }

    func testRowGrowsWithTheFontScale() {
        let small = ThreadMessageRowMetrics(fontScale: 0.8)
        let large = ThreadMessageRowMetrics(fontScale: 1.6)
        XCTAssertLessThan(small.collapsedRowHeight, 80)
        XCTAssertEqual(large.collapsedRowHeight / small.collapsedRowHeight, 2, accuracy: 0.001)
        XCTAssertEqual(large.textColumnLeading / small.textColumnLeading, 2, accuracy: 0.001)
    }

    func testBodyKeepsItsReadingWidthAtEveryScale() {
        // Pane margin + former card padding, as before the flat rows.
        XCTAssertEqual(ThreadMessageRowMetrics(fontScale: 0.8).bodyInset, 32)
        XCTAssertEqual(ThreadMessageRowMetrics(fontScale: 1.6).bodyInset, 32)
    }

    func testCorruptFontScaleIsClamped() {
        XCTAssertGreaterThan(ThreadMessageRowMetrics(fontScale: 0).avatarSize, 0)
        XCTAssertLessThan(ThreadMessageRowMetrics(fontScale: 100).avatarSize, 200)
    }

    func testTextColumnWidthSubtractsInsetsAvatarAndGap() {
        let m = ThreadMessageRowMetrics(fontScale: 1)
        // 16 + 40 + 16 before the text, 16 after it.
        XCTAssertEqual(m.textColumnWidth(rowWidth: 600), 600 - 88)
        XCTAssertEqual(m.textColumnWidth(rowWidth: 50), 0, "never negative")
    }

    // MARK: Narrow-pane date rule

    private func style(rowWidth: CGFloat, scale: Double = 1) -> MessageRowDateStyle {
        let m = ThreadMessageRowMetrics(fontScale: scale)
        return MessageRowDateStyle.forTextColumn(
            width: m.textColumnWidth(rowWidth: rowWidth), fontScale: scale)
    }

    func testWideReadingPaneShowsTheRelativePart() {
        // Reading pane beside the list on a 13-inch screen: about 560-700 pt.
        XCTAssertEqual(style(rowWidth: 560), .absoluteWithRelative)
        XCTAssertEqual(style(rowWidth: 900), .absoluteWithRelative)
    }

    func testNarrowPaneDropsTheRelativePartThenShrinks() {
        XCTAssertEqual(style(rowWidth: 420), .absolute)
        XCTAssertEqual(style(rowWidth: 320), .compact)
    }

    func testLargerTextNeedsAWiderPaneForTheSameDate() {
        XCTAssertEqual(style(rowWidth: 560, scale: 1), .absoluteWithRelative)
        XCTAssertNotEqual(style(rowWidth: 560, scale: 1.6), .absoluteWithRelative)
    }

    func testDateStyleNeverWidensAsThePaneNarrows() {
        let rank: [MessageRowDateStyle: Int] = [.compact: 0, .absolute: 1, .absoluteWithRelative: 2]
        for scale in [0.8, 1.0, 1.3, 1.6] {
            var previous = Int.max
            for width in stride(from: 1200, through: 100, by: -10) {
                let r = rank[style(rowWidth: CGFloat(width), scale: scale)]!
                XCTAssertLessThanOrEqual(r, previous, "scale \(scale) width \(width)")
                previous = r
            }
        }
    }

    // MARK: Date text

    func testFullDateAddsTheRelativePartInParentheses() {
        let now = Date()
        let date = now.addingTimeInterval(-12 * 3600)
        let full = MessageRowDate.text(date, style: .absoluteWithRelative, now: now)
        let absolute = MessageRowDate.text(date, style: .absolute, now: now)
        XCTAssertTrue(full.hasPrefix(absolute + " ("), full)
        XCTAssertTrue(full.hasSuffix(")"), full)
        XCTAssertTrue(full.contains("12"), full)
    }

    func testRelativePartReadsNowForTheFutureAndTheLastMinute() {
        let now = Date()
        let justNow = MessageRowDate.relative(now.addingTimeInterval(-20), now: now)
        XCTAssertEqual(MessageRowDate.relative(now.addingTimeInterval(300), now: now), justNow,
                       "a clock-skewed future date must not read 'in 5 minutes'")
        XCTAssertNotEqual(MessageRowDate.relative(now.addingTimeInterval(-7200), now: now), justNow)
    }

    // MARK: Avatar

    private let accounts = ["alex@example.com", "work@corp.example"]
    private let own: Set<String> = ["alex@example.com", "work@corp.example", "alex@alias.example"]

    private func avatar(_ email: String, name: String = "Someone",
                        mailbox: String = "alex@example.com",
                        photos: Set<String> = []) -> MessageAvatar {
        MessageAvatar.resolve(senderEmail: email, senderName: name,
                              messageAccountId: mailbox, accountIds: accounts,
                              ownAddresses: own, accountsWithPhoto: photos)
    }

    func testOwnAccountWithPhotoShowsThePhoto() {
        XCTAssertEqual(avatar("Work@Corp.example", photos: ["work@corp.example"]),
                       .accountPhoto(accountId: "work@corp.example"))
    }

    func testOwnAccountWithoutPhotoShowsItsInitialInTheAccountColour() {
        XCTAssertEqual(avatar("alex@example.com", name: "Alex", photos: ["work@corp.example"]),
                       .initial(name: "Alex", key: "alex@example.com"))
    }

    func testSendAsAliasUsesTheMailboxThatHoldsTheMessage() {
        XCTAssertEqual(avatar("alex@alias.example", mailbox: "work@corp.example",
                              photos: ["work@corp.example"]),
                       .accountPhoto(accountId: "work@corp.example"))
    }

    func testOtherSendersNeverGetAPhoto() {
        // Even when every account has a photo, a stranger gets a disc keyed
        // by their own address (a stable hue per sender).
        XCTAssertEqual(avatar("Priya@Example.edu", name: "Priya Raman",
                              photos: Set(accounts)),
                       .initial(name: "Priya Raman", key: "priya@example.edu"))
    }

    func testSenderWithoutNameUsesTheAddressForTheInitial() {
        XCTAssertEqual(avatar("noreply@x.example", name: "  "),
                       .initial(name: "noreply@x.example", key: "noreply@x.example"))
    }
}
