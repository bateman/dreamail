import Foundation

/// Gmail's mute, importance and "move to" on a whole conversation: the
/// local change, the Gmail change and the undo. Pure, like `ThreadUndo`,
/// so the round trip is tested against the database.
///
/// All of them are label edits on the thread (`threads.modify`):
/// - Mute adds `MUTED` and removes `INBOX` (Gmail archives a muted
///   conversation; its later replies skip the inbox). Unmute only removes
///   `MUTED`: as in Gmail, the conversation does not come back to the inbox.
/// - Important / not important add or remove `IMPORTANT`.
/// - Move to adds the label and removes `INBOX`, plus the place the move
///   leaves: the label of the label view it runs in, or `TRASH` from Trash
///   (`MoveSource`).
///
/// The undo is a label edit too, built from the pre-action snapshot, so it
/// gives back exactly what the action took (INBOX only when the thread had
/// it, the label only when it was new).
enum ConversationAction: Equatable {
    case mute
    case unmute
    case markImportant
    case markNotImportant
    /// `alsoRemove`: what the move leaves besides INBOX (`MoveSource`).
    case moveTo(labelId: String, alsoRemove: [String] = [])

    /// Gmail's "Move to Inbox": adds INBOX and nothing else, so the
    /// conversation keeps its labels and stays in All Mail, a label view or
    /// a search. Undo removes INBOX again (archives it).
    static let moveToInbox = ConversationAction.moveTo(labelId: inboxLabel)

    static let inboxLabel = "INBOX"
    static let mutedLabel = "MUTED"
    static let importantLabel = "IMPORTANT"

    private var labelEdit: (add: [String], remove: [String]) {
        switch self {
        case .mute: return ([Self.mutedLabel], ["INBOX"])
        case .unmute: return ([], [Self.mutedLabel])
        case .markImportant: return ([Self.importantLabel], [])
        case .markNotImportant: return ([], [Self.importantLabel])
        case .moveTo(let labelId, let alsoRemove):
            // Moving to the Inbox itself (Gmail's "Move to Inbox") adds INBOX
            // and leaves only what the place it leaves asks for.
            return ([labelId], (["INBOX"] + alsoRemove.filter { $0 != "INBOX" })
                .filter { $0 != labelId })
        }
    }

    /// The Gmail side of the action.
    var remote: RemoteThreadChange {
        let edit = labelEdit
        return .modify(add: edit.add, remove: edit.remove)
    }

    /// The local side: labels and the denormalized flags together.
    func apply(_ t: inout MailThread) {
        Self.applyLabels(remote, &t)
        // Back in the Inbox means awake: a conversation snoozed here takes
        // the unsnooze path (date cleared, Gmail's snooze ended).
        if labelEdit.add.contains(Self.inboxLabel), t.snoozeUntil != nil {
            ThreadUndo.unsnooze(&t)
        }
    }

    /// Gmail side of the undo for one thread, from its pre-action snapshot.
    /// Can be empty (moving a thread outside the inbox to a label it already
    /// had): the store never sends an empty modify.
    func undoRemote(original: MailThread) -> RemoteThreadChange {
        let edit = labelEdit
        let had = Set(original.labels)
            .union(original.inInbox ? ["INBOX"] : [])
            .union(original.isStarred ? ["STARRED"] : [])
        return .modify(add: edit.remove.filter { had.contains($0) },
                       remove: edit.add.filter { !had.contains($0) })
    }

    /// Local undo; `t` is the post-action copy (the diff base of the write).
    func restore(original: MailThread, _ t: inout MailThread) {
        Self.applyLabels(undoRemote(original: original), &t)
    }

