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
    /// Gmail's toolbar order; the old ids are kept. Star, the app's own
    /// (Gmail has it under More), comes last.
    func testActionsFollowGmailsOrderAndKeepTheOldIds() {
        XCTAssertEqual(SelectionBarAction.allCases.map(\.rawValue),
                       ["archive", "moveToInbox", "reportSpam", "notSpam", "trash",
                        "toggleRead", "snooze", "moveTo", "labelAs", "star"])
    }

    func testEveryGlyphIsTheRowMenusOwn() {
        let menu: [SelectionBarAction: ThreadRowMenuItem] = [
            .archive: .archive, .moveToInbox: .moveToInbox, .trash: .delete,
            .snooze: .snooze, .moveTo: .moveTo, .labelAs: .labelAs,
        ]
        for (action, item) in menu {
            XCTAssertEqual(action.symbol(flag: false), item.symbol, "\(action)")
        }
        XCTAssertEqual(SelectionBarAction.toggleRead.symbol(flag: true), ThreadRowMenuItem.markRead.symbol)
        XCTAssertEqual(SelectionBarAction.toggleRead.symbol(flag: false), ThreadRowMenuItem.markUnread.symbol)
        XCTAssertEqual(SelectionBarAction.star.symbol(flag: true), ThreadRowMenuItem.star.symbol)
        XCTAssertEqual(SelectionBarAction.star.symbol(flag: false), ThreadRowMenuItem.unstar.symbol)
        // Spam has no row menu item: the conversation toolbar's glyphs.
        XCTAssertEqual(SelectionBarAction.reportSpam.symbol(flag: false), "exclamationmark.octagon")
        XCTAssertEqual(SelectionBarAction.notSpam.symbol(flag: false), "tray")
        let glyphs = SelectionBarAction.allCases.filter { $0 != .toggleRead && $0 != .star }
            .map { $0.symbol(flag: false) }
        XCTAssertEqual(Set(glyphs).count, glyphs.count, "one glyph per action")
    }

    func testNewTitlesAreGmails() {
        XCTAssertEqual(SelectionBarAction.moveToInbox.title(flag: false), "Move to inbox")
        XCTAssertEqual(SelectionBarAction.reportSpam.title(flag: false), "Report spam")
        XCTAssertEqual(SelectionBarAction.notSpam.title(flag: false), "Not spam")
        XCTAssertEqual(SelectionBarAction.snooze.title(flag: false), "Snooze")
        XCTAssertEqual(SelectionBarAction.moveTo.title(flag: false), "Move to")
        XCTAssertEqual(SelectionBarAction.labelAs.title(flag: false), "Label as")
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
        XCTAssertEqual(SelectionBarAction.reportSpam.tooltip(flag: false, shortcut: "!"), "Report spam (!)")
        XCTAssertEqual(SelectionBarAction.labelAs.tooltip(flag: false, shortcut: "l"), "Label as (l)")
        XCTAssertEqual(SelectionBarAction.moveToInbox.tooltip(flag: false, shortcut: nil), "Move to inbox")
    }
}

final class SelectionBarStateTests: XCTestCase {
    private func thread(_ id: String, unread: Bool = false, starred: Bool = false,
                        trash: Bool = false, inbox: Bool? = nil, spam: Bool = false,
                        draftOnly: Bool = false, gmailSnoozed: Bool = false) -> MailThread {
        var t = MailThread(
            id: "a@x.com:\(id)", accountId: "a@x.com", gmailThreadId: id,
            subject: "S", snippet: "sn", fromDisplay: "F",
            lastDate: Date(), isUnread: unread, isStarred: starred,
            inInbox: inbox ?? (!trash && !spam && !draftOnly), inTrash: trash,
            labelIds: "INBOX", snoozeUntil: nil, participants: "F",
            messageCount: 1, hasAttachment: false, reminderAt: nil)
        t.inSpam = spam
        t.inDrafts = draftOnly
        t.gmailSnoozed = gmailSnoozed
        return t
    }

    func testInboxSelectionShowsGmailsBar() {
        let s = SelectionBarState(actionable: [thread("a"), thread("b")])
        XCTAssertEqual(s.actions, [.archive, .reportSpam, .trash, .toggleRead, .snooze,
                                   .moveTo, .labelAs, .star])
        for action in s.actions { XCTAssertTrue(s.isEnabled(action), "\(action)") }
    }

    func testArchivedSelectionOffersMoveToInbox() {
        let s = SelectionBarState(actionable: [thread("a", inbox: false), thread("b", inbox: false)])
        XCTAssertEqual(s.actions.first, .moveToInbox)
        XCTAssertFalse(s.actions.contains(.archive))
        XCTAssertTrue(s.isEnabled(.moveToInbox))
    }

