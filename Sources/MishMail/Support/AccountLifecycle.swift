import Foundation
import GRDB

/// Account connect / disconnect / reauth policy, kept off `MailStore` so the
/// hostless suite can cover the decisions without AppKit.
enum AccountLifecycle {
    static let demoConnectBlockedMessage =
        "The developer demo cannot connect real accounts. Quit it, configure free Personal Team signing, then run make run DEMO=0."

    /// True when `error` means the account's saved sign-in was rejected by
    /// Google and only reauthorizing (not a retry) can fix it.
    static func isReauthRequired(_ error: Error) -> Bool {
        switch error {
        case OAuthError.invalidGrant: return true
        case GmailError.noRefreshToken: return true
        default: return false
        }
    }

    /// Accounts a sync pass should attempt. A background pass skips accounts
    /// already known to need reauthorization: only the user can fix those,
    /// and each attempt is a request to Google's token endpoint with a dead
    /// token. A user-initiated pass tries all of them. The flag is cleared by
    /// a successful sign-in or sync, after which polling resumes.
    static func accountsToSync(
        all: [String], needingReauth: Set<String>, interactive: Bool
    ) -> [String] {
        interactive ? all : all.filter { !needingReauth.contains($0) }
    }

    /// Whether a reauthorization failure should raise the banner. Repeat
    /// failures for an account that is already flagged stay quiet, so a
    /// dismissed banner does not return and does not replace an unrelated
    /// one — unless the user asked for the sync that failed.
    static func presentsReauthBanner(newlyFlagged: Bool, interactive: Bool) -> Bool {
        newlyFlagged || interactive
    }

    /// Demo / UI-test processes are Keychain-free. Never let real OAuth data
    /// cross that boundary.
    static func blocksDemoConnect(usesFixtureDatabaseKey: Bool) -> Bool {
        usesFixtureDatabaseKey
    }

    /// Reauthorizing an existing account must only replace its refresh token.
    /// Preserve the history cursor and last-sync timestamp so a bundle-id
    /// migration (or a revoked token) does not trigger a full mailbox
    /// backfill and burn through Gmail's per-user quota.
    static func accountAfterSignIn(
        email: String, name: String?, existing: Account?
    ) -> Account {
        if var existing {
            if existing.displayName == existing.id,
               let name, !name.isEmpty {
                existing.displayName = name
            }
            if existing.senderName.isEmpty {
                existing.senderName = name ?? ""
            }
            return existing
        }
        return Account(
            id: email,
            displayName: name ?? email,
            historyId: nil,
            lastSyncAt: nil,
            senderName: name ?? ""
        )
    }

    // MARK: - Removal

