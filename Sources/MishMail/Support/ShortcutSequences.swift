import Foundation

/// Gmail's two-key sequences: `g` then a letter jumps to a mailbox, `*` then
/// a letter changes the multi-select. Fixed (not rebindable); both prefixes
/// are reserved in `KeyBindings`. `MailStore.handleKey` runs them and the
/// `?` help lists them from these same tables, so the two cannot drift.
enum ShortcutSequences {
    enum Prefix: String {
        case goTo = "g"
        case select = "*"
    }

    /// The second key must follow the prefix within this window.
    static let timeout: TimeInterval = 1.5

    enum Selection: Equatable {
        /// Check every conversation loaded in the list (Gmail `* a`).
        case selectAll
        /// Clear the multi-select (Gmail `* n`).
        case deselectAll
    }

    /// `g` + key. All but `p` are Gmail's; Gmail's `g p` (previous page) has
    /// no meaning in a list without pages, so it keeps MishMail's Promotions.
    static let goTo: [(key: String, view: MailboxView, title: String)] = [
        ("i", .inbox, "Inbox (also exits a full-window conversation)"),
        ("s", .starred, "Starred"),
        ("b", .snoozed, "Snoozed"),
        ("t", .sent, "Sent"),
        ("d", .drafts, "Drafts"),
        ("a", .allMail, "All mail"),
        ("p", .promotions, "Promotions"),
    ]

    /// `*` + key. Gmail also has `* r`, `* u`, `* s`, `* t` (select read,
    /// unread, starred, unstarred); MishMail has no such action yet.
    static let select: [(key: String, selection: Selection, title: String)] = [
        ("a", .selectAll, "Select all conversations"),
        ("n", .deselectAll, "Deselect all conversations"),
    ]

    static func goToTarget(_ key: String) -> MailboxView? {
        goTo.first { $0.key == key }?.view
    }

    static func selection(_ key: String) -> Selection? {
        select.first { $0.key == key }?.selection
    }
}
