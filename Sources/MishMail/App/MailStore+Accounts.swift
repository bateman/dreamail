import Foundation
import SwiftUI
import AppKit
import GRDB

extension MailStore {
    // MARK: - Account lifecycle

    func addAccount(reauthorizing hint: String? = nil) {
        // `make run` / UI tests are deliberately Keychain-free, ad-hoc fixture
        // processes backed by a known database key and isolated directory.
        // Never let real OAuth data cross that boundary; relaunching with
        // DEMO=0 requires stable signing before any real account connects.
        guard !AccountLifecycle.blocksDemoConnect(
            usesFixtureDatabaseKey: AppDatabase.usesFixtureDatabaseKey(
                environment: ProcessInfo.processInfo.environment)) else {
            lastError = AccountLifecycle.demoConnectBlockedMessage
            return
        }
        guard !isShuttingDown, !connectingAccount else { return }
        // Read-only cache (F-02): refuse before OAuth, or the refresh token
        // lands in the Keychain and the account insert then fails, leaving
        // an orphan token for an account the app never shows.
        guard cacheAcceptsWrites() else { return }
        accountSignInTask = Task {
            defer { accountSignInTask = nil }
            do {
                let (refresh, access) = try await OAuthService().signIn(loginHint: hint)
                var req = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
                req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
                struct UserInfo: Decodable { let email: String; let name: String? }
                let (data, _) = try await URLSession.shared.data(for: req)
                let info = try JSONDecoder().decode(UserInfo.self, from: data)

                try Task.checkCancellation()
                // A successful connection replaces the fictional mailbox.
                // Exit only after OAuth succeeds, so cancelling sign-in leaves
                // the user's demo session intact.
                guard !demoMode || exitDemoMode() else { return }

                try Keychain.set(refresh, forKey: "refreshToken.\(info.email)")
                // The shared client may hold an access token from the old
                // sign-in (other scopes, or a different grant).
                await GmailClient.shared(accountEmail: info.email).forgetAccessToken()
                try await db.write { db in
                    let existing = try Account.fetchOne(db, key: info.email)
                    let account = AccountLifecycle.accountAfterSignIn(
                        email: info.email, name: info.name, existing: existing)
                    if existing != nil {
                        try account.update(db)
                    } else {
                        try account.insert(db)
                    }
                }
                accountsNeedingReauth.remove(info.email)
                reloadAccounts()
                await refreshSendIdentities(accountId: info.email)
                // Own addresses are filtered at rank time. The new primary is
                // already in `ownEmailAddresses` before send-as returns, so
                // setSendIdentities sees no change and would not re-rank.
                rerankContacts()
                await sync(accountId: info.email)
            } catch {
                if !Task.isCancelled { lastError = error.localizedDescription }
            }
        }
    }

    func removeAccount(_ id: String) {
        if demoMode, id == DemoSeed.account {
            _ = exitDemoMode()
            return
        }
        // Read-only cache (F-02): refuse before anything changes, so the
        // removal cannot fail halfway on a cache that refuses every write.
        guard cacheAcceptsWrites() else { return }
        let pool = db
        // Stop the account's sync first: a pass still running would write
        // rows for an account that is being deleted. Drop the account from
        // `accounts` now so late sync errors, reauth requests and attachment
        // downloads for it are ignored (see `isKnownAccount`).
        let engine = engines[id]
        accounts.removeAll { $0.id == id }
        leaveScope(ofRemovedAccount: id)
        Task { @MainActor [weak self] in
            await engine?.cancelSync()
            // The database purge comes first because it is the step that can
            // fail. On failure nothing irreversible has happened yet: the
            // sign-in, notifications and attachment copies are still there,
            // the account comes back on reload, and the user is told. The
            // account row and its queued edits, offline drafts, scheduled
            // sends, triage rows, saved views and Ask Mish chats go in one
            // transaction.
            AccountLifecycle.markRemovalPending(id)
            do {
                try await pool.write { db in
                    try AccountLifecycle.purgeAccount(db, id: id)
                }
            } catch {
                AccountLifecycle.clearRemovalPending(id)
                guard let self, !self.isShuttingDown else { return }
                self.reloadAccounts()
                self.lastError = AccountLifecycle.removalFailedMessage
                return
            }
            await Self.removeOutsideDatabase(accountId: id)
            // After the Keychain delete: the next token request finds no
            // refresh token and fails, instead of reusing the cached one.
            await GmailClient.shared(accountEmail: id).forgetAccessToken()
            // Fold the purged pages out of the WAL and the freelist now
            // rather than at the next idle pass.
            _ = await Task.detached(priority: .utility) {
                AppDatabase.shared.checkpoint()
            }.value
            // Gmail API responses may sit in the shared HTTP cache on disk.
            // Nothing there needs to survive, so all of it goes.
            URLCache.shared.removeAllCachedResponses()
            guard let self, !self.isShuttingDown else { return }
            // Recent searches are not tagged by account; any of them may be
            // about this one's mail.
            self.clearRecentSearches()
            // A chat open in the panel may have been deleted with the account;
            // its transcript must not stay on screen or in memory.
            await self.askMishController?.discardConversationIfPurged(removedAccount: id)
            // The account's mail cascades away with it; any payload cached for
            // one of its conversations must not outlive the rows behind it.
            self.applyThreadContentChange(.everything)
            self.engines[id] = nil
            self.clients[id] = nil
            self.accountsNeedingReauth.remove(id)
            self.reloadAccounts()
            self.sendIdentities.removeAll { $0.accountId == id }
            self.reloadThreads()
            // The Scheduled and Outbox lists held rows for this account.
            self.reloadScheduledSends()
            self.reloadLocalDrafts()
            // Own-address set changed — drop the weight map and re-mine.
            self.rebuildContacts(forceFull: true)
            await self.reloadPendingThreadOpCount()
        }
    }

