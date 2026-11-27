import Foundation
import AppKit
import GRDB

/// Actions on one message of an open conversation (`MessageActions`): the
/// star in its header and its "More" menu. Label edits go through the one
/// per-message path (`editMessageLabels`, `messages.batchModify`); nothing
/// here deletes a message permanently. What each action decides is
/// `MessageActionPlan`, tested against the database.
extension MailStore {
    /// Gmail's star on this message only (its STARRED label), toggled from
    /// its stored state when the action runs: a quick second click undoes
    /// the first instead of starring again. The conversation shows as
    /// starred while any of its messages is.
    func toggleMessageStar(_ message: Message) {
        runMessageAction(message) { state in
            guard let edit = MessageActionPlan.toggleStar(state) else { return nil }
            return self.editMessageLabels([(row: state.row, ids: edit.ids)], add: edit.add,
                                          remove: edit.remove, foldThreadFlags: true)
        }
    }

    /// "Delete this message": to the Trash, this message only. The
    /// conversation stays where it is while another of its messages is
    /// outside the Trash (DEC-081); deleting its last message (with no
    /// live draft left) trashes the conversation, with that action's own
    /// undo.
    func trashMessage(_ message: Message) {
        runMessageAction(message) { state in
            switch MessageActionPlan.delete(state) {
            case .none:
                return nil
            case .conversation:
                self.trash(state.row)
                return nil
            case .message(let edit, let undo):
                let written = self.editMessageLabels([(row: state.row, ids: edit.ids)], add: edit.add,
                                                     remove: edit.remove, foldThreadFlags: true)
                self.offerUndo("Message moved to Trash") { [weak self] in
                    self?.runMessageAction(message) { state in
                        self?.editMessageLabels([(row: state.row, ids: undo.ids)], add: undo.add,
                                                remove: undo.remove, foldThreadFlags: true)
                    }
                }
                return written
            }
        }
    }

    /// "Mark unread from here": this message and the later ones `shown`
    /// (the open conversation, oldest first). The conversation stays open.
    func markUnreadFromHere(_ message: Message, shown: [Message]) {
        let ids = MessageActions.unreadFromHereIds(in: shown, from: message.id)
        guard !ids.isEmpty else { return }
        pinReadStateKeep([message.threadId])
        runMessageAction(message) { state in
            self.editMessageLabels([(row: state.row, ids: ids)], add: ["UNREAD"], remove: [],
                                   foldThreadFlags: true)
        }
    }

    /// "Report spam" / "Report not spam" from a message's menu: the
    /// conversation's own action (`markSpam`, `markNotSpam`), with its undo.
    /// Refused for a message in the Trash: the conversation's live messages
    /// are not on screen (DEC-081).
    func reportSpam(_ message: Message, spam: Bool) {
        runMessageAction(message) { state in
            guard MessageActionPlan.allowsConversationAction(state) else { return nil }
            if spam { self.markSpam(state.row) } else { self.markNotSpam(state.row) }
            return nil
        }
    }

    /// Runs `body` with the message's stored state (`MessageActionPlan.State`),
    /// one action at a time: each reads after the previous one's local
    /// write, so two quick clicks see each other.
    private func runMessageAction(_ message: Message,
                                  _ body: @escaping @MainActor (MessageActionPlan.State) -> Task<Void, Never>?) {
        guard !isShuttingDown else { return }
        let pool = db
        let previous = messageActionTail
        messageActionTail = Task { @MainActor [weak self] in
            _ = await previous?.value
            let loaded = try? await pool.read { db in
                try MessageActionPlan.State.load(db, message: message)
            }
            guard let self, !self.isShuttingDown, var state = loaded ?? nil else { return }
            // The list's copy can hold a thread edit not stored yet.
            if let listed = self.threads.first(where: {
                $0.id == state.row.id && !self.isPartlyTrashedRow($0)
            }) {
                state.row = listed
            }
            _ = await body(state)?.value
        }
    }

    // MARK: - Show original, Download message

    /// The message exactly as Gmail holds it (`format=raw`), in memory
    /// only. Not in the fictional inbox, which has no Gmail behind it.
    func originalMessage(_ message: Message) async throws -> Data {
        if demoMode {
            throw GmailError.http(0, "The original isn't available in the fictional inbox.")
        }
        return try await client(for: message.accountId).getRawMessage(id: message.gmailId)
    }

    /// "Download message": the original as an .eml file where the user
    /// chooses, through the system save panel. `original` when the caller
    /// already holds it ("Show original").
    func downloadMessage(_ message: Message, original: Data? = nil) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = MessageActions.downloadFilename(subject: message.subject)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            do {
                let data: Data
                if let original { data = original } else { data = try await originalMessage(message) }
                let values = try? destination.resourceValues(forKeys: [.isSymbolicLinkKey])
                if values?.isSymbolicLink == true {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try data.write(to: destination, options: .atomic)
                Self.markQuarantined(destination)
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                lastError = "Couldn't download the message: \(error.localizedDescription)"
            }
        }
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
