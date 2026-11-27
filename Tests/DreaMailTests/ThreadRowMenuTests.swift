import XCTest

/// The thread list row's context menu, after Gmail web's right-click menu:
/// groups, order, wording, glyphs and guards (`ThreadRowMenu`).
final class ThreadRowMenuTests: XCTestCase {
    private typealias S = ThreadRowMenu.State

    func testArchivedRowFollowsGmailsMenu() {
        let groups = ThreadRowMenu.groups(S(offersMoveToInbox: true, isUnread: false,
                                            hasSenderAddress: true, senderIsVIP: false))
        XCTAssertEqual(groups, [
            [.reply, .replyAll, .forward],
            [.moveToInbox, .delete, .markUnread, .snooze],
            [.moveTo, .labelAs, .mute],
            [.findFromSender],
            [.star, .remindMe, .addVIP, .copyLink],
        ])
        XCTAssertEqual(groups.flatMap { $0 }.map { $0.title(sender: "Alex Sample") }, [
            "Reply", "Reply all", "Forward",
            "Move to inbox", "Delete", "Mark as unread", "Snooze",
            "Move to…", "Label as…", "Mute",
            "Find emails from Alex Sample",
            "Star", "Remind me", "Add to VIPs", "Copy Gmail link",
        ])
    }

    func testInboxRowHasArchiveInTheSameSlotAndStatefulTitles() {
        let groups = ThreadRowMenu.groups(S(offersMoveToInbox: false, isUnread: true,
                                            isMuted: true, isStarred: true,
                                            hasSenderAddress: true, senderIsVIP: true))
        XCTAssertEqual(groups[1], [.archive, .delete, .markRead, .snooze])
        XCTAssertEqual(groups[2], [.moveTo, .labelAs, .unmute])
        XCTAssertEqual(groups.last, [.unstar, .remindMe, .removeVIP, .copyLink])
        XCTAssertFalse(groups.joined().contains(.moveToInbox))
    }

    func testNoSenderAddressOrOwnAddressDropsThoseItems() {
        let groups = ThreadRowMenu.groups(S())
        XCTAssertFalse(groups.joined().contains(.findFromSender))
        XCTAssertFalse(groups.joined().contains(.addVIP))
        XCTAssertFalse(groups.joined().contains(.removeVIP))
        XCTAssertEqual(groups.count, 4)
    }

    /// Trash copies of a live conversation and conversations in the Trash
    /// keep the guards they had.
    func testGuards() {
        let partly = S(inTrash: true, partlyTrashed: true)
        for item in [ThreadRowMenuItem.archive, .moveToInbox, .markRead, .markUnread, .snooze,
                     .star, .unstar, .mute, .unmute, .labelAs, .delete] {
            XCTAssertTrue(ThreadRowMenu.isDisabled(item, partly), "\(item)")
        }
        for item in [ThreadRowMenuItem.reply, .replyAll, .forward, .moveTo, .findFromSender,
                     .copyLink, .remindMe] {
            XCTAssertFalse(ThreadRowMenu.isDisabled(item, partly), "\(item)")
        }
        XCTAssertTrue(ThreadRowMenu.isDisabled(.delete, S(inTrash: true)))
        XCTAssertFalse(ThreadRowMenu.isDisabled(.archive, S(inTrash: true)))
        XCTAssertFalse(ThreadRowMenu.isDisabled(.delete, S()))
    }

    /// Every item has a glyph, and an action shows the one it has elsewhere.
    func testEveryItemHasTheGlyphItHasElsewhere() {
        for item in ThreadRowMenuItem.allCases {
            XCTAssertFalse(item.symbol.isEmpty, "\(item)")
        }
        let hover = ThreadRowHoverAction.self
        XCTAssertEqual(ThreadRowMenuItem.archive.symbol, hover.archive.symbol(isUnread: false))
        XCTAssertEqual(ThreadRowMenuItem.moveToInbox.symbol,
                       hover.archive.symbol(isUnread: false, movesToInbox: true))
        XCTAssertEqual(ThreadRowMenuItem.moveToInbox.symbol, InboxMove.symbol)
        XCTAssertEqual(ThreadRowMenuItem.delete.symbol, hover.trash.symbol(isUnread: false))
        XCTAssertEqual(ThreadRowMenuItem.markUnread.symbol, hover.toggleRead.symbol(isUnread: false))
        XCTAssertEqual(ThreadRowMenuItem.markRead.symbol, hover.toggleRead.symbol(isUnread: true))
        XCTAssertEqual(ThreadRowMenuItem.snooze.symbol, hover.snooze.symbol(isUnread: false))
        XCTAssertEqual(ThreadRowMenuItem.addVIP.symbol,
                       ParticipantMenuVIP.systemImage(for: .add(email: "a@example.com")))
        XCTAssertEqual(ThreadRowMenuItem.removeVIP.symbol,
                       ParticipantMenuVIP.systemImage(for: .remove(email: "a@example.com")))
        // The palette's Move to row uses the same folder.
        var ctx = PaletteCommands.Context()
        ctx.focused = PaletteCommands.ThreadState()
        XCTAssertEqual(PaletteCommands.entries(ctx).first { $0.id == "act.move" }?.icon,
                       ThreadRowMenuItem.moveTo.symbol)
    }
}
