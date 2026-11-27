import Foundation

/// One conversation action as the menus and toolbars show it: Gmail's
/// wording for the list row's context menu, and one SF Symbol per action,
/// read by the row menu, the conversation toolbar and the command palette,
/// so one action has one glyph across the app (the row's hover buttons keep
/// their own table, `ThreadRowHoverAction`; a test holds the two together).
/// Monochrome (DEC-021).
enum ThreadRowMenuItem: String, CaseIterable, Hashable {
    // Gmail's groups.
    case reply, replyAll, forward
    case moveToInbox, archive, delete, markUnread, markRead, snooze
    case moveTo, labelAs, mute, unmute
    case findFromSender
    // The app's own items, kept after Gmail's groups.
    case star, unstar, remindMe, addVIP, removeVIP, copyLink

    /// Gmail's wording. `sender`: the row's sender display name, already
    /// cleaned (`SenderSearch.displayName`). Move to and Label as open the
    /// app's pickers (Gmail shows submenus), hence the ellipsis. The VIP
    /// titles carry the address and come from `ParticipantMenuVIP`.
    func title(sender: String = "") -> String {
        switch self {
        case .reply: return "Reply"
        case .replyAll: return "Reply all"
        case .forward: return "Forward"
        case .moveToInbox: return InboxMove.title
        case .archive: return "Archive"
        case .delete: return "Delete"
        case .markUnread: return "Mark as unread"
        case .markRead: return "Mark as read"
        case .snooze: return "Snooze"
        case .moveTo: return "Move to…"
        case .labelAs: return "Label as…"
        case .mute: return "Mute"
        case .unmute: return "Unmute"
        case .findFromSender: return "Find emails from \(sender)"
        case .star: return "Star"
        case .unstar: return "Unstar"
        case .remindMe: return "Remind me"
        case .addVIP: return "Add to VIPs"
        case .removeVIP: return "Remove from VIPs"
        case .copyLink: return "Copy Gmail link"
        }
    }

    var symbol: String {
        switch self {
        case .reply: return "arrowshape.turn.up.left"
        case .replyAll: return "arrowshape.turn.up.left.2"
        case .forward: return "arrowshape.turn.up.right"
        case .moveToInbox: return InboxMove.symbol
        case .archive: return "archivebox"
        case .delete: return "trash"
        case .markUnread: return "envelope.badge"
        case .markRead: return "envelope.open"
        case .snooze: return "clock"
        case .moveTo: return "folder"
        case .labelAs: return "tag"
        case .mute: return "bell.slash"
        case .unmute: return "bell"
        case .findFromSender: return "magnifyingglass"
        case .star: return "star"
        case .unstar: return "star.fill"
        // No reminder action elsewhere has a glyph (the row's indicator is
        // `bell.fill`, too close to Unmute's `bell`).
        case .remindMe: return "alarm"
        case .addVIP: return "star.circle"
        case .removeVIP: return "star.circle.fill"
        case .copyLink: return "link"
        }
    }
}

/// Which items the row's menu shows, in which groups (a divider between
/// groups), and which are disabled. Pure; `ThreadListView.threadMenu`
/// builds the menu from it. A live draft's Edit / Delete Draft group stays
/// on top, as before.
///
/// Right-clicking one of several checked rows acts on the checked set, as
/// Gmail does: only the items with a bulk form are shown (Reply, Forward,
/// Find emails from, Label as, Remind me, VIP and the link need one
/// conversation), and their titles follow the bulk rules of the keys.
enum ThreadRowMenu {
    struct State: Equatable {
        var offersMoveToInbox = false
        var isUnread = false
        var isMuted = false
        var isStarred = false
        var inTrash = false
        /// A Trash copy of an otherwise live conversation
        /// (`MailStore.isPartlyTrashedRow`).
        var partlyTrashed = false
        /// The only message is the user's draft: nothing to reply to.
        var draftOnly = false
        /// The sender's strict address (`SenderSearch.strictAddress`).
        var hasSenderAddress = false
        /// nil: no VIP item (own address, or none).
        var senderIsVIP: Bool? = nil
        /// The menu acts on several checked conversations.
        var bulk = false

