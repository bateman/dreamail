import Foundation
import GRDB

/// What the sidebar's label menu has open: the Edit dialog, the Remove
/// confirmation, or a failure with a retry; and the labels with an edit in
/// flight, which take no second one until it is over.
struct LabelMenuState {
    var editing: LabelRow?
    var removing: LabelRow?
    var failure: LabelEditFailure?
    var inFlight: Set<String> = []
}

/// A label edit that did not fully land, said in an alert with a retry.
struct LabelEditFailure: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var retry: (@MainActor () -> Void)?

    /// Up to five names, made safe to show, then how many more.
    static func list(_ names: [String]) -> String {
        let shown = names.prefix(5).map(LabelText.quoted).joined(separator: ", ")
        return names.count > 5 ? "\(shown) and \(names.count - 5) more" : shown
    }
}

extension MailStore {
    /// The stored row of a sidebar label, as it is now.
    func labelRow(_ node: SidebarLabelNode) -> LabelRow? {
        labelsById[node.accountId]?[node.gmailLabelId]
    }

    /// `label` and every label nested under it, from the stored rows.
    func labelFamily(_ label: LabelRow) -> [LabelRow] {
        let rows = userLabels(forAccount: label.accountId)
        let current = rows.first { $0.id == label.id } ?? label
        return LabelFamily.members(of: current, in: rows)
    }

    /// The saved views that go with `label` and its sublabels (not those
    /// that only exclude it: they lose that filter and stay).
    func savedViewsRemoved(with label: LabelRow) -> [SavedView] {
        LabelRemoval.views(savedViews, removing: labelFamily(label),
                           allLabels: labelsByAccount.values.flatMap { $0 }).removed
    }

    /// The filter chips in use apply to `accountId`'s labels.
    private func chipsCover(_ accountId: String) -> Bool {
        activeAccountId == nil || activeAccountId == accountId
    }

    /// Gmail's label list for one account, read again (not a mail sync).
    private func refreshLabels(_ accountId: String) async {
        guard !demoMode, !isShuttingDown, isKnownAccount(accountId) else { return }
        let engine = engines[accountId] ?? SyncEngine(accountId: accountId)
        engines[accountId] = engine
        // A failure leaves the names stored; the next sync reads them.
        try? await engine.refreshLabels()
    }

    /// Gmail, or nothing at all in the demo mailbox.
    private func labelRemote(for accountId: String) -> LabelRemote {
        demoMode ? DemoLabelRemote() : client(for: accountId)
    }

    private static let offlineMessage = "You're offline. Nothing was changed on Gmail."
    private static let busyMessage = "That label is still being saved to Gmail. Try again in a moment."

    /// Claims `ids` for one edit; false (and says so) when one of them is
    /// already being edited.
    private func beginLabelEdit(_ ids: [String]) -> Bool {
        guard labelMenu.inFlight.isDisjoint(with: ids) else {
            lastError = Self.busyMessage
            return false
        }
        labelMenu.inFlight.formUnion(ids)
        return true
    }

    private func endLabelEdit(_ ids: [String]) {
        labelMenu.inFlight.subtract(ids)
    }

    // MARK: In label list / In message list

    func setLabelListVisibility(_ label: LabelRow, _ visibility: SidebarLabelNode.Visibility) {
        patchVisibility(label, GmailLabelPatch(labelListVisibility: visibility))
    }

    func setMessageListVisibility(_ label: LabelRow, _ visibility: MessageListVisibility) {
        patchVisibility(label, GmailLabelPatch(messageListVisibility: visibility))
    }

    /// Shown at once, put back if Gmail refuses. Never queued: offline, it
    /// says so and changes nothing. One edit per label at a time, so a
    /// rollback never restores another edit's optimistic value.
    private func patchVisibility(_ label: LabelRow, _ patch: GmailLabelPatch) {
        guard !isOffline || demoMode else {
            lastError = Self.offlineMessage
            return
        }
        guard beginLabelEdit([label.id]) else { return }
        let remote = labelRemote(for: label.accountId)
        let pool = db
        let accountId = label.accountId
        Task { @MainActor [weak self] in
            do {
                try await LabelVisibilityEdit.apply(patch, rowId: label.id, db: pool,
                                                    didStore: { self?.reloadAccounts() },
                                                    remote: remote)
                guard let self else { return }
                self.endLabelEdit([label.id])
                self.reloadAccounts()
            } catch {
                guard let self else { return }
                self.endLabelEdit([label.id])
                self.reloadAccounts()
                self.reportLabelEditError(error, accountId: accountId,
                                          prefix: "Couldn't change where the label is shown")
            }
        }
    }

