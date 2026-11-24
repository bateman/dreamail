import Foundation
import Combine

/// A user-rebindable single-key command (Gmail-style, no modifiers).
///
/// Raw values are the keys of stored overrides: never rename a case without
/// migrating its stored override in `KeyBindings.init`.
enum ShortcutCommand: String, CaseIterable, Codable {
    case archive, trash, toggleStar, toggleRead, snooze
    case markSpam
    case reply, replyAll, forward, label, undo, compose
    case next, prev
    /// Toggle multi-select checkbox on the focused conversation (Gmail `x`).
    case toggleCheck
    /// Open the focused conversation (Gmail `o`; Return is a fixed second key).
    case open
    /// Leave the open conversation for the list (Gmail `u`).
    case backToList
}

struct ShortcutSpec: Identifiable {
    let command: ShortcutCommand
    let title: String
    let category: KeyBindings.Category
    /// nil: the command ships without a key (Gmail has none for it); the
    /// user can still bind one in Settings.
    let defaultKey: String?
    var id: ShortcutCommand { command }
}

/// Single source of truth for the Gmail-style single-key shortcuts:
/// defaults, user overrides (persisted to UserDefaults), and both
/// key→command and command→key lookups. The `g` and `*` prefixes, the `?`
/// help key and the `/` search key are reserved and handled before this
/// registry is consulted.
///
/// Defaults follow Gmail on the web with keyboard shortcuts on
/// (support.google.com/mail/answer/6594). `GmailShortcutReferenceTests`
/// pins every default to that table.
///
/// Collision rule: a stored override always keeps its key. When it holds the
/// default key of another command that has no override of its own, that
/// command is left unbound (`key(for:)` is nil, Settings shows it as not
/// set) rather than stealing the key back or being moved to another key.
/// It regains its default as soon as the override moves elsewhere.
@MainActor
final class KeyBindings: ObservableObject {
    enum Category: String, CaseIterable {
        case navigation = "Navigation"
        case actions = "Actions"
    }

    static let reservedKeys: Set<String> = ["g", "*", "?", "/"]