    /// Launch-time cleanup of what an interrupted or partly failed removal
    /// left behind (F-04): rows a late write (an open composer, an in-flight
    /// edit or triage result) stored after its account's purge, removals
    /// whose purge committed but whose sign-in, notifications or copies were
    /// not deleted yet, and attachment folders of accounts that are gone.
    ///
    /// Which accounts exist is read here, in the same transaction as the row
    /// purge, never taken from an in-memory list: a failed read sweeps
    /// nothing, rather than taking every account for removed.
    func sweepRemovedAccountResidueOnce() {
        guard !Self.residueSwept else { return }
        Self.residueSwept = true
        guard cacheAcceptsWrites(silent: true) else { return }
        let pool = db
        let pending = AccountLifecycle.pendingRemovals()
        Task { @MainActor in
            typealias Sweep = (live: [String], removals: (finish: [String], stale: [String]))
            guard let result = try? await pool.write({ db -> Sweep in
                try AccountLifecycle.purgeOrphanRows(db)
                return (live: try AccountLifecycle.liveAccountIds(db),
                        removals: try AccountLifecycle.removalsToFinish(db, pending: pending))
            }) else { return }
            for id in result.removals.stale { AccountLifecycle.clearRemovalPending(id) }
            for id in result.removals.finish { await Self.removeOutsideDatabase(accountId: id) }
            let live = result.live
            _ = await Task.detached(priority: .utility) {
                AttachmentCache.removeOrphans(liveAccounts: live)
            }.value
        }
    }

    private static var residueSwept = false

    /// Everything of a purged account outside the database (F-04): the
    /// sign-in, its preferences, notifications and attachment copies. Then
    /// the removal is no longer pending. A copy a failed delete leaves goes
    /// at the next launch (`sweepRemovedAccountResidueOnce`).
    private static func removeOutsideDatabase(accountId id: String) async {
        Keychain.delete("refreshToken.\(id)")
        AccountLifecycle.clearAccountDefaults(accountId: id)
        Notifier.removeNotifications(forAccount: id)
        _ = await Task.detached(priority: .utility) {
            AttachmentCache.removeAccount(id)
        }.value
        AccountLifecycle.clearRemovalPending(id)
    }

    /// Nothing may stay scoped to an account that no longer exists: the
    /// list would be empty, the switcher would still name the address, and
    /// the dock badge would count nothing.
    private func leaveScope(ofRemovedAccount id: String) {
        let viewAccount: String?
        switch selectedView {
        case .account(let account), .label(let account, _, _):
            viewAccount = account
        case .saved(let viewId, _):
            viewAccount = savedViews.first { $0.id == viewId }?.accountId
        default:
            viewAccount = nil
        }
        if AccountLifecycle.viewIsScopedToRemovedAccount(viewAccount: viewAccount, removed: id) {
            selectedView = .inbox
        }
        if AccountLifecycle.activeAccountAfterRemoval(active: activeAccountId, removed: id)
            != activeAccountId {
            setActiveAccount(nil)
        }
        let badgeRaw = Self.badgeScope.rawValue
        if AccountLifecycle.badgeScopeRawAfterRemoval(raw: badgeRaw, removed: id) != badgeRaw {
            // The reload at the end of `removeAccount` recounts the badge.
            Self.badgeScope = .all
        }
    }

    /// - Parameter interactive: The failure came from a sync the user asked
    ///   for. Background and follow-up failures raise the banner only the
    ///   first time (see `AccountLifecycle.presentsReauthBanner`).
    func requireReauthorization(for accountID: String, interactive: Bool = false) {
        // A sync that ends after its account was removed must not bring the
        // account back as a reauthorization request.
        guard isKnownAccount(accountID) else { return }
        let newlyFlagged = accountsNeedingReauth.insert(accountID).inserted
        guard AccountLifecycle.presentsReauthBanner(
            newlyFlagged: newlyFlagged, interactive: interactive) else { return }
        presentedError = ErrorRecovery.reauthorizationRequired(for: accountID)
    }

    /// Record a sync failure banner and remember which account set it so a
    /// later success for that account can clear it without wiping send errors.
    func setSyncFailureError(_ message: String, accountId: String) {
        guard isKnownAccount(accountId) else { return }
        presentedError = ErrorRecovery.retry(message, accountID: accountId)
    }

    /// True while `accountId` is still in `accounts`. Late results for a
    /// removed account are ignored.
    func isKnownAccount(_ accountId: String) -> Bool {
        accounts.contains { $0.id == accountId }
    }

    func clearSyncFailureErrorIfNeeded(for accountId: String) {
        guard presentedError?.accountID == accountId else { return }
        lastError = nil
    }
}
