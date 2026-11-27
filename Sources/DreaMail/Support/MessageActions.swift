import Foundation
import GRDB

/// The actions on one message of an open conversation, as Gmail on the web
/// offers them in the message's header: time, star, reply, reply all and a
/// "More" menu (⋮). Pure — tested; `MessageCard` draws it and
/// `MailStore+MessageActions` runs it.
enum MessageActions {
    /// Gmail web's per-message "More" menu, in its order, keeping only what
    /// DreaMail really does. Left out on purpose: "Print" (needs the print
    /// entitlement, the owner's decision), "Add to Contacts list" (needs a
    /// Contacts permission DreaMail does not have), "Report phishing" and
    /// "Translate message" (they send the message to Google).
    enum MenuItem: Equatable, CaseIterable {
        case reply
        case replyAll
        case forward
        case filterLikeThis
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
        /// discarded draft). Nothing that acts on the conversation is
        /// offered: its live messages are not on screen (DEC-081).
        var isTrashed: Bool
    }

    static func menuItems(_ context: Context) -> [MenuItem] {
        var items: [MenuItem] = [.reply]
        if context.canReplyAll { items.append(.replyAll) }
        items += [.forward, .filterLikeThis]
        if !context.isTrashed { items.append(.deleteMessage) }
        if !context.fromSelf {
            items.append(context.senderBlocked ? .unblockSender : .blockSender)
        }
        if !context.isTrashed {
            items.append(context.threadInSpam ? .reportNotSpam : .reportSpam)
        }
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

    static func isStarred(_ message: Message) -> Bool {
        SyncEngine.labelIdsContain(message.labelIds, "STARRED")
    }

    /// Gmail ids "Mark unread from here" changes: this message and the
    /// later ones the pane shows, drafts left out. A message whose row
    /// still says unread is included: read on open writes only the thread
    /// row, so that row says nothing about what Gmail holds.
    static func unreadFromHereIds(in messages: [Message], from id: String) -> [String] {
        guard let start = messages.firstIndex(where: { $0.id == id }) else { return [] }
        return messages[start...]
            .filter { !TrashedMessages.isDraft($0) }
            .map(\.gmailId)
    }

    /// The From address "Filter messages like this" starts from, only when
    /// it is a plain address: Gmail reads the criterion as search syntax,
    /// so anything else (quotes, spaces, operators, braces) leaves the
    /// field empty for the user to fill.
    static func filterFromAddress(_ fromHeader: String) -> String {
        let email = MessageParser.emailAddress(fromHeader)
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              !parts[1].hasPrefix("."), !parts[1].hasSuffix("."), email.count <= 254
        else { return "" }
        let local = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._%+-")
        let domain = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        // A leading "-" would read as Gmail's "not" operator.
        let alphanumeric = CharacterSet.alphanumerics
        guard parts[0].unicodeScalars.allSatisfy(local.contains),
              parts[1].unicodeScalars.allSatisfy(domain.contains),
              let first = email.unicodeScalars.first, alphanumeric.contains(first),
              let domainFirst = parts[1].unicodeScalars.first, alphanumeric.contains(domainFirst)
        else { return "" }
        return email
    }

    /// Longest file name base "Download message" suggests, in UTF-8 bytes:
    /// with ".eml" it stays under the 255-byte limit of macOS volumes.
    static let filenameBaseByteLimit = 200

    /// The suggested file name for "Download message": the subject with
    /// path separators replaced, control and invisible formatting
    /// characters (bidi overrides among them) and leading dots dropped,
    /// cut to `filenameBaseByteLimit` bytes; ".eml" always last.
    static func downloadFilename(subject: String) -> String {
        var base = ""
        for scalar in subject.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator,
                 .surrogate, .privateUse, .unassigned:
                continue
            default:
                base.unicodeScalars.append(scalar == "/" || scalar == ":" ? "-" : scalar)
            }
        }
        base = base.trimmingCharacters(in: .whitespaces)
        while base.hasPrefix(".") { base.removeFirst() }
        base = base.trimmingCharacters(in: .whitespaces)
        var cut = ""
        for character in base {
            guard cut.utf8.count + String(character).utf8.count <= filenameBaseByteLimit else { break }
            cut.append(character)
        }
        cut = cut.trimmingCharacters(in: .whitespaces)
        return (cut.isEmpty ? "message" : cut) + ".eml"
    }

    /// What "Show original" displays: at most `limit` bytes of the raw
    /// message (a body with large attachments is megabytes of base64,
    /// slow to lay out), and whether it was cut. Bounded by bytes, so
    /// stacked combining marks cannot make it longer.
    static func originalPreview(_ raw: Data, limit: Int) -> (text: String, truncated: Bool) {
        (String(decoding: raw.prefix(limit), as: UTF8.self), raw.count > limit)
    }
}