    /// False for keys the main-window key monitor consumes before it asks
    /// this registry: Return, Tab, Delete and Esc (control characters), and
    /// the arrows, Home/End and function keys (AppKit reports those as
    /// private-use scalars U+F700–U+F8FF). A command bound to one of them
    /// would have no working key.
    static func isDeliverable(_ key: String) -> Bool {
        !key.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
                || (0xF700...0xF8FF).contains($0.value)
        }
    }

    /// True when a stored override can still fire its command.
    private static func isBindable(_ key: String) -> Bool {
        key.count == 1 && key != " " && !reservedKeys.contains(key) && isDeliverable(key)
    }

    static let catalog: [ShortcutSpec] = [
        .init(command: .next, title: "Next (older) conversation", category: .navigation, defaultKey: "j"),
        .init(command: .prev, title: "Previous (newer) conversation", category: .navigation, defaultKey: "k"),
        .init(command: .open, title: "Open conversation", category: .navigation, defaultKey: "o"),
        .init(command: .backToList, title: "Back to conversation list", category: .navigation, defaultKey: "u"),
        .init(command: .toggleCheck, title: "Select / deselect conversation", category: .navigation, defaultKey: "x"),
        .init(command: .archive, title: "Archive", category: .actions, defaultKey: "e"),
        .init(command: .trash, title: "Delete (Trash)", category: .actions, defaultKey: "#"),
        .init(command: .toggleStar, title: "Star / Unstar", category: .actions, defaultKey: "s"),
        // Gmail has no single toggle: Shift+I / Shift+U (GmailMarkReadKeys)
        // mark read / unread. The toggle stays bindable, with no default.
        .init(command: .toggleRead, title: "Toggle read / unread", category: .actions, defaultKey: nil),
        .init(command: .snooze, title: "Snooze", category: .actions, defaultKey: "b"),
        // Gmail's Report spam key. When the thread is already in Spam the
        // same binding runs Not spam (toggle) — see MailStore.perform.
        .init(command: .markSpam, title: "Mark as spam / Not spam", category: .actions, defaultKey: "!"),
        .init(command: .reply, title: "Reply", category: .actions, defaultKey: "r"),
        .init(command: .replyAll, title: "Reply all", category: .actions, defaultKey: "a"),
        .init(command: .forward, title: "Forward", category: .actions, defaultKey: "f"),
        .init(command: .label, title: "Label…", category: .actions, defaultKey: "l"),
        .init(command: .undo, title: "Undo", category: .actions, defaultKey: "z"),
        .init(command: .compose, title: "Compose", category: .actions, defaultKey: "c"),
    ]

    static func defaultKey(for command: ShortcutCommand) -> String? {
        catalog.first { $0.command == command }!.defaultKey
    }

    static func title(for command: ShortcutCommand) -> String {
        catalog.first { $0.command == command }!.title
    }

    enum RebindResult: Equatable {
        case ok
        case conflict(ShortcutCommand)
        case rejected(String)
    }

    /// True while the Settings pane is capturing a key press, so the main
    /// window's key monitor stands down and the capture can't fire actions.
    @Published var capturing = false

    @Published private(set) var overrides: [ShortcutCommand: String]

    private let store: UserDefaults
    private static let defaultsKey = "keyBindings"

    init(defaults: UserDefaults = .standard) {
        store = defaults
        // Normalize letter overrides on load so a pre-normalize rebind of
        // "Q" (Shift/Caps Lock capture) still matches command(for: "q").
        var needsNormalizePersist = false
        if let data = defaults.data(forKey: Self.defaultsKey),
           let raw = try? JSONDecoder().decode([String: String].self, from: data) {
            var loaded: [ShortcutCommand: String] = [:]
            for (key, value) in raw {
                guard let cmd = ShortcutCommand(rawValue: key) else { continue }
                let normalized = Self.normalizeKey(value)
                if normalized != value { needsNormalizePersist = true }
                // An override saved before `/`, Return, arrows and function
                // keys were refused: drop it so the command gets its default
                // key back instead of staying unreachable.
                guard Self.isBindable(normalized) else {
                    needsNormalizePersist = true
                    continue
                }
                loaded[cmd] = normalized
            }
            overrides = loaded
        } else {
            overrides = [:]
        }
        // A new catalog default (e.g. backToList → u) never shadows an
        // existing user rebind of that key: see the collision rule above.
        // Nothing to rewrite for it, so only normalization persists.
        if needsNormalizePersist {
            persist()
        }
    }

    /// The key that fires `command`, or nil when it has none: no default and
    /// no override, or its default is held by another command's override.
    func key(for command: ShortcutCommand) -> String? {
        if let override = overrides[command] { return override }
        guard let key = Self.defaultKey(for: command) else { return nil }
        let shadowed = overrides.contains { $0.key != command && $0.value == key }
        return shadowed ? nil : key
    }

    /// `key(for:)` for display: tooltips, the palette, Settings and the `?`
    /// help show "—" for an unbound command.
    func displayKey(for command: ShortcutCommand) -> String {
        key(for: command) ?? Self.unboundLabel
    }

    static let unboundLabel = "—"

    /// The command whose override holds `command`'s default key, if any —
    /// Settings explains an unbound command with it.
    func defaultKeyHolder(for command: ShortcutCommand) -> ShortcutCommand? {
        guard overrides[command] == nil,
              let key = Self.defaultKey(for: command) else { return nil }
        return overrides.first { $0.key != command && $0.value == key }?.key
    }

    /// Secondary built-in keys that fire a command when the key isn't
    /// bound to anything else (a rebind to the key wins over the alias).
    /// `]` is Gmail's "archive and go to the next conversation", which is
    /// what archive's auto-advance already does.
    static let aliases: [String: ShortcutCommand] = ["h": .snooze, "]": .archive]

    func command(for key: String) -> ShortcutCommand? {
        let key = Self.normalizeKey(key)
        return primaryCommand(for: key) ?? Self.aliases[key]
    }

    /// Explicit user overrides always win over catalog defaults so a
    /// previously rebound key (archive → x) is not stolen by a new default
    /// (toggleCheck → x).
    private func primaryCommand(for key: String) -> ShortcutCommand? {
        if let overridden = overrides.first(where: { $0.value == key })?.key {
            return overridden
        }
        return Self.catalog.first {
            overrides[$0.command] == nil && $0.defaultKey == key
        }?.command
    }

    func rebind(_ command: ShortcutCommand, to key: String) -> RebindResult {
        let key = Self.normalizeKey(key)
        guard key.count == 1, key != " " else {
            return .rejected("Press a single character key.")
        }
        guard !Self.reservedKeys.contains(key) else {
            return .rejected("\"\(key)\" is reserved.")
        }
        guard Self.isDeliverable(key) else {
            return .rejected("Return, Tab, Delete, arrow and function keys can't be used.")
        }
        if self.key(for: command) == key { return .ok }
        if let other = primaryCommand(for: key) { return .conflict(other) }
        overrides[command] = key
        persist()
        return .ok
    }

    /// Letters are case-insensitive (Caps Lock / accidental Shift must not
    /// orphan bindings). Symbol keys like `#` and `!` keep their Shift form.
    static func normalizeKey(_ key: String) -> String {
        guard key.count == 1, key.rangeOfCharacter(from: .letters) != nil else {
            return key
        }
        return key.lowercased()
    }

    func resetToDefaults() {
        overrides = [:]
        store.removeObject(forKey: Self.defaultsKey)
    }

    private func persist() {
        let raw = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            store.set(data, forKey: Self.defaultsKey)
        }
    }
}
