import XCTest

final class ThreadRowActionsTests: XCTestCase {
    func testHoverActionsAreTheFourGmailOnesInOrder() {
        XCTAssertEqual(ThreadRowHoverAction.allCases, [.archive, .trash, .toggleRead, .snooze])
    }

    func testThirdActionFlipsBetweenUnreadAndRead() {
        XCTAssertEqual(ThreadRowHoverAction.toggleRead.title(isUnread: false), "Mark as unread")
        XCTAssertEqual(ThreadRowHoverAction.toggleRead.symbol(isUnread: false), "envelope.badge")
        XCTAssertEqual(ThreadRowHoverAction.toggleRead.title(isUnread: true), "Mark as read")
        XCTAssertEqual(ThreadRowHoverAction.toggleRead.symbol(isUnread: true), "envelope.open")
    }

    func testOtherActionsDoNotDependOnReadState() {
        for action in [ThreadRowHoverAction.archive, .trash, .snooze] {
            XCTAssertEqual(action.title(isUnread: true), action.title(isUnread: false))
            XCTAssertEqual(action.symbol(isUnread: true), action.symbol(isUnread: false))
        }
        XCTAssertEqual(ThreadRowHoverAction.archive.symbol(isUnread: false), "archivebox")
        XCTAssertEqual(ThreadRowHoverAction.trash.symbol(isUnread: false), "trash")
        XCTAssertEqual(ThreadRowHoverAction.trash.title(isUnread: false), "Trash")
        XCTAssertEqual(ThreadRowHoverAction.snooze.symbol(isUnread: false), "clock")
    }