    func testMixedInboxAndArchivedKeepsArchiveAsThePaletteDoes() {
        let s = SelectionBarState(actionable: [thread("a"), thread("b", inbox: false)])
        XCTAssertEqual(s.actions.first, .archive)
        XCTAssertFalse(s.actions.contains(.moveToInbox))
    }

    func testSpamViewShowsNotSpam() {
        let s = SelectionBarState(actionable: [thread("a", spam: true), thread("b", spam: true)])
        XCTAssertEqual(s.actions, [.archive, .notSpam, .trash, .toggleRead, .snooze,
                                   .moveTo, .labelAs, .star],
                       "spam is not offered Move to inbox (Not spam is its way out)")
        XCTAssertTrue(s.isEnabled(.notSpam))
        let mixed = SelectionBarState(actionable: [thread("a", spam: true), thread("b")])
        XCTAssertTrue(mixed.actions.contains(.reportSpam), "a mix reports all as spam, as `!` does")
        XCTAssertFalse(mixed.actions.contains(.notSpam))
    }

    func testTrashViewKeepsArchiveAndDisablesTrash() {
        let s = SelectionBarState(actionable: [thread("a", trash: true), thread("b", trash: true)])
        XCTAssertEqual(s.actions.first, .archive, "Trash rows are not offered Move to inbox")
        XCTAssertFalse(s.isEnabled(.trash))
        XCTAssertTrue(s.isEnabled(.moveTo))
        XCTAssertTrue(s.isEnabled(.reportSpam))
    }

    func testTrashCopiesOfLiveConversationsLeaveOnlyMoveTo() {
        // Every checked row is such a copy: nothing is actionable, but Move
        // to restores their trashed messages (DEC-081).
        let copies = [thread("a", trash: true), thread("b", trash: true)]
        let s = SelectionBarState(actionable: [], checked: copies)
        for action in s.actions where action != .moveTo {
            XCTAssertFalse(s.isEnabled(action), "\(action) would only show a notice")
        }
        XCTAssertTrue(s.isEnabled(.moveTo))
    }

    func testLoneDraftsHaveNoMailToArchiveSpamOrSnooze() {
        let s = SelectionBarState(actionable: [thread("a", draftOnly: true), thread("b", draftOnly: true)])
        XCTAssertEqual(s.actions.first, .archive, "a lone draft is not offered Move to inbox")
        for action in [SelectionBarAction.archive, .reportSpam, .snooze] {
            XCTAssertFalse(s.isEnabled(action), "\(action)")
        }
        for action in [SelectionBarAction.trash, .toggleRead, .moveTo, .labelAs, .star] {
            XCTAssertTrue(s.isEnabled(action), "\(action)")
        }
        let mixed = SelectionBarState(actionable: [thread("a", draftOnly: true), thread("b")])
        XCTAssertTrue(mixed.isEnabled(.reportSpam) && mixed.isEnabled(.snooze))
    }

    func testSnoozeIsOffWhenGmailOwnsEverySnooze() {
        let s = SelectionBarState(actionable: [thread("a", inbox: false, gmailSnoozed: true)])
        XCTAssertFalse(s.isEnabled(.snooze), "snoozeChecked leaves Gmail's snoozes to Gmail")
        let mixed = SelectionBarState(actionable: [thread("a", inbox: false, gmailSnoozed: true), thread("b")])
        XCTAssertTrue(mixed.isEnabled(.snooze))
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

    func testEveryStateShowsOneOfEachPair() {
        let rows = [thread("a"), thread("b", inbox: false), thread("c", spam: true),
                    thread("d", trash: true), thread("e", draftOnly: true)]
        for a in rows { for b in rows {
            let actions = SelectionBarState(actionable: [a, b]).actions
            XCTAssertEqual(actions.count, 8)
            XCTAssertEqual(actions.filter { $0 == .archive || $0 == .moveToInbox }.count, 1)
            XCTAssertEqual(actions.filter { $0 == .reportSpam || $0 == .notSpam }.count, 1)
            XCTAssertEqual(actions, SelectionBarAction.allCases.filter(actions.contains), "Gmail's order")
        } }
    }

    func testTargetsAreAtLeast24PointsAndSquareAtEveryScale() {
        for scale in [0.8, 1.0, 1.25, 1.5, 2.0] {
            XCTAssertGreaterThanOrEqual(SelectionBarLayout.side(fontScale: scale), 24)
        }
        XCTAssertGreaterThan(SelectionBarLayout.spacing, ThreadRowActionLayout.spacing)
    }
}

final class SelectionBarLayoutTests: XCTestCase {
    private typealias L = SelectionBarLayout
    // Widths of the demo bar at scale 1, rounded up: "2 selected",
    // "esc to clear", the close button.
    private let count = 66.0, hint = 66.0, close = 16.0

