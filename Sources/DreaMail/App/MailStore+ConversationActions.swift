import Foundation

/// Gmail's mute (`m`), mark important / not important (`+` `=` / `-`) and
/// move to (`v`). Same optimistic path as every triage action
/// (`mutateThread(s)`: sidebar counts and the Dock badge move at once, the
/// thread row is written, Gmail gets `threads.modify`, a refusal re-derives
/// the thread from its messages). The rules are `ConversationAction` and
/// `ConversationActionRun`.
extension MailStore {
    /// The threads a key acts on: the checked rows, else the focused one.
    private var actionTargets: [MailThread] {
        if !checkedThreadIds.isEmpty { return checkedThreadsInOrder }
        return selectedThread.map { [$0] } ?? []
    }

    // MARK: - Mute

    /// `m`: mute (unmute when every target is already muted). `thread`: the
    /// conversation toolbar's own thread instead of the key's targets.
    func toggleMuteTargets(_ thread: MailThread? = nil) {
        toggleMute(thread.map { [$0] } ?? actionTargets, bulk: thread == nil && !checkedThreadIds.isEmpty)
    }

    /// The row menu over a checked set: the ids the menu was built for
    /// (`ThreadRowMenu.liveTargets`), never the focused row as a fallback.
    func toggleMuteTargets(ids: [String]) {
        toggleMute(ThreadRowMenu.liveTargets(ids: ids, in: threads), bulk: true)
    }

    private func toggleMute(_ all: [MailThread], bulk: Bool) {
        guard !refusesPartlyTrashed(all) else { return }
        let targets = all.filter { !isPartlyTrashedRow($0) }
        guard !targets.isEmpty else { return }
        let action = ConversationAction.muteToggle(for: targets)
        let n = targets.count
        let noun = n == 1 ? "Conversation" : "\(n) conversations"
        run(ConversationActionRun(action, targets: targets),
            bulk: bulk,
            autoAdvance: action == .mute ? "mute" : nil,
            undoLabel: action == .mute ? "\(noun) muted" : "\(noun) unmuted")
    }

    // MARK: - Importance

    /// `+` / `=` and `-`, with an undo toast as in Gmail.
    func setImportantTargets(_ important: Bool, thread: MailThread? = nil) {
        let all = thread.map { [$0] } ?? actionTargets
        guard !refusesPartlyTrashed(all) else { return }
        let targets = all.filter { $0.isImportant != important && !isPartlyTrashedRow($0) }
        guard !targets.isEmpty else { return }
        if !important {
            // Under Priority "starred + important" the rows can leave the
            // section: move the focus first, as unstar does.
            advanceForPriorityUnstar(targets) {
                $0.applyLabelMutation(remove: [ConversationAction.importantLabel])
            }
        }
        let n = targets.count
        run(ConversationActionRun(important ? .markImportant : .markNotImportant, targets: targets),
            bulk: thread == nil && !checkedThreadIds.isEmpty, autoAdvance: nil,
            undoLabel: important
                ? (n == 1 ? "Marked as important" : "\(n) marked as important")
                : (n == 1 ? "Marked as not important" : "\(n) marked as not important"))
    }

    // MARK: - Move to Inbox

    /// Gmail's "Move to inbox" (toolbar, row, menu, palette, the
    /// `moveToInbox` command) on the conversations that offer it
    /// (`InboxMove.offered`). The rules, the per-conversation edit and the
    /// undo are `InboxMove.Plan`. `thread`: the toolbar's or row's own
    /// conversation instead of the key's targets.
    func moveToInboxTargets(_ thread: MailThread? = nil) {
        let all = thread.map { [$0] } ?? actionTargets
        guard !refusesPartlyTrashed(all) else { return }
        runInboxMove(InboxMove.Plan(all, isPartlyTrashed: isPartlyTrashedRow),
                     bulk: thread == nil && !checkedThreadIds.isEmpty,
                     undoLabel: InboxMove.undoLabel(count:))
    }

    /// The row menu over a checked set (see `toggleMuteTargets(ids:)`).
    func moveToInboxTargets(ids: [String]) {
        let all = ThreadRowMenu.liveTargets(ids: ids, in: threads)
        guard !refusesPartlyTrashed(all) else { return }
        runInboxMove(InboxMove.Plan(all, isPartlyTrashed: isPartlyTrashedRow),
                     bulk: true, undoLabel: InboxMove.undoLabel(count:))
    }

