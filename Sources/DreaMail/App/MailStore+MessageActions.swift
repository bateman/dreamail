import Foundation
import AppKit
import GRDB

/// Actions on one message of an open conversation (`MessageActions`): the
/// star in its header and its "More" menu. Label edits go through the one
/// per-message path (`editMessageLabels`, `messages.batchModify`); nothing
/// here deletes a message permanently.
extension MailStore {
    /// Gmail's star on this message only (its STARRED label). The
    /// conversation shows as starred while any of its messages is.
    func toggleMessageStar(_ message: Message) {
        guard !MessageActions.isDraft(message) else { return }
        let starring = !MessageActions.isStarred(message)
        withMessageThread(message) { row, _ in
            self.editMessageLabels([(row: row, ids: [message.gmailId])],
                                   add: starring ? ["STARRED"] : [],
                                   remove: starring ? [] : ["STARRED"],
                                   foldThreadFlags: true)
        }
    }

    /// "Delete this message": to the Trash, this message only. The
    /// conversation stays where it is while another of its messages is
    /// outside the Trash (DEC-081); deleting the last one trashes the
    /// conversation, with that action's own undo.
    func trashMessage(_ message: Message) {
        guard !MessageActions.isDraft(message), !TrashedMessages.isTrashed(message) else { return }
        withMessageThread(message) { row, state in
            if state.liveIds == [message.gmailId] {
                self.trash(row)
                return
            }
            // Gmail drops INBOX from a trashed message; the undo puts it
            // back only where the message had it in a conversation in the
            // Inbox.
            let wasInInbox = row.inInbox && SyncEngine.labelIdsContain(message.labelIds, "INBOX")
            self.editMessageLabels([(row: row, ids: [message.gmailId])],
                                   add: ["TRASH"], remove: [], foldThreadFlags: true)
            self.offerUndo("Message moved to Trash") { [weak self] in
                self?.withMessageThread(message) { row, _ in
                    self?.editMessageLabels([(row: row, ids: [message.gmailId])],
                                            add: wasInInbox ? ["INBOX"] : [], remove: ["TRASH"],
                                            foldThreadFlags: true)
                }
            }
        }
    }

    /// "Mark unread from here": this message and the later ones `shown`
    /// (the open conversation, oldest first). The conversation stays open.
    func markUnreadFromHere(_ message: Message, shown: [Message]) {
        let ids = MessageActions.unreadFromHereIds(in: shown, from: message.id)
        guard !ids.isEmpty else { return }
        pinReadStateKeep([message.threadId])
        withMessageThread(message) { row, _ in
            self.editMessageLabels([(row: row, ids: ids)], add: ["UNREAD"], remove: [],
                                   foldThreadFlags: true)
        }
    }

    /// "Report spam" / "Report not spam" from a message's menu: the
    /// conversation's own action (`markSpam`, `markNotSpam`), with its undo.
    func reportSpam(_ message: Message, spam: Bool) {
        withMessageThread(message) { row, _ in
            if spam { self.markSpam(row) } else { self.markNotSpam(row) }
        }
    }

    /// The thread row (the list's copy when it has one: it can hold an
    /// edit not stored yet) and its messages in and out of the Trash.
    private func withMessageThread(_ message: Message,
                                   _ body: @escaping @MainActor (MailThread, ThreadUndo.TrashState) -> Void) {
        guard !isShuttingDown else { return }
        let threadId = message.threadId
        let pool = db
        Task { @MainActor [weak self] in
            let loaded = try? await pool.read { db -> (MailThread?, ThreadUndo.TrashState?) in
                (try MailThread.fetchOne(db, key: threadId),
                 try TrashedMessages.trashStates(db, threadIds: [threadId])[threadId])
            }
            guard let self, !self.isShuttingDown,
                  let stored = loaded?.0, let state = loaded?.1 else { return }
            let listed = self.threads.first { $0.id == threadId && !self.isPartlyTrashedRow($0) }
            body(listed ?? stored, state)
        }
    }

    // MARK: - Show original, Download message, Print

    /// The message exactly as Gmail holds it (`format=raw`), in memory
    /// only. Not in the fictional inbox, which has no Gmail behind it.
    func originalMessage(_ message: Message) async throws -> Data {
        if demoMode {
            throw GmailError.http(0, "The original isn't available in the fictional inbox.")
        }
        return try await client(for: message.accountId).getRawMessage(id: message.gmailId)
    }

    /// "Download message": the original as an .eml file where the user
    /// chooses, through the system save panel.
    func downloadMessage(_ message: Message) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = MessageActions.downloadFilename(subject: message.subject)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            do {
                let data = try await originalMessage(message)
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

    /// "Print": the headers and the body as text, through the system print
    /// panel. The HTML is not printed: laying it out would load its remote
    /// content.
    func printMessage(_ message: Message) {
        let pool = db
        let id = message.id
        Task { @MainActor in
            // The body as stored: a collapsed card may not hold it.
            let stored = (try? await pool.read { try Message.fetchOne($0, key: id) }) ?? nil
            let printed = stored ?? message
            guard let info = NSPrintInfo.shared.copy() as? NSPrintInfo else { return }
            info.horizontalPagination = .fit
            info.verticalPagination = .automatic
            info.isVerticallyCentered = false
            let width = info.paperSize.width - info.leftMargin - info.rightMargin
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
            view.isEditable = false
            view.isVerticallyResizable = true
            view.font = .systemFont(ofSize: 11)
            view.string = MessageActions.printableText(printed)
            view.sizeToFit()
            let operation = NSPrintOperation(view: view, printInfo: info)
            operation.jobTitle = printed.subject.isEmpty ? "(no subject)" : printed.subject
            _ = operation.run()
        }
    }
}
