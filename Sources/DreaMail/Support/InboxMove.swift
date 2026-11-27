import Foundation
import GRDB

/// Gmail's "Move to inbox" for a conversation not in the Inbox: which
/// conversations get it, what each one's label edit is, and its undo. Pure;
/// `MailStore.moveToInbox` writes `acted` through `mutateThreads` with
/// `remotes`, and the undo with `undoRemotes` and `restore`. Tests run the
/// same plan against a database.
///
/// Per conversation, a move to the Inbox adds INBOX and removes:
/// - the label of the label view it runs in, when it comes from "Move to…"
///   there (Gmail's Move to leaves the place it runs in; the explicit
///   "Move to inbox" button keeps the label);
/// - TRASH when the conversation is in the Trash, wherever it was reached
///   (the Trash view or an `in:trash` search): otherwise it would still be
///   purged after 30 days. Only through "Move to…": the button is not
///   offered there;
/// - MUTED. Assumption (Gmail's own behaviour not verified): whoever moves
///   a muted conversation back wants its replies in the Inbox again.
/// A conversation snoozed here is unsnoozed (`ConversationAction.apply`).
/// The undo gives back exactly what was taken, the snooze date included.
enum InboxMove {
    /// Gmail shows "Move to inbox" in place of "Archive" for a conversation
    /// that is not in the Inbox. Trash and Spam keep their own restore
    /// actions (Move to, Not spam); a draft-only conversation has nothing to
    /// move.
    static func offered(for t: MailThread) -> Bool {
        !t.inInbox && !t.inTrash && !t.inSpam && !isDraftOnly(t)
    }

    /// Over several targets (keys, palette, menu): only when every one of
    /// them offers it; a mix keeps Archive, as before.
    static func offered(for threads: [MailThread]) -> Bool {
        !threads.isEmpty && threads.allSatisfy { offered(for: $0) }
    }

    /// The only message is the user's own draft (the row reads "Draft").
    static func isDraftOnly(_ t: MailThread) -> Bool {
        t.inDrafts && t.messageCount <= 1
    }

    /// "Move to…" → Inbox: everything not already in the Inbox, except spam
    /// (Not spam is its way out) and draft-only conversations. Trash rows
    /// are included: their TRASH goes too.
    static func movable(_ t: MailThread) -> Bool {
        !t.inInbox && !t.inSpam && !isDraftOnly(t)
    }

    /// Every surface's label and SF Symbol (monochrome, macOS 11+): a tray
    /// with a down arrow, Gmail's own "Move to inbox" glyph.
    static let title = "Move to inbox"
    static let symbol = "tray.and.arrow.down"

    static func undoLabel(count n: Int) -> String {
        n == 1 ? "Conversation moved to inbox" : "\(n) conversations moved to inbox"
    }

    /// The label edit of one conversation (see the type's comment).
    static func action(for t: MailThread, labelViewId: String? = nil) -> ConversationAction {
        var remove: [String] = []
        if let labelViewId { remove.append(labelViewId) }
        if t.inTrash { remove.append("TRASH") }
        if t.isMuted { remove.append(ConversationAction.mutedLabel) }
        return .moveTo(labelId: ConversationAction.inboxLabel, alsoRemove: remove)
    }

    /// One move to the Inbox over the conversations a surface picked.
    struct Plan {
        /// Pre-action snapshots that the move applies to, in pick order.
        let targets: [MailThread]
        /// Targets left alone because they belong to another account.
        let skipped: [MailThread]
        let actions: [String: ConversationAction]
        /// Post-action copies, in `targets` order.
        let acted: [MailThread]
        /// Gmail change per thread id, and its undo.
        let remotes: [String: RemoteThreadChange]
        let undoRemotes: [String: RemoteThreadChange]
        /// Snooze dates the move ends, by thread id: a refusal puts them back.
        let endedSnoozes: [String: Date]

        /// - `fromPicker`: "Move to…" → Inbox (trash rows included,
        ///   `movable`); else the explicit action (`offered`).
        /// - `labelViewId`: the label view "Move to…" runs in, if any.
        /// - `account`: only this account's conversations (the picker's).
        /// - `isPartlyTrashed`: Trash copies of live conversations are left
        ///   out; "Move to…" restores their trashed messages instead
        ///   (`TrashedMessages`, DEC-081).
        init(_ all: [MailThread], fromPicker: Bool = false, labelViewId: String? = nil,
             account: String? = nil, isPartlyTrashed: (MailThread) -> Bool = { _ in false }) {
            let eligible = all.filter {
                (fromPicker ? InboxMove.movable($0) : InboxMove.offered(for: $0))
                    && !isPartlyTrashed($0)
            }
            targets = eligible.filter { account == nil || $0.accountId == account }
            skipped = eligible.filter { account != nil && $0.accountId != account }
            var actions: [String: ConversationAction] = [:]
            var acted: [MailThread] = []
            var remotes: [String: RemoteThreadChange] = [:]
            var undoRemotes: [String: RemoteThreadChange] = [:]
            var ended: [String: Date] = [:]
            for t in targets {
                let action = InboxMove.action(for: t, labelViewId: labelViewId)
                var copy = t
                action.apply(&copy)
                actions[t.id] = action
                acted.append(copy)
                remotes[t.id] = action.remote
                undoRemotes[t.id] = action.undoRemote(original: t)
                if let until = t.snoozeUntil { ended[t.id] = until }
            }
            self.actions = actions
            self.acted = acted
            self.remotes = remotes
            self.undoRemotes = undoRemotes
            endedSnoozes = ended
        }