        /// The state of a menu over `threads`: one row, or the checked set
        /// it belongs to. Bulk titles follow the keys: mark read if any is
        /// unread, unmute only if all are muted, star if any is unstarred.
        /// The guards hold when they hold for every target (the store
        /// leaves the others out and says so).
        init(threads: [MailThread], isPartlyTrashed: (MailThread) -> Bool,
             senderAddress: String?, senderIsVIP: Bool?) {
            let one = threads.count == 1
            offersMoveToInbox = InboxMove.offered(for: threads)
            isUnread = threads.contains { $0.isUnread }
            isMuted = !threads.isEmpty && threads.allSatisfy(\.isMuted)
            isStarred = !threads.isEmpty && threads.allSatisfy(\.isStarred)
            inTrash = !threads.isEmpty && threads.allSatisfy(\.inTrash)
            partlyTrashed = !threads.isEmpty && threads.allSatisfy(isPartlyTrashed)
            draftOnly = one && threads.allSatisfy(InboxMove.isDraftOnly)
            hasSenderAddress = one && senderAddress != nil
            self.senderIsVIP = one ? senderIsVIP : nil
            bulk = !one
        }

        init(offersMoveToInbox: Bool = false, isUnread: Bool = false, isMuted: Bool = false,
             isStarred: Bool = false, inTrash: Bool = false, partlyTrashed: Bool = false,
             draftOnly: Bool = false, hasSenderAddress: Bool = false,
             senderIsVIP: Bool? = nil, bulk: Bool = false) {
            self.offersMoveToInbox = offersMoveToInbox
            self.isUnread = isUnread
            self.isMuted = isMuted
            self.isStarred = isStarred
            self.inTrash = inTrash
            self.partlyTrashed = partlyTrashed
            self.draftOnly = draftOnly
            self.hasSenderAddress = hasSenderAddress
            self.senderIsVIP = senderIsVIP
            self.bulk = bulk
        }
    }

    static func groups(_ s: State) -> [[ThreadRowMenuItem]] {
        var out: [[ThreadRowMenuItem]] = []
        if !s.bulk && !s.draftOnly { out.append([.reply, .replyAll, .forward]) }
        out.append([s.offersMoveToInbox ? .moveToInbox : .archive, .delete,
                    s.isUnread ? .markRead : .markUnread, .snooze])
        out.append(s.bulk ? [.moveTo, s.isMuted ? .unmute : .mute]
                          : [.moveTo, .labelAs, s.isMuted ? .unmute : .mute])
        if !s.bulk && s.hasSenderAddress { out.append([.findFromSender]) }
        var own: [ThreadRowMenuItem] = [s.isStarred ? .unstar : .star]
        if !s.bulk {
            own.append(.remindMe)
            if let vip = s.senderIsVIP { own.append(vip ? .removeVIP : .addVIP) }
            own.append(.copyLink)
        }
        out.append(own)
        return out
    }

    /// The guards: a Trash copy of a live conversation takes no thread-wide
    /// action and no reply or forward (it would answer a live message the
    /// row does not show, DEC-081); Move to restores its trashed messages,
    /// search and the link still work. A conversation in the Trash is not
    /// trashed again.
    static func isDisabled(_ item: ThreadRowMenuItem, _ s: State) -> Bool {
        switch item {
        case .archive, .moveToInbox, .markRead, .markUnread, .snooze, .star, .unstar,
             .mute, .unmute, .labelAs, .reply, .replyAll, .forward:
            return s.partlyTrashed
        case .delete:
            return s.inTrash || s.partlyTrashed
        default:
            return false
        }
    }
}
