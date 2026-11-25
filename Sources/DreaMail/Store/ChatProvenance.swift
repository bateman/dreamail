import Foundation
import GRDB

/// Which accounts' mail an Ask AI conversation drew on (F-04), so that
/// removing an account deletes every chat that may quote its mail and leaves
/// the others alone.
///
/// A conversation draws on an account when one of that account's threads is
/// injected as context, or when the model runs any tool: tools reach every
/// connected account (unified search, `list_accounts`, …), so a tool turn
/// records all of them. Provenance is recorded before the mail is used or in
/// the same transaction as the rows that quote it, never after.
///
/// Conversations from before v48 recorded nothing (`tracksAccounts` false).
/// There is no telling which accounts they drew on, so every account removal
/// deletes them.
///
/// Pure database policy: it works whether or not the AI features are built in.
enum ChatProvenance {
    /// What the conversation's next write must add to its provenance. Kept
    /// until a write succeeds, so a failed write (a busy database) cannot
    /// let later rows that quote the mail go out without it.
    struct Pending: Equatable {
        private(set) var accounts: Set<String> = []
        /// A tool ran or is about to run: every connected account counts.
        private(set) var needsAllAccounts = false

        /// A thread of `accountId` reached the model: injected as context,
        /// or named in the system prompt as the open thread.
        mutating func noteThread(accountId: String) {
            if !accountId.isEmpty { accounts.insert(accountId) }
        }

        mutating func noteTools() { needsAllAccounts = true }

        /// `written` reached the database; anything noted since stays.
        mutating func committed(_ written: Pending) {
            accounts.subtract(written.accounts)
            if written.needsAllAccounts { needsAllAccounts = false }
        }
    }

    /// Records `pending`; see the other overload.
    @discardableResult
    static func record(_ db: Database, conversationId: String, pending: Pending) throws -> Bool {
        try record(db, conversationId: conversationId, accounts: pending.accounts,
                   includingAllAccounts: pending.needsAllAccounts)
    }

    /// Adds `accounts` (and, with `includingAllAccounts`, every account in
    /// the cache) to the conversation's provenance.
    ///
    /// Returns false when nothing may be written to the conversation any
    /// more: it was deleted (by an account removal, or by the user), or one
    /// of `accounts` is no longer connected. In the last case the
    /// conversation is deleted here: it holds, or is about to hold, mail of
    /// an account that was removed while the turn ran.
    @discardableResult
    static func record(_ db: Database, conversationId: String, accounts: Set<String>,
                       includingAllAccounts: Bool = false) throws -> Bool {
        guard try ChatConversationRow.exists(db, key: conversationId) else { return false }
        for account in accounts {
            if try !Account.exists(db, key: account) {
                _ = try ChatConversationRow.deleteOne(db, key: conversationId)
                return false
            }
        }
        var all = accounts
        if includingAllAccounts {
            all.formUnion(try String.fetchAll(db, sql: "SELECT id FROM account"))
        }
        for account in all {
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO chatConversationAccount (conversationId, accountId)
                    VALUES (?, ?)
                    """,
                arguments: [conversationId, account])
        }
        return true
    }

    /// Accounts recorded for a conversation, sorted.
    static func accounts(_ db: Database, conversationId: String) throws -> [String] {
        try String.fetchAll(
            db,
            sql: """
                SELECT accountId FROM chatConversationAccount
                WHERE conversationId = ? ORDER BY accountId
                """,
            arguments: [conversationId])
    }

    /// Deletes the conversations that drew on `accountId`, and every
    /// conversation without provenance. Messages and provenance rows
    /// cascade. Call in the account-removal transaction.
    static func purgeConversations(_ db: Database, drawingOn accountId: String) throws {
        try db.execute(
            sql: """
                DELETE FROM chatConversation
                WHERE tracksAccounts = 0
                   OR id IN (SELECT conversationId FROM chatConversationAccount
                             WHERE accountId = ?)
                """,
            arguments: [accountId])
    }
}
