import XCTest
import GRDB

/// The thread list row's context menu, after Gmail web's right-click menu:
/// groups, order, wording, glyphs and guards (`ThreadRowMenu`).
final class ThreadRowMenuTests: XCTestCase {
    private typealias S = ThreadRowMenu.State
    private let account = "ron@example.com"

    /// One-message conversations with these labels, derived as a sync does.
    private func threads(_ specs: [(id: String, labels: String)]) throws -> [MailThread] {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        return try q.write { db in
            try Account(id: self.account, displayName: "P", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
            var out: [MailThread] = []
            for (id, labels) in specs {
                let threadId = "\(self.account):\(id)"
                try Message(id: "\(self.account):m-\(id)", accountId: self.account,
                            gmailId: "m-\(id)", threadId: threadId,
                            fromHeader: "a@example.com", toHeader: self.account,
                            ccHeader: "", bccHeader: "", subject: "Hello",
                            date: Date(timeIntervalSince1970: 1_700_000_000),
                            snippet: "", bodyText: "", bodyHTML: nil, messageIdHeader: "",
                            referencesHeader: "", labelIds: labels,
                            isUnread: labels.contains("UNREAD"), hasAttachment: false).insert(db)
                try SyncEngine.deriveThreads(db, for: [threadId], accountId: self.account)
                out.append(try XCTUnwrap(try MailThread.fetchOne(db, key: threadId)))
            }
            return out
        }
    }

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

    /// A lone draft has nothing to reply to or forward.
    func testDraftOnlyRowHasNoReplyGroup() {
        let groups = ThreadRowMenu.groups(S(draftOnly: true))
        XCTAssertFalse(groups.joined().contains(.reply))
        XCTAssertFalse(groups.joined().contains(.replyAll))
        XCTAssertFalse(groups.joined().contains(.forward))
        XCTAssertEqual(groups.first, [.archive, .delete, .markUnread, .snooze])
    }

    /// Several checked rows: only the items with a bulk form, titled by the
    /// keys' bulk rules.
    func testCheckedSetShowsOnlyBulkItems() {
        let groups = ThreadRowMenu.groups(S(offersMoveToInbox: true, isUnread: true,
                                            hasSenderAddress: true, senderIsVIP: false,
                                            bulk: true))
        XCTAssertEqual(groups, [
            [.moveToInbox, .delete, .markRead, .snooze],
            [.moveTo, .mute],
            [.star],
        ])
    }

    /// The bulk state follows the keys: mark read if any is unread, unmute
    /// only when all are muted, star if any is unstarred, Move to inbox only
    /// when every one offers it; guards hold when they hold for all.
    func testBulkStateFollowsTheKeys() throws {
        let rows = try threads([("a", "Label_7 UNREAD MUTED"), ("b", "MUTED STARRED"), ("c", "INBOX")])
        let a = rows[0], b = rows[1], c = rows[2]
        let ab = S(threads: [a, b], isPartlyTrashed: { _ in false },
                   senderAddress: "x@example.com", senderIsVIP: true)
        XCTAssertTrue(ab.bulk)
        XCTAssertTrue(ab.offersMoveToInbox)
        XCTAssertTrue(ab.isUnread)
        XCTAssertTrue(ab.isMuted)
        XCTAssertFalse(ab.isStarred)
        XCTAssertFalse(ab.hasSenderAddress, "no sender search over a set")
        XCTAssertNil(ab.senderIsVIP)
        let abc = S(threads: [a, b, c], isPartlyTrashed: { $0.id == a.id },
                    senderAddress: nil, senderIsVIP: nil)
        XCTAssertFalse(abc.offersMoveToInbox, "a mix keeps Archive")
        XCTAssertFalse(abc.partlyTrashed, "one Trash copy does not disable the set")
        let one = S(threads: [a], isPartlyTrashed: { _ in false },
                    senderAddress: "x@example.com", senderIsVIP: false)
        XCTAssertFalse(one.bulk)
        XCTAssertTrue(one.hasSenderAddress)
        XCTAssertEqual(one.senderIsVIP, false)
    }

    /// Trash copies of a live conversation and conversations in the Trash
    /// keep their guards. Reply, Reply all and Forward are disabled on a
    /// Trash copy too: they would answer a live message the row does not
    /// show (DEC-081). This corrects the first version of this test, which
    /// asserted they stayed enabled.
    func testGuards() {
        let partly = S(inTrash: true, partlyTrashed: true)
        for item in [ThreadRowMenuItem.archive, .moveToInbox, .markRead, .markUnread, .snooze,
                     .star, .unstar, .mute, .unmute, .labelAs, .delete,
                     .reply, .replyAll, .forward] {
            XCTAssertTrue(ThreadRowMenu.isDisabled(item, partly), "\(item)")
        }
        for item in [ThreadRowMenuItem.moveTo, .findFromSender, .copyLink, .remindMe] {
            XCTAssertFalse(ThreadRowMenu.isDisabled(item, partly), "\(item)")
        }
        XCTAssertTrue(ThreadRowMenu.isDisabled(.delete, S(inTrash: true)))
        XCTAssertFalse(ThreadRowMenu.isDisabled(.archive, S(inTrash: true)))
        XCTAssertFalse(ThreadRowMenu.isDisabled(.delete, S()))
        XCTAssertFalse(ThreadRowMenu.isDisabled(.reply, S()))
    }

    /// One action, one glyph: the expected symbols are written out here, and
    /// each independent source (the menu table, the row's hover buttons, the
    /// VIP menu, the palette) is held to them.
    func testOneActionOneGlyphAcrossSources() {
        let expected: [ThreadRowMenuItem: String] = [
            .reply: "arrowshape.turn.up.left", .replyAll: "arrowshape.turn.up.left.2",
            .forward: "arrowshape.turn.up.right", .moveToInbox: "tray.and.arrow.down",
            .archive: "archivebox", .delete: "trash", .markUnread: "envelope.badge",
            .markRead: "envelope.open", .snooze: "clock", .moveTo: "folder", .labelAs: "tag",
            .mute: "bell.slash", .unmute: "bell", .findFromSender: "magnifyingglass",
            .star: "star", .unstar: "star.fill", .remindMe: "alarm",
            .addVIP: "star.circle", .removeVIP: "star.circle.fill", .copyLink: "link",
        ]
        XCTAssertEqual(Set(expected.keys), Set(ThreadRowMenuItem.allCases))
        for item in ThreadRowMenuItem.allCases {
            XCTAssertEqual(item.symbol, expected[item], "\(item)")
        }
        // The hover buttons' own table.
        let hover = ThreadRowHoverAction.self
        XCTAssertEqual(hover.archive.symbol(isUnread: false), expected[.archive])
        XCTAssertEqual(hover.archive.symbol(isUnread: false, movesToInbox: true), expected[.moveToInbox])
        XCTAssertEqual(hover.trash.symbol(isUnread: false), expected[.delete])
        XCTAssertEqual(hover.toggleRead.symbol(isUnread: false), expected[.markUnread])
        XCTAssertEqual(hover.toggleRead.symbol(isUnread: true), expected[.markRead])
        XCTAssertEqual(hover.snooze.symbol(isUnread: false), expected[.snooze])
        // The VIP menu's own table.
        XCTAssertEqual(ParticipantMenuVIP.systemImage(for: .add(email: "a@example.com")), expected[.addVIP])
        XCTAssertEqual(ParticipantMenuVIP.systemImage(for: .remove(email: "a@example.com")),
                       expected[.removeVIP])
        // The palette, unstarred and unread / starred, read and muted.
        func icons(_ t: PaletteCommands.ThreadState) -> [String: String] {
            var ctx = PaletteCommands.Context()
            ctx.focused = t
            return Dictionary(PaletteCommands.entries(ctx).map { ($0.id, $0.icon) },
                              uniquingKeysWith: { a, _ in a })
        }
        let plain = icons(.init(isUnread: true))
        XCTAssertEqual(plain["act.archive"], expected[.archive])
        XCTAssertEqual(plain["act.trash"], expected[.delete])
        XCTAssertEqual(plain["act.star"], expected[.star])
        XCTAssertEqual(plain["act.read"], expected[.markRead])
        XCTAssertEqual(plain["act.snooze"], expected[.snooze])
        XCTAssertEqual(plain["act.reply"], expected[.reply])
        XCTAssertEqual(plain["act.replyAll"], expected[.replyAll])
        XCTAssertEqual(plain["act.forward"], expected[.forward])
        XCTAssertEqual(plain["act.label"], expected[.labelAs])
        XCTAssertEqual(plain["act.move"], expected[.moveTo])
        XCTAssertEqual(plain["act.mute"], expected[.mute])
        XCTAssertEqual(plain["act.copyLink"], expected[.copyLink])
        // "Snooze Until…" picks a date: its own glyph, on purpose.
        XCTAssertEqual(plain["act.snoozeCustom"], "calendar.badge.clock")
        let flagged = icons(.init(isStarred: true, isUnread: false, isMuted: true))
        XCTAssertEqual(flagged["act.star"], expected[.unstar])
        XCTAssertEqual(flagged["act.read"], expected[.markUnread])
        XCTAssertEqual(flagged["act.mute"], expected[.unmute])
        XCTAssertEqual(icons(.init(offersMoveToInbox: true))["act.moveToInbox"], expected[.moveToInbox])
    }
}