        /// The local move of `t` (a target, by id).
        func apply(_ t: inout MailThread) {
            actions[t.id]?.apply(&t)
        }

        /// The local undo of `t`, a post-action copy.
        func restore(_ t: inout MailThread) {
            guard let action = actions[t.id],
                  let original = targets.first(where: { $0.id == t.id }) else { return }
            action.restore(original: original, &t)
        }
    }

    /// After Gmail refused a move to the Inbox that ended a snooze: the row
    /// was re-derived from its messages (still without INBOX), and the date,
    /// which lives only here, is put back. Not when the row is in the Inbox
    /// again or was snoozed anew meanwhile. Returns whether it wrote.
    @discardableResult
    static func restoreSnoozeAfterRefusal(_ db: Database, threadId: String,
                                          until: Date) throws -> Bool {
        guard var row = try MailThread.fetchOne(db, key: threadId),
              row.snoozeUntil == nil, !row.inInbox, !row.inTrash, !row.inSpam else { return false }
        let before = row
        row.snoozeUntil = until
        try OptimisticThreadWrite.updateChangedColumns(db, from: before, to: row)
        return true
    }

    /// Whether a refused change is a move to the Inbox (the only edit whose
    /// refusal gives a snooze back).
    static func refusalRestoresSnooze(_ refused: RemoteThreadChange?) -> Bool {
        refused?.addLabels.contains(ConversationAction.inboxLabel) ?? false
    }
}

/// Gmail reserves the names of its system labels: "no USER label can be
/// created with the same name as any SYSTEM label", and other reserved names
/// fail with "HTTP 400 Invalid label name" (developers.google.com/gmail/api/
/// guides/labels). Only the system labels that guide documents are listed
/// (DRAFTS too: the API reference spells it so). The picker never offers
/// "Create" for them; for "Inbox" it offers Move to inbox instead.
enum ReservedLabelNames {
    static let names: Set<String> = [
        "inbox", "spam", "trash", "unread", "starred", "important", "sent",
        "draft", "drafts", "category_personal", "category_social",
        "category_promotions", "category_updates", "category_forums",
    ]

    static func isReserved(_ name: String) -> Bool {
        names.contains(name.trimmingCharacters(in: .whitespaces)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
    }
}

/// "Find emails from <sender>" in the row menu. The sender comes from a
/// message header, so it is offered only for a strict address and searched
/// quoted: a crafted From must not add search operators or empty the
/// result. Same rule as PR #110's `filterFromAddress` (filter prefill); the
/// two should become one once both are merged.
enum SenderSearch {
    /// The address when it is one plain address: one `@` with text on both
    /// sides, no whitespace, quotes, parentheses, angle brackets, braces,
    /// brackets, commas, semicolons, backslashes or control characters.
    static func strictAddress(_ raw: String) -> String? {
        let forbidden = CharacterSet.whitespacesAndNewlines
            .union(.controlCharacters)
            .union(CharacterSet(charactersIn: "\"'()<>{}[],;:\\"))
            .union(bidiControls)
        guard raw.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else { return nil }
        let parts = raw.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              !parts[1].hasPrefix("."), !parts[1].hasSuffix(".") else { return nil }
        return raw
    }

    /// The search the item commits: the address quoted.
    static func query(_ address: String) -> String { "from:\"\(address)\"" }

    /// The display name in the title: control and bidi characters removed,
    /// whitespace collapsed, capped; the address when nothing is left.
    static func displayName(_ name: String, address: String, maxLength: Int = 40) -> String {
        // Line breaks and tabs read as spaces; other controls and the bidi
        // characters go.
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                scalars.append(" ")
            } else if !CharacterSet.controlCharacters.contains(scalar),
                      !bidiControls.contains(scalar) {
                scalars.append(scalar)
            }
        }
        let cleaned = String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let shown = cleaned.isEmpty ? address : cleaned
        return shown.count > maxLength ? String(shown.prefix(maxLength - 1)) + "…" : shown
    }

    /// Unicode bidirectional controls (embeddings, overrides, isolates,
    /// marks) and the other format characters that reorder or hide text.
    static let bidiControls = CharacterSet(charactersIn: "\u{061C}\u{200B}\u{200C}\u{200D}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2060}\u{2066}\u{2067}\u{2068}\u{2069}\u{FEFF}")
}