    /// Writes an Inbox move: one bulk mutation with each conversation's own
    /// Gmail change, the snoozes it ends kept for a refusal, and one undo.
    private func runInboxMove(_ plan: InboxMove.Plan, bulk: Bool,
                              undoLabel: (Int) -> String) {
        guard !plan.targets.isEmpty else { return }
        let focus = selectedThreadId
        let acted = mutateThreads(plan.targets, autoAdvanceAction: "move-to-inbox",
                                  remote: .modify(), remotes: plan.remotes,
                                  local: { plan.apply(&$0) })
        endedSnoozes.begin(plan)
        if bulk { clearCheckedThreads() }
        let ids = plan.targets.map(\.id)
        offerUndo(undoLabel(plan.targets.count)) { [weak self] in
            guard let self else { return }
            self.pinReadStateKeep(ids)
            self.endedSnoozes.undone(ids)
            self.mutateThreads(acted, remote: .modify(), remotes: plan.undoRemotes,
                               local: { plan.restore(&$0) })
            self.restoreSelectionFocus(focus)
        }
    }

    /// True when the key's targets (checked rows, else the focused one) get
    /// "Move to inbox" in place of "Archive" (app menu, palette).
    var targetsOfferMoveToInbox: Bool { InboxMove.offered(for: actionTargets) }

    // MARK: - Move to

    /// `v` (and the menu and palette): the label picker in "move" mode, over
    /// the key's targets. The toolbar passes its own conversation.
    func openMovePicker(thread: MailThread? = nil) {
        let ids = MovePickerRules.targetIds(
            toolbarThread: thread?.id,
            checkedInOrder: checkedThreadIds.isEmpty ? [] : checkedThreadsInOrder.map(\.id),
            focused: selectedThreadId)
        guard !ids.isEmpty else { return }
        openLabelPicker(mode: .move, moveTargetIds: ids)
    }

    /// The row menu over a checked set (see `toggleMuteTargets(ids:)`).
    func openMovePicker(ids: [String]) {
        let live = ThreadRowMenu.liveTargets(ids: ids, in: threads).map(\.id)
        guard !live.isEmpty else { return }
        openLabelPicker(mode: .move, moveTargetIds: live)
    }

    /// The conversation the picker acts on and lists labels for: the first
    /// target still in the list (move mode, or label mode opened from a
    /// row's menu), else the focused row.
    var labelPickerThread: MailThread? {
        // Label mode with a target: the row whose context menu opened it.
        if labelPicker.mode == .move || !labelPicker.moveTargetIds.isEmpty {
            let ids = labelPicker.moveTargetIds
            return ids.lazy.compactMap { id in self.threads.first { $0.id == id } }.first
        }
        return selectedThread
    }

