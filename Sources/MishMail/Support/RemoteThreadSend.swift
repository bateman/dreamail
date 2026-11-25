import Foundation

/// The two Gmail calls a thread edit makes. `GmailClient` is the real one;
/// tests pass a stub to see exactly what reaches Gmail.
protocol GmailThreadEditing: Sendable {
    func modifyThread(id: String, add: [String], remove: [String]) async throws
    func trashThread(id: String) async throws
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
}
