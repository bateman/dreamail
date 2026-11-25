import Foundation

/// The mailboxes a fixed command can open (Cmd-K "Go to …", the `g` chords).
/// Kept apart from `MailboxView` so the command list stays a pure value the
/// unit tests can build; the app maps a case to its `MailboxView`.
enum BuiltinMailbox: String, CaseIterable {
    case inbox, promotions, social, starred, snoozed, reminders
    case important, drafts, sent, allMail, spam, trash
    /// Every labelled conversation in one list, grouped by label. No longer
    /// a sidebar row (the sidebar lists the labels themselves).
    case labels

    var title: String {
        switch self {
        case .inbox: return "Inbox"
        case .promotions: return "Promotions"
        case .social: return "Social"
        case .starred: return "Starred"
        case .snoozed: return "Snoozed"
        case .reminders: return "Reminders"
        case .important: return "Important"
        case .spam: return "Spam"
        case .labels: return "Labels"
        case .drafts: return "Drafts"
        case .sent: return "Sent"
        case .allMail: return "All Mail"
        case .trash: return "Trash"
        }
    }
}

/// Pure builder for the Cmd-K command list. The view turns each `Action`
/// into one store call; everything that decides WHICH rows exist and what
/// they are called lives here.
enum PaletteCommands {
    /// The flags of one thread that change a row's title or presence.
    struct ThreadState: Equatable {
        var isStarred = false
        var isUnread = false
        var isMuted = false
        var isImportant = false
    }

    struct SavedViewRef: Equatable {
        var id: Int64
        var name: String
    }

    struct Context {
        /// The focused thread (`MailStore.selectedThread`), if any.
        var focused: ThreadState?
        /// The checked threads that are still in the list.
        var checked: [ThreadState] = []
        /// `checkedThreadIds.count` — what the keys test to pick the bulk
        /// path, and what the multi-select bar shows.
        var checkedCount = 0
        var savedViews: [SavedViewRef] = []
        /// Ask Mish and AI sorting are listed only in a build with the AI
        /// features on.
        var aiFeatures = AIFeatures.isEnabled
    }

    enum Action: Equatable {
        case compose
        case syncAll
        case toggleAskMish
        case sortInboxWithAI
        case addView
        /// Same entry point as the single key, so the palette inherits the
        /// key's rules (checked threads win over the focused one).
        case perform(ShortcutCommand)
        case snoozeTomorrow
        case copyLink
        case goTo(BuiltinMailbox)
        case goToSaved(id: Int64, name: String)
        case search(String)
    }

    struct Entry: Identifiable, Equatable {
        let id: String
        let title: String
        let icon: String
        /// Rebindable key shown at the row's trailing edge.
        var shortcut: ShortcutCommand? = nil
        let action: Action
    }

    static func entries(_ ctx: Context) -> [Entry] {
        var list: [Entry] = [
            Entry(id: "compose", title: "Compose New Message", icon: "square.and.pencil", action: .compose),
            Entry(id: "sync", title: "Sync All Accounts", icon: "arrow.clockwise", action: .syncAll),
        ]
        if ctx.aiFeatures {
            list += [
                Entry(id: "askmish", title: "Ask Mish", icon: "bubble.left.and.text.bubble.right", action: .toggleAskMish),
                Entry(id: "aisort", title: "Sort Inbox with AI", icon: "sparkles", action: .sortInboxWithAI),
            ]
        }
        list.append(Entry(id: "newview", title: "Add View…", icon: "plus", action: .addView))
        list += threadActions(ctx)
        for mailbox in BuiltinMailbox.allCases {
            list.append(Entry(id: "view.\(mailbox.title)", title: "Go to \(mailbox.title)",
                              icon: "tray", action: .goTo(mailbox)))
        }
        for view in ctx.savedViews {
            list.append(Entry(id: "saved.\(view.id)", title: "Go to \(view.name)",
                              icon: "line.3.horizontal.decrease.circle",
                              action: .goToSaved(id: view.id, name: view.name)))
        }
        return list
    }