    /// Deletes the account row and every local row that belongs to it. Call
    /// inside one write transaction so a failure leaves the account whole.
    ///
    /// Mail (threads, messages, bodies, attachments, labels, summaries,
    /// reminders, the search index) cascades from the account row. The
    /// offline queues, scheduled sends and triage results carry no foreign
    /// key and would otherwise outlive it: a due scheduled send would still
    /// try to go out, and a queued edit for a missing account would sit in
    /// the replay queue forever.
    ///
    /// Removal deletes everything that belongs to the account (F-04), with
    /// no "keep" option:
    /// - saved views scoped to it (their filters can name its senders);
    /// - its entry in a snippet's account scope, and the snippet itself when
    ///   that account was its only scope (emptying the scope would make it
    ///   available on every account instead);
    /// - Ask Mish conversations that drew on its mail, and every
    ///   conversation from before provenance was recorded (`ChatProvenance`).
    static func purgeAccount(_ db: Database, id: String) throws {
        for table in ["pendingThreadOp", "localDraft", "scheduledSend", "savedView"] {
            try db.execute(sql: "DELETE FROM \(table) WHERE accountId = ?",
                           arguments: [id])
        }
        // Thread ids are "<account>:<gmailThreadId>". Not LIKE: `_` and `%`
        // are legal in an address and would match another account's rows.
        let prefix = "\(id):"
        try db.execute(
            sql: "DELETE FROM threadAI WHERE substr(threadId, 1, length(?)) = ?",
            arguments: [prefix, prefix])
        try removeFromSnippetScopes(db, id: id)
        try ChatProvenance.purgeConversations(db, drawingOn: id)
        // Also cascades with the account row; deleted by name so the purge
        // does not depend on the foreign key alone.
        try db.execute(sql: "DELETE FROM accountPhoto WHERE accountId = ?", arguments: [id])
        // Cached inline images: same (they cascade with the account, its
        // messages and attachment rows).
        try InlineImageCache.forget(db, account: id)
        // Cached remote images: same (they cascade with the account and its
        // messages).
        try RemoteImageCache.forget(db, account: id)
        // Answers sent to calendar invites: same.
        try CalendarRSVPStore.forget(db, account: id)
        // Calendar grant, chosen calendars, invitation events: same.
        try CalendarStore.forget(db, accountId: id)
        // The account's mail cascades with the account row.
        let messages = try Int.fetchOne(
            db, sql: "SELECT count(*) FROM message WHERE accountId = ?", arguments: [id]) ?? 0
        try SearchIndexDeletes.deleting(db, messages: messages) {
            try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [id])
        }
        // The cascade queued every message of the account, with its address;
        // the removal deletes its copies and notifications wholesale.
        try DeletedMessageResidue.forget(db, account: id)
    }

    struct AccountRemovedError: LocalizedError {
        var errorDescription: String? { "This account was removed from MishMail." }
    }

    /// Call first in a write that stores mail for `accountId` in a table
    /// without a foreign key (offline drafts, scheduled sends). A composer
    /// still open when its account is removed would otherwise write its text
    /// back after the purge. An empty id is not checked.
    static func requireLiveAccount(_ db: Database, id: String) throws {
        guard !id.isEmpty else { return }
        guard try Account.exists(db, key: id) else { throw AccountRemovedError() }
    }

    // MARK: Interrupted removals

    static let pendingRemovalsKey = "accountRemovalsPending"

    /// Recorded before the purge and cleared once everything outside the
    /// database is gone too. A quit or crash in between (after the purge,
    /// before the Keychain delete) leaves the id here, and the next launch
    /// finishes the job (`removalsToFinish`).
    static func markRemovalPending(_ id: String, defaults: UserDefaults = .standard) {
        var ids = pendingRemovals(defaults: defaults)
        guard !ids.contains(id) else { return }
        ids.append(id)
        defaults.set(ids, forKey: pendingRemovalsKey)
    }

    static func clearRemovalPending(_ id: String, defaults: UserDefaults = .standard) {
        let ids = pendingRemovals(defaults: defaults).filter { $0 != id }
        if ids.isEmpty {
            defaults.removeObject(forKey: pendingRemovalsKey)
        } else {
            defaults.set(ids, forKey: pendingRemovalsKey)
        }
    }

    static func pendingRemovals(defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: pendingRemovalsKey) ?? []
    }

    /// Marked removals whose account row is gone: the purge committed, the
    /// rest may not have run. A marked account whose row still exists was
    /// never purged (killed before the transaction committed); it keeps its
    /// sign-in and only the mark is dropped (`stale`). Read from the account
    /// table, in the caller's transaction.
    static func removalsToFinish(_ db: Database, pending: [String]) throws
        -> (finish: [String], stale: [String]) {
        var finish: [String] = []
        var stale: [String] = []
        for id in pending {
            if try Account.exists(db, key: id) { stale.append(id) } else { finish.append(id) }
        }
        return (finish, stale)
    }

    static func liveAccountIds(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT id FROM account")
    }

    /// What the remove-account confirmation says is deleted. Ask Mish chats
    /// are named only in a build with the AI features: without them there is
    /// no chat to speak of (older chats are still purged, see `purgeAccount`).
    static func removalConfirmationMessage(aiFeaturesEnabled: Bool) -> String {
        let chats = aiFeaturesEnabled
            ? ", and Ask Mish chats that may contain this account's mail"
            : ""
        return "This removes cached mail, opened attachments and the saved sign-in from this Mac. "
            + "Also deleted: unsent scheduled mail, offline drafts and edits not yet synced for this account, "
            + "its saved views, snippets available only to it, its sync and filter settings"
            + (aiFeaturesEnabled ? ", its notifications" : " and its notifications")
            + chats
            + ". Gmail mail on the server is not deleted."
    }

    static let removalFailedMessage =
        "The account couldn't be removed. Nothing was deleted; try again."

    /// Rows of the tables without a foreign key whose account no longer
    /// exists: a write that landed after its account's purge (an open
    /// composer's autosave, an in-flight edit or triage result), or a purge
    /// that never ran. Called at launch. An empty account id is left alone:
    /// it is not an account that was removed.
    static func purgeOrphanRows(_ db: Database) throws {
        for table in ["pendingThreadOp", "localDraft", "scheduledSend", "savedView", "deletedMessage"] {
            try db.execute(sql: """
                DELETE FROM \(table)
                WHERE accountId IS NOT NULL AND accountId != ''
                  AND accountId NOT IN (SELECT id FROM account)
                """)
        }
        try db.execute(sql: "DELETE FROM threadAI WHERE threadId NOT IN (SELECT id FROM thread)")
        try InlineImageCache.purgeOrphans(db)
        try RemoteImageCache.purgeOrphans(db)
        try CalendarRSVPStore.purgeOrphans(db)
        try db.execute(sql: """
            DELETE FROM chatConversation
            WHERE id IN (SELECT conversationId FROM chatConversationAccount
                         WHERE accountId NOT IN (SELECT id FROM account))
            """)
    }

    /// Same case-insensitive match as `Snippet.isAvailable(for:)`.
    private static func removeFromSnippetScopes(_ db: Database, id: String) throws {
        let scoped = try Snippet.filter(Column("accountIdsJSON") != nil).fetchAll(db)
        for var snippet in scoped {
            let before = snippet.accountIds
            let after = before.filter { $0.caseInsensitiveCompare(id) != .orderedSame }
            guard after.count != before.count else { continue }
            if after.isEmpty {
                _ = try snippet.delete(db)
            } else {
                snippet.accountIds = after
                try snippet.update(db)
            }
        }
    }

    /// UserDefaults keys that belong to an account: the one-time backfill
    /// flags (key strings match `SyncEngine.performSyncNow`), the backfill
    /// cursor, its Keep-mail-from window, the category filter of each of its
    /// labels, and the RSVPs sent from it.
    static func accountDefaultsKeys(accountId: String,
                                    in defaults: UserDefaults = .standard) -> [String] {
        var keys = ["backfill.window.\(accountId)",
                    "backfill.starred.\(accountId)",
                    SyncEngine.attachmentRepairDefaultsKey(accountId: accountId),
                    WindowBackfill.listedKey(accountId: accountId),
                    "syncWindowDays.\(accountId)"]
        // `categoryFilter.label.<account>.<labelId>` (`MailboxView.prefsKey`).
        // Gmail label ids have no dot, so a remainder with one belongs to a
        // longer address that starts with this one.
        let labelPrefix = "categoryFilter.label.\(accountId)."
        // The account is percent-encoded down to letters and digits there,
        // so the trailing dot ends it.
        let rsvpPrefix = CalendarInvite.rsvpDefaultsKey(accountId: accountId, uid: "")
        for key in defaults.dictionaryRepresentation().keys {
            if key.hasPrefix(labelPrefix),
               !key.dropFirst(labelPrefix.count).contains(".") {
                keys.append(key)
            } else if key.hasPrefix(rsvpPrefix) {
                keys.append(key)
            }
        }
        return keys
    }

    /// A removed account's cache is gone, and so is everything remembered
    /// about it. Left in place, adding the account again would skip the
    /// starred-mail backfill.
    static func clearAccountDefaults(accountId: String,
                                     defaults: UserDefaults = .standard) {
        for key in accountDefaultsKeys(accountId: accountId, in: defaults) {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Scope after removal
    //
    // Primitive types on purpose: `MailboxView` and `BadgeScope` live in the
    // app target, outside the hostless suite.

    /// The single-account filter after `removed` is gone: back to the unified
    /// view when it pointed at that account, unchanged otherwise.
    static func activeAccountAfterRemoval(active: String?, removed: String) -> String? {
        active == removed ? nil : active
    }

    /// True when the selected view shows only `removed`'s mail (its inbox,
    /// one of its labels, or a saved view scoped to it) and would be an
    /// empty list from now on. `viewAccount` is nil for a unified view.
    static func viewIsScopedToRemovedAccount(viewAccount: String?, removed: String) -> Bool {
        viewAccount == removed
    }

    /// The dock-badge scope preference ("all", "focused", "account:<email>")
    /// after `removed` is gone. A scope of the removed account would count
    /// nothing, so it falls back to "all".
    static func badgeScopeRawAfterRemoval(raw: String?, removed: String) -> String? {
        raw == "account:\(removed)" ? "all" : raw
    }
}