    private func fit(_ width: Double, actions: Int = 8, scale: Double = 1, count: Double? = nil) -> L.Fit {
        L.fit(actions: actions, barWidth: width, countWidth: count ?? self.count, hintWidth: hint,
              closeWidth: close, side: L.side(fontScale: scale))
    }

    /// What `fit` reserves, spelled out as the UI test measures it.
    private func needed(_ f: L.Fit, scale: Double = 1, count: Double? = nil) -> Double {
        let buttons = f.visible + (f.showsMore ? 1 : 0)
        let items = f.showsHint ? 5.0 : 4.0
        return 24 + (count ?? self.count) + (f.showsHint ? hint : 0) + 8
            + L.stripWidth(buttons, side: L.side(fontScale: scale)) + close + (items - 1) * 10
    }

    func testAWideColumnShowsEverything() {
        XCTAssertEqual(fit(800), L.Fit(visible: 8, showsMore: false, showsHint: true))
    }

    func testTheHintGoesBeforeAnyAction() {
        let f = fit(420)
        XCTAssertEqual(f, L.Fit(visible: 8, showsMore: false, showsHint: false),
                       "at the 420 pt minimum every action still fits, without the hint")
        XCTAssertLessThanOrEqual(needed(f), 420)
    }

    func testNarrowerOrLargerTextPutsTheTrailingActionsUnderMore() {
        for scale in [1.0, 1.25, 1.5, 2.0] {
            for width in stride(from: 200.0, through: 420, by: 10) {
                let f = fit(width, scale: scale)
                XCTAssertLessThanOrEqual(f.visible, 8)
                XCTAssertEqual(f.showsMore, f.visible < 8, "More only holds what did not fit")
                if f.visible > 0 || !f.showsMore {
                    XCTAssertLessThanOrEqual(needed(f, scale: scale), width, "\(width) pt at \(scale)×")
                }
                // The largest count that fits: one more button would not.
                if f.showsMore && f.visible < 7 {
                    let more = L.Fit(visible: f.visible + 1, showsMore: true, showsHint: false)
                    XCTAssertGreaterThan(needed(more, scale: scale), width)
                }
            }
        }
        let big = fit(420, scale: 1.5, count: 99)
        XCTAssertTrue(big.showsMore && !big.showsHint && big.visible > 0)
        XCTAssertLessThanOrEqual(needed(big, scale: 1.5, count: 99), 420,
                                 "the count keeps its full width at the minimum column")
    }

    func testMoreGrowsMonotonically() {
        var last = 0
        for width in stride(from: 200.0, through: 800, by: 5) {
            let f = fit(width)
            XCTAssertGreaterThanOrEqual(f.visible, last)
            last = f.visible
        }
    }

    func testUnmeasuredBarShowsEverything() {
        XCTAssertEqual(fit(0), L.Fit(visible: 8, showsMore: false, showsHint: true))
    }
}

final class BulkLabelTests: XCTestCase {
    private func thread(_ id: String, labels: String) -> MailThread {
        MailThread(
            id: "a@x.com:\(id)", accountId: "a@x.com", gmailThreadId: id,
            subject: "S", snippet: "sn", fromDisplay: "F",
            lastDate: Date(), isUnread: false, isStarred: false,
            inInbox: true, inTrash: false,
            labelIds: labels, snoozeUntil: nil, participants: "F",
            messageCount: 1, hasAttachment: false, reminderAt: nil)
    }

    func testStateAndClickFollowGmailsLabelMenu() {
        let both = [thread("a", labels: "INBOX L1"), thread("b", labels: "INBOX L1")]
        let one = [thread("a", labels: "INBOX L1"), thread("b", labels: "INBOX")]
        let none = [thread("a", labels: "INBOX"), thread("b", labels: "INBOX")]
        XCTAssertEqual(BulkLabel.state("L1", in: both), .all)
        XCTAssertEqual(BulkLabel.state("L1", in: one), .some)
        XCTAssertEqual(BulkLabel.state("L1", in: none), .none)
        XCTAssertFalse(BulkLabel.adds("L1", to: both), "on all: the click removes it from all")
        XCTAssertTrue(BulkLabel.adds("L1", to: one), "on some: the click adds it to the rest")
        XCTAssertTrue(BulkLabel.adds("L1", to: none))
    }
}