    /// Context actions, so Cmd-K can drive the keyboard-first flow end to
    /// end. With checked threads the triage rows act on the whole selection,
    /// exactly as the keys do, and say so in the title.
    private static func threadActions(_ ctx: Context) -> [Entry] {
        let bulk = ctx.checkedCount > 0
        guard bulk || ctx.focused != nil else { return [] }
        let noun = ctx.checkedCount == 1
            ? "1 Selected Conversation"
            : "\(ctx.checkedCount) Selected Conversations"
        // Bulk rules mirror the store: any unstarred → star all; any unread
        // → mark all read, else mark all unread (`toggleReadChecked`).
        let starring = bulk
            ? ctx.checked.contains { !$0.isStarred }
            : !(ctx.focused?.isStarred ?? false)
        let markingRead = bulk
            ? ctx.checked.contains { $0.isUnread }
            : (ctx.focused?.isUnread ?? false)

        var list: [Entry] = [
            Entry(id: "act.archive", title: bulk ? "Archive \(noun)" : "Archive Conversation",
                  icon: "archivebox", shortcut: .archive, action: .perform(.archive)),
            Entry(id: "act.trash", title: bulk ? "Trash \(noun)" : "Trash Conversation",
                  icon: "trash", shortcut: .trash, action: .perform(.trash)),
            Entry(id: "act.star",
                  title: bulk ? "\(starring ? "Star" : "Unstar") \(noun)"
                              : (starring ? "Star Conversation" : "Unstar Conversation"),
                  icon: starring ? "star" : "star.slash",
                  shortcut: .toggleStar, action: .perform(.toggleStar)),
            Entry(id: "act.read",
                  title: bulk ? "Mark \(noun) \(markingRead ? "Read" : "Unread")"
                              : (markingRead ? "Mark Read" : "Mark Unread"),
                  icon: markingRead ? "envelope.open" : "envelope",
                  shortcut: .toggleRead, action: .perform(.toggleRead)),
            Entry(id: "act.snooze",
                  title: bulk ? "Snooze \(noun) Until Tomorrow" : "Snooze Until Tomorrow",
                  icon: "clock", action: .snoozeTomorrow),
            Entry(id: "act.snoozeCustom",
                  title: bulk ? "Snooze \(noun) Until…" : "Snooze Until…",
                  icon: "calendar.badge.clock", shortcut: .snooze, action: .perform(.snooze)),
        ]
        // Reply, forward and the link need one thread: the keys use the
        // focused one even while others are checked.
        if ctx.focused != nil {
            list += [
                Entry(id: "act.reply", title: "Reply", icon: "arrowshape.turn.up.left",
                      shortcut: .reply, action: .perform(.reply)),
                Entry(id: "act.replyAll", title: "Reply All", icon: "arrowshape.turn.up.left.2",
                      shortcut: .replyAll, action: .perform(.replyAll)),
                Entry(id: "act.forward", title: "Forward", icon: "arrowshape.turn.up.right",
                      shortcut: .forward, action: .perform(.forward)),
            ]
        }
        list.append(Entry(id: "act.label",
                          title: bulk ? "Label \(noun)…" : "Label Conversation…",
                          icon: "tag", shortcut: .label, action: .perform(.label)))
        // Same rules as the store (`ConversationAction.muteToggle`): unmute
        // only when every target is muted.
        let unmuting = bulk
            ? !ctx.checked.isEmpty && ctx.checked.allSatisfy(\.isMuted)
            : (ctx.focused?.isMuted ?? false)
        list += [
            Entry(id: "act.move", title: bulk ? "Move \(noun) To…" : "Move Conversation To…",
                  icon: "folder", shortcut: .moveTo, action: .perform(.moveTo)),
            Entry(id: "act.mute",
                  title: bulk ? "\(unmuting ? "Unmute" : "Mute") \(noun)"
                              : (unmuting ? "Unmute Conversation" : "Mute Conversation"),
                  icon: unmuting ? "bell" : "bell.slash",
                  shortcut: .mute, action: .perform(.mute)),
            Entry(id: "act.important",
                  title: bulk ? "Mark \(noun) as Important" : "Mark as Important",
                  icon: "flag", shortcut: .markImportant, action: .perform(.markImportant)),
            Entry(id: "act.notImportant",
                  title: bulk ? "Mark \(noun) as Not Important" : "Mark as Not Important",
                  icon: "flag.slash", shortcut: .markNotImportant,
                  action: .perform(.markNotImportant)),
        ]
        if ctx.focused != nil {
            list.append(Entry(id: "act.copyLink", title: "Copy Gmail Link to Conversation",
                              icon: "link", action: .copyLink))
        }
        return list
    }
}