    func testIdentifiersAreTheRawValuesAndUnique() {
        let ids = ThreadRowHoverAction.allCases.map(\.rawValue)
        XCTAssertEqual(ids, ["archive", "trash", "toggleRead", "snooze"])
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testButtonsTakeSeventyFiveAndAHalfPointsAtScaleOne() {
        // Four 17 pt buttons (13 pt glyph, 2 pt padding each side) and three
        // 2.5 pt gaps (a little air between the icons).
        XCTAssertEqual(ThreadRowActionLayout.actionsWidth(fontScale: 1.0), 75.5, accuracy: 0.001)
    }

    func testButtonsGrowWithTheFontScaleAndKeepAClickableSize() {
        var last = 0.0
        for scale in [0.8, 1.0, 1.25, 1.5, 2.0] {
            let width = ThreadRowActionLayout.actionsWidth(fontScale: scale)
            XCTAssertGreaterThan(width, last)
            last = width
            // Each button is at least 14 pt wide (14.4 pt at the smallest
            // scale, 17 pt at scale 1) and, with the vertical hit extension,
            // at least 20 pt tall (about 34 pt at scale 1).
            XCTAssertGreaterThanOrEqual(width / Double(ThreadRowHoverAction.allCases.count), 14)
            XCTAssertGreaterThanOrEqual(
                ThreadRowActionLayout.iconSize * scale + 2 * ThreadRowActionLayout.iconPaddingV
                    + 2 * ThreadRowActionLayout.hitExtraV, 20)
        }
    }

    /// The date must size the slot (fixed size, buttons' width as minimum):
    /// a hard width clipped "Nov 25, 2025" at large text sizes.
    func testDateIsNeverClippedByTheSlot() throws {
        let text = try ForkIdentityTests.repoFile("Sources/DreaMail/UI/ThreadListView.swift")
        func squash(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        XCTAssertTrue(squash(text).contains(squash("""
            .fixedSize()
            .frame(minWidth: ThreadRowActionLayout.actionsWidth(fontScale: fontScale),
            alignment: .trailing)
            """)))
        XCTAssertFalse(text.contains(".frame(width: ThreadRowActionLayout"),
                       "a hard slot width clips long dates")
    }
}

final class SelectionBarActionTests: XCTestCase {
    func testActionsKeepTheOldOrderAndIds() {
        XCTAssertEqual(SelectionBarAction.allCases.map(\.rawValue),
                       ["archive", "trash", "star", "toggleRead"])
    }

    func testGlyphsAreTheOnesTheRowsAndToolbarAlreadyUse() {
        XCTAssertEqual(SelectionBarAction.archive.symbol(flag: false), "archivebox")
        XCTAssertEqual(SelectionBarAction.trash.symbol(flag: false), "trash")
        XCTAssertEqual(SelectionBarAction.star.symbol(flag: true), "star")
        XCTAssertEqual(SelectionBarAction.star.symbol(flag: false), "star.fill")
        XCTAssertEqual(SelectionBarAction.toggleRead.symbol(flag: true), "envelope.open")
        XCTAssertEqual(SelectionBarAction.toggleRead.symbol(flag: false), "envelope.badge")
    }

    func testLabelsFollowWhatTheClickDoes() {
        XCTAssertEqual(SelectionBarAction.archive.title(flag: true), "Archive")
        XCTAssertEqual(SelectionBarAction.trash.title(flag: false), "Trash")
        XCTAssertEqual(SelectionBarAction.star.title(flag: true), "Star")
        XCTAssertEqual(SelectionBarAction.star.title(flag: false), "Unstar")
        XCTAssertEqual(SelectionBarAction.toggleRead.title(flag: true), "Mark as read")
        XCTAssertEqual(SelectionBarAction.toggleRead.title(flag: false), "Mark as unread")
    }
}

final class SelectionBarTooltipTests: XCTestCase {
    func testTooltipKeepsTheShortcutWhenThereIsOne() {
        XCTAssertEqual(SelectionBarAction.archive.tooltip(flag: false, shortcut: "e"), "Archive selected (e)")
        XCTAssertEqual(SelectionBarAction.trash.tooltip(flag: false, shortcut: "#"), "Trash selected (#)")
        XCTAssertEqual(SelectionBarAction.star.tooltip(flag: true, shortcut: "s"), "Star selected (s)")
        XCTAssertEqual(SelectionBarAction.toggleRead.tooltip(flag: true, shortcut: nil), "Mark as read")
    }
}

final class SelectionBarStateTests: XCTestCase {
    private func thread(_ id: String, unread: Bool = false, starred: Bool = false,
                        trash: Bool = false) -> MailThread {
        MailThread(
            id: "a@x.com:\(id)", accountId: "a@x.com", gmailThreadId: id,
            subject: "S", snippet: "sn", fromDisplay: "F",
            lastDate: Date(), isUnread: unread, isStarred: starred,
            inInbox: !trash, inTrash: trash,
            labelIds: "INBOX", snoozeUntil: nil, participants: "F",
            messageCount: 1, hasAttachment: false, reminderAt: nil)
    }

    func testMixedSelectionActsOnTheUnstarredAndTheUnread() {
        let s = SelectionBarState(actionable: [thread("a", unread: true, starred: true),
                                               thread("b", unread: false, starred: false)])
        XCTAssertTrue(s.starring, "one unstarred row: the click stars")
        XCTAssertTrue(s.anyUnread, "one unread row: the click marks read")
        XCTAssertEqual(SelectionBarAction.star.title(flag: s.flag(for: .star)), "Star")
        XCTAssertEqual(SelectionBarAction.toggleRead.symbol(flag: s.flag(for: .toggleRead)), "envelope.open")
    }

    func testUniformSelectionFlipsTheActions() {
        let s = SelectionBarState(actionable: [thread("a", starred: true), thread("b", starred: true)])
        XCTAssertFalse(s.starring)
        XCTAssertFalse(s.anyUnread)
        XCTAssertEqual(SelectionBarAction.star.title(flag: s.flag(for: .star)), "Unstar")
        XCTAssertEqual(SelectionBarAction.toggleRead.title(flag: s.flag(for: .toggleRead)), "Mark as unread")
    }

    func testEverythingIsEnabledForLiveRows() {
        let s = SelectionBarState(actionable: [thread("a")])
        for action in SelectionBarAction.allCases { XCTAssertTrue(s.isEnabled(action)) }
    }

    func testNothingActionableDisablesEveryButton() {
        let s = SelectionBarState(actionable: [])
        for action in SelectionBarAction.allCases {
            XCTAssertFalse(s.isEnabled(action), "\(action) does nothing but show a notice")
        }
        XCTAssertEqual(SelectionBarAction.star.title(flag: s.flag(for: .star)), "Star")
    }

    func testTrashIsDisabledWhenEveryRowIsAlreadyInTheTrash() {
        let s = SelectionBarState(actionable: [thread("a", trash: true), thread("b", trash: true)])
        XCTAssertFalse(s.isEnabled(.trash), "trashChecked skips rows already in the Trash")
        XCTAssertTrue(s.isEnabled(.archive))
        XCTAssertTrue(s.isEnabled(.star))
        XCTAssertTrue(SelectionBarState(actionable: [thread("a", trash: true), thread("b")]).isEnabled(.trash))
    }

    func testTargetsAreAtLeast24PointsAndSquareAtEveryScale() {
        for scale in [0.8, 1.0, 1.25, 1.5, 2.0] {
            XCTAssertGreaterThanOrEqual(SelectionBarLayout.side(fontScale: scale), 24)
        }
        XCTAssertGreaterThan(SelectionBarLayout.spacing, ThreadRowActionLayout.spacing)
    }
}
