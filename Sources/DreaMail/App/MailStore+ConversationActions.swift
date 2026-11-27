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
        let targets = thread.map { [$0] } ?? actionTargets
        guard !targets.isEmpty else { return }
        let action = ConversationAction.muteToggle(for: targets)
        let n = targets.count
        let noun = n == 1 ? "Conversation" : "\(n) conversations"
        run(ConversationActionRun(action, targets: targets),
            bulk: thread == nil && !checkedThreadIds.isEmpty,
            autoAdvance: action == .mute ? "mute" : nil,
            undoLabel: action == .mute ? "\(noun) muted" : "\(noun) unmuted")
    }

    // MARK: - Importance

    /// `+` / `=` and `-`, with an undo toast as in Gmail.
    func setImportantTargets(_ important: Bool, thread: MailThread? = nil) {
        let targets = (thread.map { [$0] } ?? actionTargets)
            .filter { $0.isImportant != important }
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

    /// The conversation whose account the picker lists labels for: in move
    /// mode the first move target still in the list, else the focused row.
    var labelPickerThread: MailThread? {
        if labelPicker.mode == .move {
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
                isPartlyTrashedRow($0.id) && $0.accountId == accountId
            }
            if !partial.isEmpty {
                restoreTrashedMessages(partial, toLabel: labelId)
                let partialIds = Set(partial.map(\.id))
                all.removeAll { partialIds.contains($0.id) }
                if all.isEmpty { return }
            }
        }
        let plan = ConversationActionRun(
            .moveTo(labelId: labelId, alsoRemove: MoveSource.alsoRemove(
                labelViewId: currentLabelViewId(account: accountId),
                inTrashView: selectedView == .trash)),
            targets: all, account: accountId)
        if !plan.skipped.isEmpty {
            showNotice(plan.skipped.count == 1
                       ? "1 conversation of another account was not moved: labels belong to one account"
                       : "\(plan.skipped.count) conversations of other accounts were not moved: labels belong to one account")
        }
        guard !plan.targets.isEmpty else { return }
        let n = plan.targets.count
        let name = labelName(labelId, account: accountId) ?? "label"
        run(plan, bulk: n > 1 || !checkedThreadIds.isEmpty, autoAdvance: "move",
            undoLabel: n == 1 ? "Moved to \(name)" : "Moved \(n) to \(name)")
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
        switch labelPicker.mode {
        case .label:
            toggleLabel(thread, labelId: label.gmailLabelId)
            labelPicker.changed = true
        case .move:
            moveThreads(ids: labelPicker.moveTargetIds, toLabel: label.gmailLabelId,
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
                moveMode: moveMode, changed: labelPicker.changed) {
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
        guard !plan.targets.isEmpty else { return }
        let action = plan.action
        let focus = selectedThreadId
        let acted: [MailThread]
        if bulk {
            acted = mutateThreads(plan.targets, autoAdvanceAction: autoAdvance,
                                  remote: action.remote, local: { action.apply(&$0) })
            clearCheckedThreads()
        } else {
            acted = [mutateThread(plan.targets[0], autoAdvanceAction: autoAdvance,
                                  remote: action.remote) { action.apply(&$0) }]
        }
        guard let undoLabel else { return }
        let ids = plan.targets.map(\.id)
        let groups = action.undoGroups(acted: acted, originals: plan.targets)
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