    // MARK: Edit

    /// Gmail's "Edit label": renames `label` to `name` under `parent` (nil:
    /// top level), its sublabels moved along. nil on success, else what the
    /// dialog shows. A failure that could not be undone closes the dialog
    /// and opens an alert with a retry instead.
    func renameLabel(_ label: LabelRow, name: String, parent: String?) async -> String? {
        guard !isOffline || demoMode else { return Self.offlineMessage }
        let changes: [LabelRename.Change]
        switch LabelRename.plan(label: label, name: name, parent: parent,
                                rows: userLabels(forAccount: label.accountId)) {
        case .success(let value): changes = value
        case .failure(.unchanged): return nil
        case .failure(let problem): return problem.message
        }
        return await runRenames(changes, accountId: label.accountId)
    }

    private func runRenames(_ changes: [LabelRename.Change], accountId: String) async -> String? {
        let ids = changes.map(\.rowId)
        guard beginLabelEdit(ids) else { return Self.busyMessage }
        defer { endLabelEdit(ids) }
        let (outcome, names) = await LabelRename.execute(changes, remote: labelRemote(for: accountId))
        let pool = db
        var localFailure: String?
        do {
            try await pool.write { db in try LabelRename.store(db, names: names) }
        } catch {
            localFailure = "The names couldn't be saved on this Mac (\(error.localizedDescription)). "
                + "They appear after the next sync."
        }
        followRenameInFilters(changes, names: names)
        if case .renamed = outcome {
            reloadAccounts()
            followRename(names, accountId: accountId)
            if let localFailure { lastError = localFailure }
            return nil
        }
        // A call that timed out may have landed on Gmail all the same: read
        // the names back (labels only) before saying anything about them.
        await refreshLabels(accountId)
        reloadAccounts()
        followRename(names, accountId: accountId)
        let local = localFailure.map { "\n\n" + $0 } ?? ""
        switch outcome {
        case .renamed:
            return nil
        case .rolledBack(let cause):
            if OfflinePolicy.shouldDefer(cause) { isOffline = true }
            return "Couldn't rename the label: \(describe(cause)). The renames that went through were "
                + "undone; the names shown are Gmail's as of now." + local
        case .partial(let renamed, let notRenamed, let cause):
            if OfflinePolicy.shouldDefer(cause) { isOffline = true }
            labelMenu.failure = LabelEditFailure(
                title: "The label was only partly renamed",
                message: "\(describe(cause)).\n\nRenamed: \(LabelEditFailure.list(renamed.map(\.to)))."
                    + "\nStill with the old name: \(LabelEditFailure.list(notRenamed.map(\.from)))."
                    + "\n\nThe sidebar shows Gmail's names as of now." + local,
                retry: { [weak self] in
                    Task { @MainActor in
                        guard let self else { return }
                        if await self.runRenames(notRenamed, accountId: accountId) != nil {
                            self.lastError = "Some labels may still have their old name: "
                                + LabelEditFailure.list(notRenamed.map(\.from)) + "."
                        }
                    }
                })
            return nil
        }
    }

    /// The open label view keeps its selection under the new name (the
    /// stored one: after a failed rename, Gmail's as read back).
    private func followRename(_ names: [String: String], accountId: String) {
        let current = Dictionary(userLabels(forAccount: accountId).map { ($0.id, $0.name) },
                                 uniquingKeysWith: { a, _ in a })
        var known = names
        for key in names.keys { if let name = current[key] { known[key] = name } }
        if let view = LabelSelection.afterRename(selectedView, names: known) { goTo(view) }
    }

    /// The label filter chip and the saved views' chips keep naming a
    /// renamed label by its name on Gmail.
    private func followRenameInFilters(_ changes: [LabelRename.Change], names: [String: String]) {
        let landed = changes.filter { names[$0.rowId] == $0.to }
        guard let first = landed.first else { return }
        let accountId = String(first.rowId.prefix { ch in ch != ":" })
        if chipsCover(accountId) {
            for c in landed { chips.followRename(labelId: c.gmailLabelId, from: c.from, to: c.to) }
        }
        let updated = LabelRename.views(savedViews, after: landed, accountId: accountId)
        guard !updated.isEmpty else { return }
        do {
            try db.write { db in for view in updated { try view.update(db) } }
        } catch {
            lastError = "Saved views couldn't be updated on this Mac (\(error.localizedDescription))."
        }
        reloadSavedViews()
    }