    /// Adds `labelId` and removes INBOX (plus the label view's own label, or
    /// TRASH in Trash: `MoveSource`) on the picked conversations. Labels are
    /// per account: conversations of another account are left alone, and the
    /// notice says so, even when that leaves nothing to move.
    func moveThreads(ids: [String], toLabel labelId: String, accountId: String) {
        mailboxOverlay = nil
        let byId = Dictionary(threads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var all = ids.compactMap { byId[$0] }
        // A Trash row of a conversation that is otherwise live gives back
        // only its trashed messages; the rest of it is not touched.
        do {
            let partial = all.filter {
                isPartlyTrashedRow($0) && $0.accountId == accountId
            }
            if !partial.isEmpty {
                restoreTrashedMessages(partial, toLabel: labelId)
                let partialIds = Set(partial.map(\.id))
                all.removeAll { partialIds.contains($0.id) }
                if all.isEmpty {
                    // Only Trash copies: say what was done, as a move does.
                    // No undo: a restore has none.
                    let name = destinationName(labelId, account: accountId)
                    if !checkedThreadIds.isEmpty { clearCheckedThreads() }
                    showNotice(partial.count == 1 ? "Moved to \(name)"
                                                  : "Moved \(partial.count) to \(name)")
                    return
                }
            }
        }
        let labelViewId = currentLabelViewId(account: accountId)
        if labelId == ConversationAction.inboxLabel {
            // Inbox as a destination: each conversation's own edit (TRASH
            // and MUTED go too, `InboxMove`); spam and lone drafts stay.
            let plan = InboxMove.Plan(all, fromPicker: true, labelViewId: labelViewId,
                                      account: accountId, isPartlyTrashed: isPartlyTrashedRow)
            noticeSkippedAccounts(plan.skipped.count)
            let name = destinationName(labelId, account: accountId)
            runInboxMove(plan, bulk: plan.targets.count > 1 || !checkedThreadIds.isEmpty,
                         undoLabel: { $0 == 1 ? "Moved to \(name)" : "Moved \($0) to \(name)" })
            return
        }
        let plan = ConversationActionRun(
            .moveTo(labelId: labelId, alsoRemove: MoveSource.alsoRemove(
                labelViewId: labelViewId,
                inTrashView: selectedView == .trash)),
            targets: all, account: accountId)
        noticeSkippedAccounts(plan.skipped.count)
        guard !plan.targets.isEmpty else { return }
        let n = plan.targets.count
        let name = destinationName(labelId, account: accountId)
        run(plan, bulk: n > 1 || !checkedThreadIds.isEmpty, autoAdvance: "move",
            undoLabel: n == 1 ? "Moved to \(name)" : "Moved \(n) to \(name)")
    }

    private func noticeSkippedAccounts(_ n: Int) {
        guard n > 0 else { return }
        showNotice(n == 1
                   ? "1 conversation of another account was not moved: labels belong to one account"
                   : "\(n) conversations of other accounts were not moved: labels belong to one account")
    }

    /// A Move to destination's name for the toasts: the label's, or Inbox.
    private func destinationName(_ labelId: String, account accountId: String) -> String {
        labelId == ConversationAction.inboxLabel
            ? LabelPickerInboxRow.name : (labelName(labelId, account: accountId) ?? "label")
    }

    /// The label of the label view the list shows, when it is `accountId`'s.
    private func currentLabelViewId(account accountId: String) -> String? {
        if case .label(let account, let labelId, _) = selectedView, account == accountId {
            return labelId
        }
        return nil
    }

    /// The label picker's Return / click / Space on a label row.
    func labelPickerCommit(_ label: LabelRow, thread: MailThread) {
        switch LabelPickerInboxRow.commit(moveMode: labelPicker.mode == .move,
                                          labelId: label.gmailLabelId) {
        case .moveToInbox:
            // "Label as" → "Move to inbox": an action, not a label box.
            mailboxOverlay = nil
            moveToInboxTargets(thread)
        case .toggleLabel(let labelId):
            toggleLabel(thread, labelId: labelId)
            labelPicker.changed = true
        case .move(let labelId):
            moveThreads(ids: labelPicker.moveTargetIds, toLabel: labelId,
                        accountId: thread.accountId)
        }
    }

    /// Return / Space on the highlighted row. A label row is applied (toggled,
    /// or moved); Return in label mode then closes the picker, Space keeps it
    /// open. The "Create …" row keeps its own behaviour.
    func labelPickerActivateHighlighted(closeAfterApply: Bool) {
        guard let thread = labelPickerThread else { return }
        let labels = labelPickerLabels(for: thread)
        let createName = labelPickerCreateName(for: thread)
        let rowCount = labels.count + (createName != nil ? 1 : 0)
        let idx = min(labelPicker.highlight, max(rowCount - 1, 0))
        if let label = labels[safe: idx] {
            let moveMode = labelPicker.mode == .move
            if closeAfterApply, !LabelPickerKeyRules.returnTogglesLabel(
                moveMode: moveMode, changed: labelPicker.changed,
                actionRow: label.gmailLabelId == ConversationAction.inboxLabel) {
                mailboxOverlay = nil   // Return after a pick only closes
                return
            }
            labelPickerCommit(label, thread: thread)
            if LabelPickerKeyRules.closesAfterApply(moveMode: moveMode, closeKey: closeAfterApply) {
                mailboxOverlay = nil
            }
        } else if let createName {
            createLabelAndApply(name: createName, thread: thread)
        }
    }

    // MARK: - Shared

    private func run(_ plan: ConversationActionRun, bulk: Bool,
                     autoAdvance: String?, undoLabel: String?) {
        // A Trash row of an otherwise live conversation takes no thread-wide
        // action: say so, and offer no undo for what was not done.
        let targets = plan.targets.filter { !isPartlyTrashedRow($0) }
        guard !targets.isEmpty else {
            if !plan.targets.isEmpty { showNotice(Self.partlyTrashedNotice) }
            return
        }
        let action = plan.action
        let focus = selectedThreadId
        let acted: [MailThread]
        if bulk {
            acted = mutateThreads(targets, autoAdvanceAction: autoAdvance,
                                  remote: action.remote, local: { action.apply(&$0) })
            clearCheckedThreads()
        } else {
            acted = [mutateThread(targets[0], autoAdvanceAction: autoAdvance,
                                  remote: action.remote) { action.apply(&$0) }]
        }
        guard let undoLabel else { return }
        let ids = targets.map(\.id)
        let groups = action.undoGroups(acted: acted, originals: targets)
        offerUndo(undoLabel) { [weak self] in
            guard let self else { return }
            self.pinReadStateKeep(ids)
            for group in groups {
                let change = group.change
                self.mutateThreads(group.threads, remote: change, local: {
                    $0.applyLabelMutation(add: Set(change.addLabels),
                                          remove: Set(change.removeLabels))
                })
            }
            self.restoreSelectionFocus(focus)
        }
    }
}
