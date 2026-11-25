import Foundation

/// Gmail's mute (`m`), mark important / not important (`+` `=` / `-`) and
/// move to (`v`). Same optimistic path as every triage action
/// (`mutateThread(s)`: sidebar counts and the Dock badge move at once, the
/// thread row is written, Gmail gets `threads.modify`, a refusal re-derives
/// the thread from its messages). The rules are `ConversationAction`.
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
        let bulk = thread == nil && !checkedThreadIds.isEmpty
        let n = targets.count
        let noun = n == 1 ? "Conversation" : "\(n) conversations"
        run(action, on: targets, bulk: bulk,
            autoAdvance: action == .mute ? "mute" : nil,
            undoLabel: action == .mute ? "\(noun) muted" : "\(noun) unmuted")
    }

    // MARK: - Importance

    /// `+` / `=` and `-`. No undo toast: the other key is the undo, as in
    /// Gmail's own importance markers.
    func setImportantTargets(_ important: Bool, thread: MailThread? = nil) {
        let targets = (thread.map { [$0] } ?? actionTargets)
            .filter { $0.isImportant != important }
        guard !targets.isEmpty else { return }
        run(important ? .markImportant : .markNotImportant, on: targets,
            bulk: thread == nil && !checkedThreadIds.isEmpty, autoAdvance: nil, undoLabel: nil)
        let n = targets.count
        showNotice(important
                   ? (n == 1 ? "Marked as important" : "\(n) marked as important")
                   : (n == 1 ? "Marked as not important" : "\(n) marked as not important"))
    }

    // MARK: - Move to

    /// `v`: the label picker in "move" mode.
    func openMovePicker() {
        guard selectedThread != nil else { return }
        openLabelPicker(mode: .move)
    }

    /// Adds `labelId` and removes INBOX on the checked rows, else the focused
    /// one. Labels are per account: checked rows of another account are left
    /// alone and the notice says so.
    func moveTargets(toLabel labelId: String, accountId: String) {
        let all = actionTargets
        let targets = all.filter { $0.accountId == accountId }
        mailboxOverlay = nil
        guard !targets.isEmpty else { return }
        let n = targets.count
        let name = labelName(labelId, account: accountId) ?? "label"
        run(.moveTo(labelId: labelId), on: targets, bulk: !checkedThreadIds.isEmpty,
            autoAdvance: "move",
            undoLabel: n == 1 ? "Moved to \(name)" : "Moved \(n) to \(name)")
        if targets.count < all.count {
            showNotice("Other accounts' conversations were not moved: labels belong to one account")
        }
    }

    /// The label picker's Return / click / Space on a label row.
    func labelPickerCommit(_ label: LabelRow, thread: MailThread) {
        switch labelPicker.mode {
        case .label: toggleLabel(thread, labelId: label.gmailLabelId)
        case .move: moveTargets(toLabel: label.gmailLabelId, accountId: thread.accountId)
        }
    }

    // MARK: - Shared

    private func run(_ action: ConversationAction, on targets: [MailThread], bulk: Bool,
                     autoAdvance: String?, undoLabel: String?) {
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
        offerUndo(undoLabel) { [weak self] in
            guard let self else { return }
            self.pinReadStateKeep(ids)
            for group in action.undoGroups(acted: acted, originals: targets) {
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
