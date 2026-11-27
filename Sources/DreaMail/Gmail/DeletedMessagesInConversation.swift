import Foundation
import GRDB

/// What the reading pane of a live conversation says about its deleted
/// messages: Gmail web's "N deleted messages in this conversation. View
/// message" line. The count and the line come with the payload (no mail
/// content); the messages themselves are read only when the user presses
/// "View", outside the payload, the reader cache and the mirror, so quoting,
/// the summary, export and MCP never see them (`TrashedMessages.shown`).
struct DeletedMessagesSummary: Equatable, Sendable {
    var count: Int
    /// Date of the oldest deleted message: where the line sits.
    var firstDate: Date
    /// Their message ids (no content): a different set with the same count
    /// still reads the shown messages again.
    var messageIds: [String] = []
}

/// The deleted messages "View" shows, read apart from the payload.
struct DeletedMessagesLoad: Sendable {
    var messages: [Message]
    var attachmentsByMessageId: [String: [AttachmentRow]]
    var bodyPrepByMessageId: [String: MessageHTMLPrep]

    static let empty = DeletedMessagesLoad(
        messages: [], attachmentsByMessageId: [:], bodyPrepByMessageId: [:])
}

enum DeletedMessagesInConversation {
    /// Row id of the line (and the UI test's anchor).
    static let lineId = "deletedMessagesLine"

    /// The non-draft messages left out of the live conversation: trashed
    /// ones that `TrashedMessages.shown` drops. None for a conversation in
    /// the trash, or when only trashed messages are left (it shows them).
    /// Discarded drafts (DRAFT + TRASH) are not counted, as in the Trash
    /// view (`TrashedMessages.trashedIds`).
    static func deleted(_ messages: [Message], threadInTrash: Bool) -> [Message] {
        let shownIds = Set(TrashedMessages.shown(messages, threadInTrash: threadInTrash).map(\.id))
        return messages.filter {
            !shownIds.contains($0.id) && TrashedMessages.isTrashed($0) && !TrashedMessages.isDraft($0)
        }
    }

    /// The line's facts, or nil when there is no line.
    static func summary(_ messages: [Message], threadInTrash: Bool) -> DeletedMessagesSummary? {
        let gone = deleted(messages, threadInTrash: threadInTrash)
        guard let first = gone.map(\.date).min() else { return nil }
        return DeletedMessagesSummary(count: gone.count, firstDate: first, messageIds: gone.map(\.id))
    }

    /// The line's text (and accessibility label). No mail content.
    static func label(count: Int) -> String {
        count == 1
            ? "1 deleted message in this conversation"
            : "\(count) deleted messages in this conversation"
    }

    enum Row: Identifiable, Equatable {
        case message(Message, inTrash: Bool)
        case line

        var id: String {
            switch self {
            case .message(let message, _): return message.id
            case .line: return DeletedMessagesInConversation.lineId
            }
        }
    }

    /// The pane's rows in order. `live` is the conversation as shown (date
    /// order); `deleted` the messages "View" loaded, used only while
    /// `showing`. The line sits where the first deleted message is (by
    /// date; on a tie, after the live message). While showing, the deleted
    /// messages are merged in by date and the line stays just above the
    /// first of them.
    static func rows(live: [Message], deleted: [Message],
                     summary: DeletedMessagesSummary?, showing: Bool) -> [Row] {
        var rows = live.map { Row.message($0, inTrash: false) }
        guard let summary, summary.count > 0 else { return rows }
        let liveIds = Set(live.map(\.id))
        // A restored message is live again: shown once, as live.
        let extra = showing ? deleted.filter { !liveIds.contains($0.id) } : []
        let firstDate = extra.map(\.date).min() ?? summary.firstDate
        for message in extra.sorted(by: { $0.date < $1.date }) {
            let at = rows.firstIndex { row in
                if case .message(let m, _) = row { return m.date > message.date }
                return false
            } ?? rows.count
            rows.insert(.message(message, inTrash: true), at: at)
        }
        let lineAt = rows.firstIndex { row in
            switch row {
            case .message(let m, let inTrash): return inTrash || m.date > firstDate
            case .line: return false
            }
        } ?? rows.count
        rows.insert(.line, at: lineAt)
        return rows
    }

    /// "Restore" (one message) or "Restore all": the named messages leave
    /// the trash, and go back to the Inbox only when the conversation is
    /// there. Per message (`messages.batchModify` on these ids), like the
    /// Trash view's "Move to"; the conversation's other messages are not
    /// touched.
    static func restoreChange(gmailIds: [String], conversationInInbox: Bool) -> RemoteThreadChange {
        .modifyMessages(ids: gmailIds, add: conversationInInbox ? ["INBOX"] : [], remove: ["TRASH"])
    }

    /// The deleted messages of `threadId` with their stored bodies and
    /// attachments, date order. Local rows only: no request. Empty for a
    /// conversation in the trash.
    static func load(_ db: Database, threadId: String) throws
        -> (messages: [Message], attachments: [String: [AttachmentRow]]) {
        let threadInTrash = try Bool.fetchOne(
            db, sql: "SELECT inTrash FROM thread WHERE id = ?", arguments: [threadId]) ?? false
        let all = try Message.filter(Column("threadId") == threadId)
            .order(Column("date")).fetchAll(db)
        var gone = deleted(all, threadInTrash: threadInTrash)
        guard !gone.isEmpty else { return ([], [:]) }
        let ids = gone.map(\.id)
        let bodies = try MessageBody.filter(ids.contains(Column("messageId"))).fetchAll(db)
        let byId = Dictionary(uniqueKeysWithValues: bodies.map { ($0.messageId, $0) })
        for index in gone.indices {
            if let body = byId[gone[index].id] {
                gone[index].bodyText = body.bodyText
                gone[index].bodyHTML = body.bodyHTML
            }
        }
        let attachments = try AttachmentRow.filter(ids.contains(Column("messageId")))
            .order(Column("id")).fetchAll(db)
        return (gone, Dictionary(grouping: attachments, by: \.messageId))
    }
}