    /// Bulk undo: one group per distinct undo change, because one bulk
    /// mutation carries one Gmail change. `acted` are the post-action copies,
    /// `originals` the pre-action snapshots; list order is kept per group.
    func undoGroups(acted: [MailThread], originals: [MailThread])
        -> [(change: RemoteThreadChange, threads: [MailThread])] {
        let byId = Dictionary(originals.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var groups: [(change: RemoteThreadChange, threads: [MailThread])] = []
        for thread in acted {
            guard let original = byId[thread.id] else { continue }
            let change = undoRemote(original: original)
            if let i = groups.firstIndex(where: { $0.change == change }) {
                groups[i].threads.append(thread)
            } else {
                groups.append((change, [thread]))
            }
        }
        return groups
    }

    private static func applyLabels(_ change: RemoteThreadChange, _ t: inout MailThread) {
        t.applyLabelMutation(add: Set(change.addLabels), remove: Set(change.removeLabels))
    }

    // MARK: - Toggles (one key, as Gmail's `m` and `!`)

    /// `m`: mute, or unmute a conversation that is already muted. Over a
    /// multi-select: mute all unless every one is muted.
    static func muteToggle(for threads: [MailThread]) -> ConversationAction {
        threads.allSatisfy(\.isMuted) && !threads.isEmpty ? .unmute : .mute
    }
}

/// What Gmail's "Move to" leaves, by the list it runs in: a label view
/// leaves that label, Trash leaves the trash, the inbox and every other list
/// only the inbox. There is no Spam list in the app; a spam conversation
/// found by a search keeps SPAM (moving it out of spam is "Not spam", `!`).
enum MoveSource {
    static func alsoRemove(labelViewId: String?, inTrashView: Bool) -> [String] {
        if inTrashView { return ["TRASH"] }
        return labelViewId.map { [$0] } ?? []
    }
}

/// A conversation action over the targets a key or menu picked, split by
/// account (labels belong to one account) and paired with its undo. Pure:
/// `MailStore` writes `acted` through `mutateThread(s)` and the undo groups
/// through `mutateThreads`; tests run the same plan against a database.
struct ConversationActionRun {
    let action: ConversationAction
    /// Pre-action snapshots that the action applies to.
    let targets: [MailThread]
    /// Post-action copies, in `targets` order.
    let acted: [MailThread]
    /// Targets left alone because they belong to another account.
    let skipped: [MailThread]

    /// - Parameter account: only threads of this account are acted on (a
    ///   label id means nothing in another account); nil acts on all.
    init(_ action: ConversationAction, targets all: [MailThread], account: String? = nil) {
        self.action = action
        targets = all.filter { account == nil || $0.accountId == account }
        skipped = all.filter { account != nil && $0.accountId != account }
        acted = targets.map { t in var c = t; action.apply(&c); return c }
    }

    var undoGroups: [(change: RemoteThreadChange, threads: [MailThread])] {
        action.undoGroups(acted: acted, originals: targets)
    }
}

extension MailThread {
    var isMuted: Bool { labels.contains(ConversationAction.mutedLabel) }
    var isImportant: Bool { labels.contains(ConversationAction.importantLabel) }
}

/// Where Gmail shows "Move to Inbox" instead of "Archive": for every
/// conversation not in the Inbox (archived, snoozed, found in All Mail, a
/// label, Sent or a search). Trash and Spam keep their own restore actions
/// (Move to, Not spam), so their rows keep the surfaces they had.
enum InboxMove {
    static func offered(for t: MailThread) -> Bool {
        !t.inInbox && !t.inTrash && !t.inSpam
    }

    /// Over several targets (keys, palette, menu): only when every one of
    /// them offers it; a mix keeps Archive, as before.
    static func offered(for threads: [MailThread]) -> Bool {
        !threads.isEmpty && threads.allSatisfy { offered(for: $0) }
    }

    /// A conversation snoozed here goes back through unsnooze (it also clears
    /// the wake-up date), not through a plain label edit.
    static func isUnsnooze(_ t: MailThread) -> Bool { t.snoozeUntil != nil }

    /// Every surface's label and SF Symbol (monochrome, macOS 11+): a tray
    /// with a down arrow, Gmail's own "Move to Inbox" glyph.
    static let title = "Move to inbox"
    static let symbol = "tray.and.arrow.down"

    static func undoLabel(count n: Int) -> String {
        n == 1 ? "Conversation moved to inbox" : "\(n) conversations moved to inbox"
    }
}

/// Gmail reserves the names of its system labels: "no USER label can be
/// created with the same name as any SYSTEM label", and other reserved names
/// fail with "HTTP 400 Invalid label name" (developers.google.com/gmail/api/
/// guides/labels). Only the system labels that guide documents are listed
/// (DRAFTS too: the API reference spells it so). The picker never offers
/// "Create" for them; for "Inbox" it offers Move to Inbox instead.
enum ReservedLabelNames {
    static let names: Set<String> = [
        "inbox", "spam", "trash", "unread", "starred", "important", "sent",
        "draft", "drafts", "category_personal", "category_social",
        "category_promotions", "category_updates", "category_forums",
    ]

    static func isReserved(_ name: String) -> Bool {
        let key = name.trimmingCharacters(in: .whitespaces)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
        return names.contains(key)
    }
}
