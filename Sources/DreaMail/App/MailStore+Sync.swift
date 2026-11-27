import Foundation
import SwiftUI
import AppKit
import GRDB

extension MailStore {
    // MARK: - Sync

    /// Async so the catch-up read is awaited rather than left running in an
    /// untracked task. Termination cancels and awaits every *tracked*
    /// background task before closing SQLCipher; a stray read outliving that
    /// is the exact race `DatabaseLifecycle` exists to prevent.
    func startPolling() async {
        // Demo mode has no real account and no token; polling would only spin
        // up failed syncs and error banners over the screenshot fixtures.
        if demoMode { return }
        guard !isShuttingDown else { return }
        // Read-only cache (F-02): the poll, the reconnect edge and the due
        // sweeps (reminders, snoozes, scheduled sends) all write, and a sweep
        // whose clearing write is refused re-fires every tick — one overdue
        // reminder would notify once a minute. One gate for all of them.
        guard storageState.allowsWrites else { return }
        // Catch snoozes that came due while the app was closed.
        await fireDueSnoozes()
        guard !isShuttingDown else { return }
        observeActivityForPolling()
        observeConnectivity()
        armSyncTimer()
    }

    /// Reachability edges. Losing the path flips the sync control to
    /// "Offline" before the first request times out; regaining it replays
    /// the offline queues now instead of at the next poll. Neither edge is
    /// trusted on its own — a captive portal reports a satisfied path — so
    /// `isOffline` is only cleared by a request that actually succeeds.
    private func observeConnectivity() {
        guard connectivity == nil else { return }
        let monitor = ConnectivityMonitor()
        monitor.onChange = { [weak self] reachable in
            guard let self, !self.isShuttingDown else { return }
            if !reachable {
                self.isOffline = true
                return
            }
            guard self.syncTickTask == nil else { return }
            self.syncTickTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.syncTickTask = nil }
                guard !self.isShuttingDown else { return }
                await self.syncAll(interactive: false)
            }
        }
        monitor.start()
        connectivity = monitor
    }

    private var currentPollInterval: TimeInterval {
        PollCadence.interval(
            appActive: NSApp?.isActive ?? true,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
    private func armSyncTimer() {
        guard !isShuttingDown else { return }
        let interval = currentPollInterval
        syncTimer?.invalidate()
        syncTimerInterval = interval
        syncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isShuttingDown else { return }
                // Two independent one-at-a-time guards: a long syncAll must
                // not skip due sweeps, and a slow sweep must not stack
                // concurrent fireDue* against itself. Do not clobber a
                // running task (would leave its pool work untracked for
                // termination).
                if self.syncTickTask == nil {
                    self.syncTickTask = Task { @MainActor [weak self] in
                        guard let self else { return }
                        defer { self.syncTickTask = nil }
                        guard !self.isShuttingDown else { return }
                        await self.syncAll(interactive: false)
                    }
                }
                // Due sweeps are independent of syncAll and do not wait for
                // it — reminders, snoozes, and the scheduled-send backstop
                // must still fire on schedule during a long backfill.
                if self.dueSweepTask == nil {
                    self.dueSweepTask = Task { @MainActor [weak self] in
                        guard let self else { return }
                        defer { self.dueSweepTask = nil }
                        guard !self.isShuttingDown else { return }
                        await self.fireDueReminders()
                        await self.fireDueSnoozes()
                        // Backstop for the one-shot timer (sleep/wake can eat it).
                        await self.fireDueScheduledSends()
                    }
                }
            }
        }
        // Let the kernel coalesce the poll wake with other timers; see
        // `TimerTolerance`.
        syncTimer?.tolerance = TimerTolerance.forInterval(
            interval, cap: TimerTolerance.pollCap)
    }

    /// Re-arm only when the cadence actually changed. Focus flaps between two
    /// windows of the same app do not change `NSApp.isActive`, but Low Power
    /// Mode and app switches do.
    private func rearmSyncTimerIfCadenceChanged() {
        guard syncTimer != nil, !isShuttingDown else { return }
        guard currentPollInterval != syncTimerInterval else { return }
        armSyncTimer()
    }

    private func observeActivityForPolling() {
        guard activityObservers.isEmpty else { return }
        let center = NotificationCenter.default
        // Coming to the front: catch up now rather than making the user look
        // at a list that can be a whole interval stale, then speed back up.
        activityObservers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isShuttingDown else { return }
                self.rearmSyncTimerIfCadenceChanged()
                // Repaint the Dock badge in case a paint was lost, and pick
                // up notification settings changed meanwhile.
                self.repaintDockBadge()
                self.refreshDockBadgeSystemStatus()
                // Only if the mailbox is actually stale. Without this floor,
                // alt-tabbing back and forth would fire a full multi-account
                // sync per switch — more requests against Gmail's quota than
                // the poll it is supposed to be relieving.
                if let last = self.lastSyncAttemptedAt,
                   Date().timeIntervalSince(last) < PollCadence.active {
                    return
                }
                await self.syncAll(interactive: false)
            }
        })
        for name in [NSApplication.didResignActiveNotification,
                     Notification.Name.NSProcessInfoPowerStateDidChange] {
            activityObservers.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.rearmSyncTimerIfCadenceChanged() }
            })
        }
    }

    func stopObservingActivityForPolling() {
        for observer in activityObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        activityObservers.removeAll()
    }

    /// Sync every account with true parallelism at the SyncEngine layer
    /// (each engine is an independent actor). MainActor work — reload,
    /// blocklist, contacts — runs once at the end.
    ///
    /// - Parameter interactive: User-initiated sync (toolbar, menu, banner).
    ///   Background timer / activation catch-up pass `false` so brief offline
    ///   blips do not leave a sticky error banner.
    func syncAll(interactive: Bool = true) async {
        guard !demoMode else {
            showNotice("Demo inbox is offline")
            return
        }
        guard !isShuttingDown else { return }
        // Read-only cache (F-02): every fetched row would be refused, and
        // the offline queues could not record what they sent. Reached from
        // the toolbar and menu as well as the (already gated) poll.
        guard cacheAcceptsWrites(silent: !interactive) else { return }
        // Covers every exit below, including the no-accounts and early-out
        // paths — all of them count as "we just looked".
        defer { lastSyncAttemptedAt = Date() }
        let ids = accounts.map(\.id)
        guard !ids.isEmpty else {
            await applyBlocklist()
            await notifyNewMail()
            rebuildContacts()
            await autoClassifyNewMail()
            return
        }
        for id in ids where engines[id] == nil {
            engines[id] = SyncEngine(accountId: id)
        }
        // Offline work first, so the history read below sees it applied
        // rather than reverting it, and queued mail leaves before new mail
        // is fetched. Each stops at the first connectivity failure.
        await flushPendingThreadOps()
        await flushLocalDrafts()
        await fireDueScheduledSends()
        // A background pass leaves out accounts that need reauthorization;
        // signing in again clears the flag and they rejoin the next poll.
        let syncIds = AccountLifecycle.accountsToSync(
            all: ids, needingReauth: accountsNeedingReauth, interactive: interactive)
        // Capture engine refs before leaving MainActor for the task group.
        let pairs: [(String, SyncEngine)] = syncIds.compactMap { id in
            engines[id].map { (id, $0) }
        }
        guard !pairs.isEmpty else {
            await reloadAccountsOffMain()
            await AppDatabase.shared.checkpointIfNeededOffMain()
            return
        }
        let message = syncIds.count == 1
            ? "Syncing \(syncIds[0])…" : "Syncing \(syncIds.count) accounts…"
        let progress = makeSyncStatusSink(message)
        let batches = makeSyncBatchSink()
        quietBacklogOfFirstSyncs(syncIds)

        // Whether any account actually rewrote thread rows this pass.
        // `deriveThreads` is the single choke point for message-row writes and
        // records every key it derives, so `.none` from every engine means the
        // thread table is byte-identical to before the sync — and the whole
        // reload tail below would be recomputing the same answers.
        var anyThreadsChanged = false

        await withTaskGroup(of: (String, Error?, ThreadContentChange).self) { group in
            for (id, engine) in pairs {
                group.addTask {
                    do {
                        let change = try await engine.syncNow(
                            progress: { progress.submit($0) },
                            batch: { batches.submit($0) })
                        return (id, nil, change)
                    } catch {
                        // Drain rather than fabricate .none: incrementalSync
                        // may have already rewritten thread rows (deriveThreads
                        // runs before partialFetch is thrown). Skipping the
                        // drain would leave anyThreadsChanged false and the
                        // post-sync reload early-out would hide partial work
                        // until a later clean pass. Matches sync(accountId:).
                        return (id, error, await engine.drainContentChange())
                    }
                }
            }
            for await (id, error, change) in group {
                applyThreadContentChange(change)
                if change != .none { anyThreadsChanged = true }
                // Removed while this pass ran: its outcome is moot.
                guard isKnownAccount(id) else { continue }
                noteSyncOutcome(account: id, error: error)
                if let error {
                    if AccountLifecycle.isReauthRequired(error) {
                        requireReauthorization(for: id, interactive: interactive)
                    } else if case GmailError.partialFetch = error {
                        // Soft: historyId not advanced; next sync retries.
                        // Still run post-sync so successful upserts appear.
                        accountsNeedingReauth.remove(id)
                        await backfillSenderNameIfNeeded(accountId: id)
                        refreshAccountPhotoIfDue(accountId: id)
                        await refreshSendIdentitiesIfStale(accountId: id)
                    } else if !OfflinePolicy.surfacesSyncFailure(error) {
                        // No network. The sync control reads "Offline";
                        // a user-initiated sync gets a passing notice, the
                        // background tick stays silent. Either way no
                        // sticky banner: the next poll retries on its own.
                        isOffline = true
                        if interactive { showNotice(OfflinePolicy.offlineSyncNotice) }
                    } else {
                        DiagnosticLog.syncFailure(account: id, error: error)
                        setSyncFailureError(
                            "\(id): \(error.localizedDescription)",
                            accountId: id)
                    }
                } else {
                    isOffline = false
                    accountsNeedingReauth.remove(id)
                    clearSyncFailureErrorIfNeeded(for: id)
                    await backfillSenderNameIfNeeded(accountId: id)
                    refreshAccountPhotoIfDue(accountId: id)
                    await refreshSendIdentitiesIfStale(accountId: id)
                }
            }
        }
        batches.close()
        endSyncStatus(progress)
        // Always: `syncLabels` can rename/add a Gmail label without touching a
        // single thread row, and the sidebar renders from this.
        await reloadAccountsOffMain()
        // The steady state for an idle mailbox is "history returned nothing".
        // Re-running the list query, the blocklist scan, the unread diff and
        // the classifier every 60 seconds to reach the same answer was pure
        // main-actor tax.
        guard anyThreadsChanged else {
            await AppDatabase.shared.checkpointIfNeededOffMain()
            return
        }
        reloadThreads()  // once for all accounts, not once per account
        await applyBlocklist()
        await notifyNewMail()
        await settleNewMailBacklog(syncIds, alreadyNotified: true)
        rebuildContacts()
        await autoClassifyNewMail()
        await AppDatabase.shared.checkpointIfNeededOffMain()
    }

    func sync(accountId: String) async {
        guard !demoMode else {
            return
        }
        // A follow-up sync (after a send or failed edit) must not restart a
        // pass for an account that is being removed.
        guard !isShuttingDown, isKnownAccount(accountId) else { return }
        guard cacheAcceptsWrites(silent: true) else { return }
        let engine = engines[accountId] ?? SyncEngine(accountId: accountId)
        engines[accountId] = engine

        // Throttled like syncAll's; both exits close it before writing the
        // final "" so a queued progress hop can't land on top of it.
        let progress = makeSyncStatusSink("Syncing \(accountId)…")
        let batches = makeSyncBatchSink()
        quietBacklogOfFirstSyncs([accountId])
        do {
            let change = try await engine.syncNow(
                progress: { progress.submit($0) },
                batch: { batches.submit($0) })
            batches.close()
            endSyncStatus(progress)
            applyThreadContentChange(change)
            isOffline = false
            accountsNeedingReauth.remove(accountId)
            noteSyncOutcome(account: accountId, error: nil)
            clearSyncFailureErrorIfNeeded(for: accountId)
            await backfillSenderNameIfNeeded(accountId: accountId)
            refreshAccountPhotoIfDue(accountId: accountId)
            await refreshSendIdentitiesIfStale(accountId: accountId)
            reloadAccounts()
            reloadThreads()
            await settleNewMailBacklog([accountId], alreadyNotified: false)
        } catch {
            batches.close()
            endSyncStatus(progress)
            // Removed while this pass ran: ignore its failure (the refresh
            // token is gone and the pass was cancelled on purpose).
            guard isKnownAccount(accountId) else { return }
            noteSyncOutcome(account: accountId, error: error)
            if case GmailError.partialFetch = error {} else {
                // The pages stored before the failure, including those the
                // closed batch sink had not shown yet.
                let stored = await engine.drainContentChange()
                if stored != .none {
                    applyThreadContentChange(stored)
                    reloadThreads()
                }
            }
            if AccountLifecycle.isReauthRequired(error) {
                requireReauthorization(for: accountId)
            } else if case GmailError.partialFetch = error {
                // Soft: apply what we got; historyId stays put for retry. The
                // throw skipped syncNow's own drain, so collect the rows that
                // did land rather than leaving them for the next pass.
                applyThreadContentChange(await engine.drainContentChange())
                accountsNeedingReauth.remove(accountId)
                await backfillSenderNameIfNeeded(accountId: accountId)
                refreshAccountPhotoIfDue(accountId: accountId)
                await refreshSendIdentitiesIfStale(accountId: accountId)
                reloadAccounts()
                reloadThreads()
            } else if !OfflinePolicy.surfacesSyncFailure(error) {
                // Follow-up syncs (after a save, a failed edit) run without
                // the user asking; offline they must not stack banners.
                isOffline = true
            } else {
                DiagnosticLog.syncFailure(account: accountId, error: error)
                setSyncFailureError(
                    "\(accountId): \(error.localizedDescription)",
                    accountId: accountId)
            }
        }
    }

    /// Accounts added before senderName existed get it from the profile.
    private func backfillSenderNameIfNeeded(accountId: String) async {
        // Gate on the published row (senderName is stable there), but never
        // write that value back: published accounts carry lastSyncAt = nil,
        // and a whole-row update would clobber the real timestamp in the DB.
        // Re-fetch inside the write, same as renameAccount / setSenderName.
        guard let published = accounts.first(where: { $0.id == accountId }),
              published.senderName.isEmpty,
              let name = try? await client(for: accountId).userName(),
              !name.isEmpty else { return }
        try? await db.write { db in
            if var account = try Account.fetchOne(db, key: accountId) {
                account.senderName = name
                try account.update(db)
            }
        }
    }

    /// RFC 2822 From value for a mailbox primary (legacy call sites / new
    /// mail default). Prefer `fromHeader(accountId:fromEmail:)` when a
    /// send-as identity may be selected.
    func fromHeader(for accountId: String) -> String {
        fromHeader(accountId: accountId, fromEmail: accountId)
    }

    /// RFC 2822 From for a chosen identity. Uses the send-as display name
    /// when present; falls back to the account's senderName for primaries.
    func fromHeader(accountId: String, fromEmail: String) -> String {
        let email = fromEmail.isEmpty ? accountId : fromEmail
        if let identity = SendIdentityResolver.identity(
            email: email, inMailbox: accountId, from: sendIdentities) {
            return identity.fromHeader
        }
        // Identity list not loaded yet, or email is the primary: use the
        // account's senderName when we have one (covers send-as scheduled
        // sends that fire before refreshSendIdentities finishes).
        if let account = accounts.first(where: { $0.id == accountId }),
           !account.senderName.isEmpty {
            return "\(account.senderName) <\(email)>"
        }
        return email
    }

    // MARK: - New-mail notifications

    private func currentUnreadInboxCandidates() async -> [NewMailNotifications.Candidate] {
        let pool = db
        return (try? await pool.read { db in
            try NewMailNotifications.unreadInboxCandidates(db, now: Date())
        }) ?? []
    }

    /// Seeds the notification baseline without notifying. Runs off the launch
    /// critical path; a sync that beats it is handled by the same flag.
    func seedUnreadBaseline() async {
        guard !newMailNotifications.isSeeded else { return }
        let current = await currentUnreadInboxCandidates()
        guard !newMailNotifications.isSeeded else { return }   // a sync won the race
        newMailNotifications.seed(current)
    }

    private func notifyNewMail() async {
        // `applyBlocklist` runs just before this and moves blocked senders'
        // mail to Spam optimistically; the row write is still queued. Reading
        // ahead of it would see that mail as unread inbox and notify for it.
        _ = await threadMutationPersistenceTask?.value
        guard !isShuttingDown else { return }
        let current = await currentUnreadInboxCandidates()
        // The blocked check repeats here: a block that lands after the sweep
        // above has no Spam move yet.
        let fresh = newMailNotifications.fresh(
            current: current, now: Date(), demoMode: demoMode,
            isBlocked: { self.isBlocked($0) })
        guard !fresh.isEmpty else { return }
        let pool = db
        let (newThreads, detailAccounts) = (try? await pool.read { db in
            (try MailThread.filter(fresh.contains(Column("id")))
                .order(Column("lastDate").desc).fetchAll(db),
             NotificationContent.detailAccounts(db))
        }) ?? ([], [])
        // Generic text unless the thread's account opted in to sender and
        // subject (F-11).
        let items = newThreads.map {
            NotificationContent.MailItem(accountId: $0.accountId, threadId: $0.id,
                                         sender: $0.fromDisplay, subject: $0.subject)
        }
        for request in NotificationContent.newMail(
            items, detailAccounts: detailAccounts) {
            Notifier.notify(request)
        }
    }

    /// Pages a backfill stores while the pass runs reach the list here: the
    /// reading-pane cache of those threads is dropped and the list reloads
    /// (no flicker, selection and scroll kept: `reloadThreads` replaces rows
    /// by id). Sidebar counts, the account badges and the Dock badge come
    /// with the same reload, so they count what is stored so far.
    func makeSyncBatchSink() -> SyncBatchSink {
        SyncBatchSink { [weak self] keys in
            guard let self, !self.isShuttingDown else { return }
            self.applyThreadContentChange(.threads(keys))
            // A reload already running shows these rows or the next batch
            // will; the pass's final reload shows the rest.
            if !self.listLoadInFlight { self.reloadThreads() }
        }
    }

    /// A first sync downloads mail that arrived before the account was
    /// added; none of it is new mail (Gmail notifies only for what arrives).
    /// Mail that arrives during and after the pass still notifies. The same
    /// for the pass that runs the one-time repair of conversations brought
    /// back from the trash: their mail is old.
    func quietBacklogOfFirstSyncs(_ ids: [String]) {
        for id in ids {
            // An account removed meanwhile is not a first sync: nothing of
            // it may be written back (DEC-019).
            guard let account = accounts.first(where: { $0.id == id }) else { continue }
            let repairPending = !UserDefaults.standard.bool(
                forKey: SyncEngine.revivedTrashRepairKey(accountId: id))
            guard account.historyId == nil || repairPending else { continue }
            quietNewMailBacklog(accountId: id)
        }
    }

    /// Once an account's window is listed to its last page (and its first
    /// sync committed), the backlog is stored: record it without notifying
    /// and drop the cutoff, so later first-seen threads notify as before.
    private func settleNewMailBacklog(_ ids: [String], alreadyNotified: Bool) async {
        let waiting = ids.filter { newMailNotifications.hasBacklog(accountId: $0) }
        guard !waiting.isEmpty else { return }
        let pool = db
        let synced = Set((try? await pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT id FROM account WHERE historyId IS NOT NULL
                """)
        }) ?? [])
        let done = waiting.filter { id in
            synced.contains(id)
                && UserDefaults.standard.object(forKey: WindowBackfill.listedKey(accountId: id))
                    as? Int == SyncEngine.syncWindowDays(for: id)
        }
        guard !done.isEmpty else { return }
        if !alreadyNotified { await notifyNewMail() }
        for id in done { newMailNotifications.forgetBacklog(accountId: id) }
    }

    /// The same for older mail a wider "Keep mail from" downloads.
    /// `restart`: the window changed, so the cutoff is now, not the one an
    /// earlier first sync kept (an account on "Nothing" never settles it).
    func quietNewMailBacklog(accountId: String, restart: Bool = false) {
        // DEC-019: nothing is written back for an account removed meanwhile.
        guard isKnownAccount(accountId) else { return }
        if restart { newMailNotifications.forgetBacklog(accountId: accountId) }
        newMailNotifications.quietBacklog(accountId: accountId, before: Date())
    }

    /// A pass that did not complete marks its account failed until the next
    /// one that does; `lastSyncAt` stays at the last completed pass. No
    /// network is not a failure here: the sync control reads "Offline".
    func noteSyncOutcome(account id: String, error: Error?) {
        // Mutating a stored struct publishes even when nothing changes, so
        // compare first: this runs after every pass of every account.
        let missing = MissingMessages.load(accountId: id).undownloadedCount
        if syncHealth.undownloaded[id] ?? 0 != missing {
            syncHealth.setUndownloaded(account: id, count: missing)
        }
        guard let error else {
            // Only a change republishes: this runs on every pass.
            if syncHealth.failedAccounts.contains(id) { syncHealth.recordSuccess(account: id) }
            return
        }
        // Reauth and partial fetches surface too (neither is transient).
        if OfflinePolicy.surfacesSyncFailure(error), !syncHealth.failedAccounts.contains(id) {
            syncHealth.recordFailure(account: id)
        }
    }

    func makeSyncStatusSink(_ message: String) -> ThrottledStatusSink {
        let id = UUID()
        mailProgress.begin(id, message: message)
        return ThrottledStatusSink(id: id, shown: message) { [weak self] status in
            self?.mailProgress.update(id, message: status)
        }
    }

    func endSyncStatus(_ sink: ThrottledStatusSink) {
        sink.close()
        mailProgress.end(sink.id)
    }
}
