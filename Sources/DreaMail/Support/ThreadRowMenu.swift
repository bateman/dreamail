import Foundation

/// One item of the thread list row's context menu. Wording, order and
/// grouping follow Gmail web's right-click menu on a conversation; each item
/// has the SF Symbol the app already uses for that action elsewhere (row
/// hover buttons, conversation toolbar, participant menu), so one action has
/// one glyph. Monochrome (DEC-021).
enum ThreadRowMenuItem: String, CaseIterable, Hashable {
    // Gmail's groups.
    case reply, replyAll, forward
    case moveToInbox, archive, delete, markUnread, markRead, snooze
    case moveTo, labelAs, mute, unmute
    case findFromSender
    // The app's own items, kept after Gmail's groups.
    case star, unstar, remindMe, addVIP, removeVIP, copyLink

    /// Gmail's wording. `sender`: the row's sender display name, for
    /// "Find emails from …". Move to and Label as open the app's pickers
    /// (Gmail shows submenus), hence the ellipsis. The VIP titles carry the
    /// address and come from `ParticipantMenuVIP`.
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
        case .archive: return ThreadRowHoverAction.archive.symbol(isUnread: false)
        case .delete: return ThreadRowHoverAction.trash.symbol(isUnread: false)
        case .markUnread: return ThreadRowHoverAction.toggleRead.symbol(isUnread: false)
        case .markRead: return ThreadRowHoverAction.toggleRead.symbol(isUnread: true)
        case .snooze: return ThreadRowHoverAction.snooze.symbol(isUnread: false)
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
        case .addVIP: return ParticipantMenuVIP.systemImage(for: .add(email: ""))
        case .removeVIP: return ParticipantMenuVIP.systemImage(for: .remove(email: ""))
        case .copyLink: return "link"
        }
    }
}

/// Which items the row's menu shows, in which groups (a divider between
/// groups), and which are disabled. Pure; `ThreadListView.threadMenu`
/// builds the menu from it. A live draft's Edit / Delete Draft group stays
/// on top, as before.
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
        /// The row's sender has an address to search for.
        var hasSenderAddress = false
        /// nil: no VIP item (own address, or none).
        var senderIsVIP: Bool? = nil
    }

    static func groups(_ s: State) -> [[ThreadRowMenuItem]] {
        var out: [[ThreadRowMenuItem]] = [
            [.reply, .replyAll, .forward],
            [s.offersMoveToInbox ? .moveToInbox : .archive, .delete,
             s.isUnread ? .markRead : .markUnread, .snooze],
            [.moveTo, .labelAs, s.isMuted ? .unmute : .mute],
        ]
        if s.hasSenderAddress { out.append([.findFromSender]) }
        var own: [ThreadRowMenuItem] = [s.isStarred ? .unstar : .star, .remindMe]
        if let vip = s.senderIsVIP { own.append(vip ? .removeVIP : .addVIP) }
        own.append(.copyLink)
        out.append(own)
        return out
    }

    /// The guards the menu had: a Trash copy of a live conversation takes no
    /// thread-wide action (Move to restores its messages; reply, forward,
    /// search and the link still work), and a conversation in the Trash is
    /// not trashed again.
    static func isDisabled(_ item: ThreadRowMenuItem, _ s: State) -> Bool {
        switch item {
        case .archive, .moveToInbox, .markRead, .markUnread, .snooze, .star, .unstar,
             .mute, .unmute, .labelAs:
            return s.partlyTrashed
        case .delete:
            return s.inTrash || s.partlyTrashed
        default:
            return false
        }
    }
}
