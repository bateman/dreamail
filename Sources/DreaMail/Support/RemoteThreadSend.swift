import Foundation

/// The two Gmail calls a thread edit makes. `GmailClient` is the real one;
/// tests pass a stub to see exactly what reaches Gmail.
protocol GmailThreadEditing: Sendable {
    func modifyThread(id: String, add: [String], remove: [String]) async throws
    func trashThread(id: String) async throws
    /// `messages.batchModify` on exactly `ids`: labels only, never a delete.
    func modifyMessages(ids: [String], add: [String], remove: [String]) async throws
    /// `messages/{id}/modify` on one message; Gmail answers 404 for an id
    /// it no longer has.
    func modifyMessage(id: String, add: [String], remove: [String]) async throws
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
            do {
                try await client.modifyMessages(ids: ids, add: add, remove: remove)
            } catch let error where isRejectedId(error) {
                // One id Gmail no longer has can fail the whole batch: the
                // others still need the change. One by one, skipping the
                // ones that are gone (404). Any other refusal (a 400 for a
                // label deleted elsewhere, say) does not stop the others;
                // the last one reaches the caller, also for a batch of one.
                var refusal: Error?
                for id in ids {
                    do {
                        try await client.modifyMessage(id: id, add: add, remove: remove)
                    } catch let error where isNotFound(error) {
                        continue
                    } catch {
                        refusal = error
                    }
                }
                if let refusal { throw refusal }
            }
        case .sequence(let steps):
            for step in steps {
                try await send(step, via: client, gmailThreadId: gmailThreadId)
            }
        }
    }

    /// A batch Gmail refused for its ids (400 or 404), not for the account.
    static func isRejectedId(_ error: Error) -> Bool {
        guard case GmailError.http(let code, _) = error else { return false }
        return code == 400 || code == 404
    }

    static func isNotFound(_ error: Error) -> Bool {
        guard case GmailError.http(404, _) = error else { return false }
        return true
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
