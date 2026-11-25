import Foundation

/// What the sidebar's label menu has open: the Edit dialog, the Remove
/// confirmation, or a failure with a retry.
struct LabelMenuState {
    var editing: LabelRow?
    var removing: LabelRow?
    var failure: LabelEditFailure?
}

/// A label edit that did not fully land, said in an alert with a retry.
struct LabelEditFailure: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var retry: (@MainActor () -> Void)?

    /// Up to five names, then how many more.
    static func list(_ names: [String]) -> String {
        let shown = names.prefix(5).map { "“\($0)”" }.joined(separator: ", ")
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

    /// Gmail, or nothing at all in the demo mailbox.
    private func labelRemote(for accountId: String) -> LabelRemote {
        demoMode ? DemoLabelRemote() : client(for: accountId)
    }

    private static let offlineMessage = "You're offline. Nothing was changed on Gmail."

    // MARK: In label list / In message list

    func setLabelListVisibility(_ label: LabelRow, _ visibility: SidebarLabelNode.Visibility) {
        patchVisibility(label, GmailLabelPatch(labelListVisibility: visibility))
    }

    func setMessageListVisibility(_ label: LabelRow, _ visibility: MessageListVisibility) {
        patchVisibility(label, GmailLabelPatch(messageListVisibility: visibility))
    }

    /// Shown at once, put back if Gmail refuses. Never queued: offline, it
    /// says so and changes nothing.
    private func patchVisibility(_ label: LabelRow, _ patch: GmailLabelPatch) {
        guard !isOffline || demoMode else {
            lastError = Self.offlineMessage
            return
        }
        let remote = labelRemote(for: label.accountId)
        let pool = db
        let accountId = label.accountId
        Task { @MainActor [weak self] in
            do {
                try await LabelVisibilityEdit.apply(patch, rowId: label.id, db: pool,
                                                    didStore: { self?.reloadAccounts() },
                                                    remote: remote)
                self?.reloadAccounts()
            } catch {
                guard let self else { return }
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
        let (outcome, names) = await LabelRename.execute(changes, remote: labelRemote(for: accountId))
        let pool = db
        try? await pool.write { db in try LabelRename.store(db, names: names) }
        reloadAccounts()
        followRename(names, accountId: accountId)
        switch outcome {
        case .renamed:
            return nil
        case .rolledBack(let cause):
            if OfflinePolicy.shouldDefer(cause) { isOffline = true }
            return "Couldn't rename the label: \(describe(cause)). Nothing was changed."
        case .partial(let renamed, let notRenamed, let cause):
            if OfflinePolicy.shouldDefer(cause) { isOffline = true }
            labelMenu.failure = LabelEditFailure(
                title: "The label was only partly renamed",
                message: "\(describe(cause)).\n\nRenamed: \(LabelEditFailure.list(renamed.map(\.to)))."
                    + "\nStill with the old name: \(LabelEditFailure.list(notRenamed.map(\.from))).",
                retry: { [weak self] in
                    Task { @MainActor in
                        guard let self else { return }
                        if await self.runRenames(notRenamed, accountId: accountId) != nil {
                            self.lastError = "Some labels still have their old name: "
                                + LabelEditFailure.list(notRenamed.map(\.from)) + "."
                        }
                    }
                })
            return nil
        }
    }

    /// The open label view keeps its selection under the new name.
    private func followRename(_ names: [String: String], accountId: String) {
        guard case .label(let account, let labelId, let old) = selectedView, account == accountId,
              let name = names["\(accountId):\(labelId)"], name != old else { return }
        goTo(.label(account: account, labelId: labelId, name: name))
    }

    // MARK: Remove

    /// Gmail web's "Remove label": the label and its sublabels go on Gmail
    /// and here, conversations stay. No undo (Gmail has none); the
    /// confirmation is the safeguard. Offline, nothing is sent or queued.
    func removeLabel(_ label: LabelRow) {
        guard !isOffline || demoMode else {
            lastError = "You're offline. The label was not removed."
            return
        }
        let rows = LabelRemoval.order(label, rows: userLabels(forAccount: label.accountId))
        let remote = labelRemote(for: label.accountId)
        let pool = db
        let accountId = label.accountId
        Task { @MainActor [weak self] in
            let report = await LabelRemoval.execute(rows, under: label, remote: remote)
            try? await pool.write { db in try LabelRemoval.forget(db, rows: report.deleted) }
            guard let self else { return }
            for row in report.deleted {
                SidebarDisclosure.forget(row.gmailLabelId, accountId: row.accountId)
            }
            self.reloadAccounts()
            if case .label(let account, let labelId, _) = self.selectedView, account == accountId,
               report.deleted.contains(where: { $0.gmailLabelId == labelId }) {
                self.goTo(.inbox)
            }
            guard let cause = report.cause else { return }
            if OfflinePolicy.shouldDefer(cause) { self.isOffline = true }
            if case GmailError.http(403, let body) = cause, !MessageFetchFailureKind.isRateLimitBody(body) {
                self.requireReauthorization(for: accountId, interactive: true)
                return
            }
            let offline = OfflinePolicy.shouldDefer(cause)
            self.labelMenu.failure = LabelEditFailure(
                title: report.deleted.isEmpty ? "The label was not removed" : "Some labels were not removed",
                message: (offline ? "You're offline" : self.describe(cause)) + ".\n\nNot removed: "
                    + LabelEditFailure.list(report.notDeleted.map(\.name)) + ".",
                retry: { [weak self] in
                    guard let self,
                          let current = self.userLabels(forAccount: accountId).first(where: { $0.id == label.id })
                    else { return }
                    self.removeLabel(current)
                })
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
