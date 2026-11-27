import Foundation

/// The actions on one message of an open conversation, as Gmail on the web
/// offers them in the message's header: time, star, reply, reply all and a
/// "More" menu (⋮). Pure — tested; `MessageCard` draws it and
/// `MailStore+MessageActions` runs it.
enum MessageActions {
    /// Gmail web's per-message "More" menu, in its order, keeping only what
    /// DreaMail really does. Left out on purpose: "Add to Contacts list"
    /// (needs a Contacts permission DreaMail does not have), "Report
    /// phishing" and "Translate message" (they send the message to Google).
    enum MenuItem: Equatable, CaseIterable {
        case reply
        case replyAll
        case forward
        case filterLikeThis
        case print
        case deleteMessage
        case blockSender
        case unblockSender
        case reportSpam
        case reportNotSpam
        case showOriginal
        case downloadMessage
        case markUnreadFromHere
    }

    /// What the menu depends on, read from the message and the store.
    struct Context: Equatable {
        var canReplyAll: Bool
        /// The sender is one of the user's own addresses.
        var fromSelf: Bool
        var senderBlocked: Bool
        var threadInSpam: Bool
        /// The message is in the Trash (read from the Trash view, or a
        /// discarded draft): there is nothing to delete.
        var isTrashed: Bool
    }

    static func menuItems(_ context: Context) -> [MenuItem] {
        var items: [MenuItem] = [.reply]
        if context.canReplyAll { items.append(.replyAll) }
        items += [.forward, .filterLikeThis, .print]
        if !context.isTrashed { items.append(.deleteMessage) }
        if !context.fromSelf {
            items.append(context.senderBlocked ? .unblockSender : .blockSender)
        }
        items.append(context.threadInSpam ? .reportNotSpam : .reportSpam)
        items += [.showOriginal, .downloadMessage, .markUnreadFromHere]
        return items
    }

    /// Gmail web's wording (English).
    static func title(_ item: MenuItem, senderName: String) -> String {
        switch item {
        case .reply: return "Reply"
        case .replyAll: return "Reply to all"
        case .forward: return "Forward"
        case .filterLikeThis: return "Filter messages like this"
        case .print: return "Print"
        case .deleteMessage: return "Delete this message"
        case .blockSender: return "Block \"\(senderName)\""
        case .unblockSender: return "Unblock \"\(senderName)\""
        case .reportSpam: return "Report spam"
        case .reportNotSpam: return "Report not spam"
        case .showOriginal: return "Show original"
        case .downloadMessage: return "Download message"
        case .markUnreadFromHere: return "Mark unread from here"
        }
    }

    static func isDraft(_ message: Message) -> Bool {
        SyncEngine.labelIdsContain(message.labelIds, "DRAFT")
    }

    static func isStarred(_ message: Message) -> Bool {
        SyncEngine.labelIdsContain(message.labelIds, "STARRED")
    }

    /// The message a conversation opens on: its newest starred message
    /// (Gmail), else nil and the pane keeps its default, the newest
    /// message. `messages` oldest first, as the pane shows them.
    static func starredOpenTarget(in messages: [Message]) -> Message? {
        messages.last { !isDraft($0) && !TrashedMessages.isTrashed($0) && isStarred($0) }
    }

    /// Gmail ids "Mark unread from here" changes: this message and the
    /// later ones the pane shows, drafts left out, those not unread yet.
    static func unreadFromHereIds(in messages: [Message], from id: String) -> [String] {
        guard let start = messages.firstIndex(where: { $0.id == id }) else { return [] }
        return messages[start...]
            .filter { !isDraft($0) && !$0.isUnread }
            .map(\.gmailId)
    }

    /// The suggested file name for "Download message".
    static func downloadFilename(subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = MessageParser.safeFilename(trimmed.isEmpty ? "message" : trimmed)
        return base + ".eml"
    }

    /// The text "Print" lays out: the headers Gmail prints, then the body
    /// as text (never the HTML: printing must not load remote content).
    static func printableText(_ message: Message) -> String {
        var lines: [String] = []
        lines.append(message.subject.isEmpty ? "(no subject)" : message.subject)
        lines.append("")
        lines.append("From: \(message.fromHeader)")
        if !message.toHeader.isEmpty { lines.append("To: \(message.toHeader)") }
        if !message.ccHeader.isEmpty { lines.append("Cc: \(message.ccHeader)") }
        lines.append("Date: \(message.date.formatted(date: .complete, time: .shortened))")
        lines.append("")
        let text = message.bodyText.isEmpty
            ? MessageParser.stripHTML(message.bodyHTML ?? "")
            : message.bodyText
        lines.append(text)
        return lines.joined(separator: "\n")
    }
}
