import Foundation

/// Gmail's two-key sequences: `g` then a letter jumps to a mailbox, `*` then
/// a letter changes the multi-select. Fixed (not rebindable); both prefixes
/// are reserved in `KeyBindings`. `ShortcutKeyRouter` runs them and the `?`
/// help lists them from these same tables, so the two cannot drift.
enum ShortcutSequences {
    enum Prefix: String, CaseIterable {
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
        case read, unread, starred, unstarred

        /// Whether a conversation in this state ends up checked. Every
        /// selection but `deselectAll` replaces the current checks.
        func includes(isUnread: Bool, isStarred: Bool) -> Bool {
            switch self {
            case .selectAll: return true
            case .deselectAll: return false
            case .read: return !isUnread
            case .unread: return isUnread
            case .starred: return isStarred
            case .unstarred: return !isStarred
            }
        }
    }

    /// `g` + key. All but `p` are Gmail's; Gmail's `g p` (previous page) has
    /// no meaning in a list without pages, so it keeps DreaMail's Promotions.
    static let goTo: [(key: String, view: MailboxView, title: String)] = [
        ("i", .inbox, "Inbox (also exits a full-window conversation)"),
        ("s", .starred, "Starred"),
        ("b", .snoozed, "Snoozed"),
        ("t", .sent, "Sent"),
        ("d", .drafts, "Drafts"),
        ("a", .allMail, "All mail"),
        ("l", .labels, "Labels"),
        ("p", .promotions, "Promotions"),
    ]

    /// `*` + key, all Gmail's. Acts on the conversations loaded in the list.
    static let select: [(key: String, selection: Selection, title: String)] = [
        ("a", .selectAll, "Select all conversations"),
        ("n", .deselectAll, "Deselect all conversations"),
        ("r", .read, "Select read conversations"),
        ("u", .unread, "Select unread conversations"),
        ("s", .starred, "Select starred conversations"),
        ("t", .unstarred, "Select unstarred conversations"),
    ]

    static func goToTarget(_ key: String) -> MailboxView? {
        goTo.first { $0.key == key }?.view
    }

    static func selection(_ key: String) -> Selection? {
        select.first { $0.key == key }?.selection
    }

    /// The ids `selection` checks, in list order.
    static func checkedIds(order: [String], selection: Selection,
                           state: (String) -> (isUnread: Bool, isStarred: Bool)?)
        -> [String] {
        order.filter { id in
            guard let s = state(id) else { return false }
            return selection.includes(isUnread: s.isUnread, isStarred: s.isStarred)
        }
    }
}

/// What one mailbox key press does: the `g` / `*` sequences, `?`, then the
/// rebindable single keys. Pure, so the whole key path below the window's
/// key monitor is testable; `MailStore.handleKey` only performs the route.
struct ShortcutKeyRouter {
    enum Route: Equatable {
        /// `g` or `*`: wait for the second key.
        case armed(ShortcutSequences.Prefix)
        case goTo(MailboxView)
        case select(ShortcutSequences.Selection)
        /// The key after a prefix matched no sequence. It is eaten, never
        /// run as its own shortcut (`* r` must not reply, `g l` must not
        /// open the label picker).
        case swallowed
        case help
        case command(ShortcutCommand)
        /// Not a mailbox key.
        case unhandled
    }

    private var pending: (prefix: ShortcutSequences.Prefix, at: Date)?

    /// A prefix is armed and its window has not run out.
    func hasPendingPrefix(now: Date = Date()) -> Bool {
        guard let pending else { return false }
        return now.timeIntervalSince(pending.at) < ShortcutSequences.timeout
    }

    /// - Parameters:
    ///   - chars: `charactersIgnoringModifiers`. Letters arrive uppercase
    ///     with Shift or Caps Lock (`*` needs Shift, so `* a` often comes in
    ///     as "*", "A"); they are matched case-insensitively.
    ///   - command: the registry lookup (`KeyBindings.command(for:)`).
    mutating func route(_ chars: String, now: Date = Date(),
                        command: (String) -> ShortcutCommand?) -> Route {
        let key = Self.normalized(chars)
        if hasPendingPrefix(now: now), let armed = pending?.prefix {
            pending = nil
            switch armed {
            case .goTo:
                return ShortcutSequences.goToTarget(key).map(Route.goTo) ?? .swallowed
            case .select:
                return ShortcutSequences.selection(key).map(Route.select) ?? .swallowed
            }
        }
        pending = nil
        if let prefix = ShortcutSequences.Prefix(rawValue: key) {
            pending = (prefix, now)
            return .armed(prefix)
        }
        if key == "?" { return .help }
        return command(chars).map(Route.command) ?? .unhandled
    }

    /// Single letters lowercased; symbols keep their Shift form.
    static func normalized(_ chars: String) -> String {
        guard chars.count == 1, chars.rangeOfCharacter(from: .letters) != nil else {
            return chars
        }
        return chars.lowercased()
    }
}