/// Which messages a conversation opens on (Gmail, decided for DreaMail by
/// the orchestrator). Without a starred message the pane keeps its rule:
/// the newest message open and at the top. With one:
/// - open: the newest starred message, every unread message and the
///   newest message;
/// - at the top: the newest starred message, unless unread mail is newer
///   than it: then the oldest of those unread messages, so new mail is
///   never hidden below the fold.
/// Drafts never count; a starred message in the Trash does not either.
enum ConversationOpenTarget: Equatable {
    struct Target: Equatable {
        /// Message ids, in the pane's order.
        var expanded: [String]
        var scroll: String
    }

    /// `messages` oldest first, as the pane shows them. Nil without a
    /// starred message.
    static func target(in messages: [Message]) -> Target? {
        let candidates = messages.filter { !TrashedMessages.isDraft($0) }
        guard let starIndex = candidates.lastIndex(where: {
            MessageActions.isStarred($0) && !TrashedMessages.isTrashed($0)
        }) else { return nil }
        let last = candidates.count - 1
        let expanded = candidates.indices.filter {
            $0 == starIndex || $0 == last || candidates[$0].isUnread
        }
        let newerUnread = candidates.indices.first { $0 > starIndex && candidates[$0].isUnread }
        return Target(expanded: expanded.map { candidates[$0].id },
                      scroll: candidates[newerUnread ?? starIndex].id)
    }
}

/// What an action on one message does, decided from what is stored when it
/// runs. Pure over a database read — tested.
enum MessageActionPlan {
    /// Labels on exactly these Gmail message ids.
    struct Edit: Equatable, Sendable {
        var ids: [String]
        var add: [String] = []
        var remove: [String] = []
    }

    /// The message's stored row and its conversation.
    struct State: Sendable {
        var row: MailThread
        var message: Message
        /// Gmail ids outside the Trash, drafts left out.
        var liveIds: [String]
        var hasLiveDraft: Bool

        /// Nil when the message or its conversation is no longer stored.
        static func load(_ db: Database, message: Message) throws -> State? {
            guard let row = try MailThread.fetchOne(db, key: message.threadId),
                  let stored = try Message.fetchOne(db, key: message.id) else { return nil }
            let messages = try Row.fetchAll(db, sql: """
                SELECT gmailId, labelIds FROM message WHERE threadId = ?
                """, arguments: [message.threadId])
            var live: [String] = []
            var liveDraft = false
            for m in messages {
                let labels: String = m["labelIds"]
                let trashed = SyncEngine.labelIdsContain(labels, "TRASH")
                if SyncEngine.labelIdsContain(labels, "DRAFT") {
                    liveDraft = liveDraft || !trashed
                } else if !trashed {
                    live.append(m["gmailId"])
                }
            }
            return State(row: row, message: stored, liveIds: live, hasLiveDraft: liveDraft)
        }

        var isTrashed: Bool { TrashedMessages.isTrashed(message) }
        var isDraft: Bool { TrashedMessages.isDraft(message) }
    }

    static func toggleStar(_ state: State) -> Edit? {
        guard !state.isDraft else { return nil }
        let id = state.message.gmailId
        return MessageActions.isStarred(state.message)
            ? Edit(ids: [id], remove: ["STARRED"])
            : Edit(ids: [id], add: ["STARRED"])
    }

    enum Delete: Equatable {
        /// Nothing to do (a draft, or already in the Trash).
        case none
        /// Its last live message, no live draft left: the conversation's
        /// own Trash action.
        case conversation
        case message(Edit, undo: Edit)
    }

    static func delete(_ state: State) -> Delete {
        guard !state.isDraft, !state.isTrashed else { return .none }
        let id = state.message.gmailId
        if state.liveIds == [id], !state.hasLiveDraft { return .conversation }
        // Gmail drops INBOX from a trashed message; the undo puts it back
        // only where the message had it in a conversation in the Inbox.
        let wasInInbox = state.row.inInbox
            && SyncEngine.labelIdsContain(state.message.labelIds, "INBOX")
        return .message(Edit(ids: [id], add: ["TRASH"]),
                        undo: Edit(ids: [id], add: wasInInbox ? ["INBOX"] : [], remove: ["TRASH"]))
    }

    /// Conversation-wide actions (spam) only from a message outside the
    /// Trash: from the Trash view the live messages are not on screen.
    static func allowsConversationAction(_ state: State) -> Bool {
        !state.isTrashed
    }
}