    // MARK: Remove

    /// Gmail web's "Remove label": the label and its sublabels go on Gmail
    /// and here, conversations stay. No undo (Gmail has none); the
    /// confirmation is the safeguard. Offline, nothing is sent or queued.
    ///
    /// `snapshot` is the row the confirmation named. It is looked up again
    /// first: if a sync renamed or removed it meanwhile, nothing is done.
    func removeLabel(_ snapshot: LabelRow) {
        guard !isOffline || demoMode else {
            lastError = "You're offline. The label was not removed."
            return
        }
        let current = (try? db.read { db in
            try LabelRow.filter(Column("accountId") == snapshot.accountId && Column("type") == "user")
                .fetchAll(db)
        }) ?? userLabels(forAccount: snapshot.accountId)
        guard let label = LabelRemoval.resolve(snapshot, current: current) else {
            lastError = "The label \(LabelText.quoted(snapshot.name)) changed on Gmail meanwhile. "
                + "Nothing was removed."
            reloadAccounts()
            return
        }
        let rows = LabelRemoval.order(label, rows: current)
        let ids = rows.map(\.id)
        guard beginLabelEdit(ids) else { return }
        let remote = labelRemote(for: label.accountId)
        let pool = db
        let accountId = label.accountId
        Task { @MainActor [weak self] in
            let report = await LabelRemoval.execute(rows, under: label, remote: remote)
            guard let self else { return }
            let views = LabelRemoval.views(self.savedViews, removing: report.deleted,
                                           allLabels: self.labelsByAccount.values.flatMap { $0 })
            do {
                try await pool.write { db in try LabelRemoval.forget(db, rows: report.deleted, views: views) }
            } catch {
                self.lastError = "The labels were removed on Gmail but couldn't be cleared on this Mac "
                    + "(\(error.localizedDescription)). They go at the next sync."
            }
            LabelRemoval.forgetDefaults(report.deleted)
            if self.chipsCover(accountId) {
                for row in report.deleted { self.chips.dropLabel(row) }
            }
            self.endLabelEdit(ids)
            self.reloadAccounts()
            self.reloadSavedViews()
            if let next = LabelSelection.afterRemoval(self.selectedView, removed: report.deleted,
                                                      views: views.removed) {
                self.goTo(next)
            }
            guard let cause = report.cause else { return }
            if OfflinePolicy.shouldDefer(cause) { self.isOffline = true }
            let removedFirst = report.deleted.isEmpty ? ""
                : "\n\nAlready removed: " + LabelEditFailure.list(report.deleted.map(\.name)) + "."
            if case GmailError.http(403, let body) = cause, !MessageFetchFailureKind.isRateLimitBody(body) {
                // Say what is already gone before asking to sign in again.
                if !report.deleted.isEmpty {
                    self.labelMenu.failure = LabelEditFailure(
                        title: "Some labels were not removed",
                        message: "Google refused the sign-in." + removedFirst + "\nNot removed: "
                            + LabelEditFailure.list(report.notDeleted.map(\.name)) + ".")
                }
                self.requireReauthorization(for: accountId, interactive: true)
                return
            }
            self.labelMenu.failure = LabelEditFailure(
                title: report.deleted.isEmpty ? "The label was not removed" : "Some labels were not removed",
                message: self.describe(cause) + "." + removedFirst + "\n\nNot removed: "
                    + LabelEditFailure.list(report.notDeleted.map(\.name)) + ".",
                // Checked again against the name the confirmation showed.
                retry: { [weak self] in self?.removeLabel(snapshot) })
        }
    }

    // MARK: Errors

    private func reportLabelEditError(_ error: Error, accountId: String, prefix: String) {
        guard isKnownAccount(accountId) else { return }
        if OfflinePolicy.shouldDefer(error) {
            isOffline = true
            lastError = Self.offlineMessage
            return
        }
        if case GmailError.http(403, let body) = error, !MessageFetchFailureKind.isRateLimitBody(body) {
            requireReauthorization(for: accountId, interactive: true)
            return
        }
        lastError = "\(prefix): \(describe(error))"
    }

    private func describe(_ error: Error) -> String {
        if OfflinePolicy.shouldDefer(error) { return "You're offline" }
        return error.localizedDescription
    }
}
