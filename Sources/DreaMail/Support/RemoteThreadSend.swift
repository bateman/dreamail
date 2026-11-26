import Foundation

/// The two Gmail calls a thread edit makes. `GmailClient` is the real one;
/// tests pass a stub to see exactly what reaches Gmail.
protocol GmailThreadEditing: Sendable {
    func modifyThread(id: String, add: [String], remove: [String]) async throws
    func trashThread(id: String) async throws
    /// `messages.batchModify` on exactly `ids`: labels only, never a delete.
    func modifyMessages(ids: [String], add: [String], remove: [String]) async throws
}

extension GmailClient: GmailThreadEditing {}

/// Sends one optimistic thread edit, and decides what a failure means.
/// `MailStore` owns the queue and the revert; the rules live here.
enum RemoteThreadSend {
    static func send(_ change: RemoteThreadChange, via client: any GmailThreadEditing,
                     gmailThreadId: String) async throws {
        switch change {
        case .modify(let add, let remove):
            try await client.modifyThread(id: gmailThreadId, add: add, remove: remove)
        case .trash:
            try await client.trashThread(id: gmailThreadId)
        case .modifyMessages(let ids, let add, let remove):
            guard !ids.isEmpty, !(add.isEmpty && remove.isEmpty) else { return }
            try await client.modifyMessages(ids: ids, add: add, remove: remove)
        case .sequence(let steps):
            for step in steps {
                try await send(step, via: client, gmailThreadId: gmailThreadId)
            }
        }
    }

    enum FailureDisposition: Equatable {
        /// No network: park the edit, mark the app offline.
        case queueOffline
        /// Quota or server error: park the edit for the replay before the
        /// next sync; Gmail is reachable.
        case queue
        /// Gmail refused the edit: show the error, re-derive the thread from
        /// its message rows (Gmail's last known state) and resync.
        case revert
    }

    static func disposition(for error: Error) -> FailureDisposition {
        if OfflinePolicy.shouldDefer(error) { return .queueOffline }
        if ThreadEditRetryPolicy.shouldRequeue(error) { return .queue }
        return .revert
    }

    /// The banner for an edit Gmail refused. Mute gets its own words: the
    /// `MUTED` label is not documented in the Gmail API, so a refusal of it
    /// is expected on some accounts and must not read like a sync fault.
    static func refusalMessage(for change: RemoteThreadChange, error: Error) -> String {
        if change.addLabels.contains(ConversationAction.mutedLabel) {
            return "Gmail did not accept muting this conversation, so it is back where it was. Mute it on gmail.com instead."
        }
        return error.localizedDescription
    }
}
