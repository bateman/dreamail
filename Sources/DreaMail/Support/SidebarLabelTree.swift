import Foundation

/// The sidebar's label tree, built the way Gmail builds it: a `/` in a
/// label's name nests it under the label named by the part before it.
///
/// Pure and hostless-tested (`SidebarLabelTreeTests`). `MailStore` builds the
/// trees once per label change (`labelTrees`), never per body pass; the
/// visibility split that depends on unread counts is a linear walk.
struct SidebarLabelNode: Identifiable, Hashable, Sendable {
    /// `LabelRow.id` (`<account>:<labelId>`).
    let id: String
    let accountId: String
    let gmailLabelId: String
    /// The full Gmail name, e.g. `mail/hotmail`.
    let fullName: String
    /// What the row shows: the name after the parent's, e.g. `hotmail`. A
    /// label whose parent does not exist keeps the rest of its path (`b/c`
    /// under `a` when `a/b` is missing; `x/y` at the top when `x` is).
    let displayName: String
    let colors: LabelColors
    let visibility: Visibility
    var children: [SidebarLabelNode]

    /// Gmail's `labelListVisibility`.
    enum Visibility: String, Sendable {
        case show = "labelShow"
        case showIfUnread = "labelShowIfUnread"
        case hide = "labelHide"

        /// Anything unknown (or no value: a label synced before v65, or one
        /// Gmail returned without the field) reads as Gmail's default.
        init(raw: String?) {
            self = raw.flatMap(Visibility.init(rawValue:)) ?? .show
        }

        /// Whether the label is listed above the labels' "More" row.
        func isListed(unread: Int) -> Bool {
            switch self {
            case .show: return true
            case .showIfUnread: return unread > 0
            case .hide: return false
            }
        }
    }
}

enum SidebarLabelTree {
    /// One account's labels as a tree. `rows` are that account's user labels
    /// (system labels and categories never reach the sidebar: `MailStore`
    /// loads `type = 'user'` rows only).
    ///
    /// A label nests under the longest existing label whose name is a
    /// `/`-prefix of its own. Siblings keep the organizer's order
    /// (`sortOrder`, a Mac-only customization), then Gmail's: names
    /// compared case-insensitively, so `Notes` sits between `juve` and
    /// `prenotazioni`.
    static func build(_ rows: [LabelRow]) -> [SidebarLabelNode] {
        // Exact names; on a duplicate name the first row is the parent.
        var byName: [String: LabelRow] = [:]
        for row in rows where byName[row.name] == nil { byName[row.name] = row }
        var childrenOf: [String: [LabelRow]] = [:]   // parent id → children
        var roots: [LabelRow] = []
        var parentName: [String: String] = [:]       // child id → parent name
        for row in rows {
            if let parent = parent(of: row.name, among: byName), parent.id != row.id {
                childrenOf[parent.id, default: []].append(row)
                parentName[row.id] = parent.name
            } else {
                roots.append(row)
            }
        }
        // A parent's name is a proper prefix of its child's, so names grow
        // strictly along a path and the recursion cannot cycle.
        func node(_ row: LabelRow) -> SidebarLabelNode {
            var display = row.name
            if let p = parentName[row.id] {
                let rest = String(row.name.dropFirst(p.count + 1))
                // `a/` under `a`: nothing after the slash, keep the full name.
                if !rest.isEmpty { display = rest }
            }
            return SidebarLabelNode(
                id: row.id, accountId: row.accountId, gmailLabelId: row.gmailLabelId,
                fullName: row.name, displayName: display, colors: row.displayColors,
                visibility: .init(raw: row.listVisibility),
                children: sorted(childrenOf[row.id] ?? []).map(node))
        }
        return sorted(roots).map(node)
    }

    /// The longest existing label whose name is a proper `/`-prefix of
    /// `name`: for `a/b/c`, `a/b` if it exists, else `a`.
    static func parent(of name: String, among byName: [String: LabelRow]) -> LabelRow? {
        var prefix = Substring(name)
        while let slash = prefix.lastIndex(of: "/") {
            prefix = prefix[..<slash]
            // `a//b` or a leading `/`: an empty part is not a label name.
            if !prefix.isEmpty, let row = byName[String(prefix)] { return row }
        }
        return nil
    }

    static func sorted(_ rows: [LabelRow]) -> [LabelRow] {
        rows.sorted { a, b in
            if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
            switch a.name.compare(b.name, options: [.caseInsensitive]) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.id < b.id
            }
        }
    }

    /// Gmail's two lists: labels shown in the list, and those behind the
    /// labels' trailing "More" row (hidden, or shown only when unread and
    /// read now). A listed label under an unlisted parent stays under it, so
    /// the parent appears in the list as its container; an unlisted label
    /// under a listed parent appears in "More" under its parent likewise.
    static func split(_ roots: [SidebarLabelNode],
                      unread: (SidebarLabelNode) -> Int)
        -> (listed: [SidebarLabelNode], more: [SidebarLabelNode]) {
        var listed: [SidebarLabelNode] = []
        var more: [SidebarLabelNode] = []
        for root in roots {
            let parts = split(root, unread: unread)
            if let l = parts.listed { listed.append(l) }
            if let m = parts.more { more.append(m) }
        }
        return (listed, more)
    }

    private static func split(_ node: SidebarLabelNode,
                              unread: (SidebarLabelNode) -> Int)
        -> (listed: SidebarLabelNode?, more: SidebarLabelNode?) {
        var listedKids: [SidebarLabelNode] = []
        var moreKids: [SidebarLabelNode] = []
        for child in node.children {
            let parts = split(child, unread: unread)
            if let l = parts.listed { listedKids.append(l) }
            if let m = parts.more { moreKids.append(m) }
        }
        let own = node.visibility.isListed(unread: unread(node))
        var listed: SidebarLabelNode?
        if own || !listedKids.isEmpty {
            var copy = node
            copy.children = listedKids
            listed = copy
        }
        var more: SidebarLabelNode?
        if !own || !moreKids.isEmpty {
            var copy = node
            copy.children = moreKids
            more = copy
        }
        return (listed, more)
    }
}

/// Which disclosure rows of the sidebar are open, remembered on this Mac.
///
/// Keys carry account addresses and Gmail label ids only, never label names.
/// Everything keyed by an account goes with it (`AccountLifecycle
/// .accountDefaultsKeys`, "deleted means gone", DEC-019).
enum SidebarDisclosure {
    /// The "More" row under the system views (not per account).
    static let moreKey = "sidebar.more.expanded"

    /// Gmail label ids of the parent labels open in an account's tree.
    /// Closed by default, as in Gmail.
    static func expandedLabelsKey(accountId: String) -> String {
        "sidebar.labels.expanded.\(accountId)"
    }

    /// An account's labels' trailing "More" row.
    static func labelsMoreKey(accountId: String) -> String {
        "sidebar.labels.more.\(accountId)"
    }

    /// An account's label section in the all-accounts sidebar; present (and
    /// true) only while it is collapsed. Open by default.
    static func accountCollapsedKey(accountId: String) -> String {
        "sidebar.labels.collapsed.\(accountId)"
    }

    static func keys(accountId: String) -> [String] {
        [expandedLabelsKey(accountId: accountId),
         labelsMoreKey(accountId: accountId),
         accountCollapsedKey(accountId: accountId),
         // The account's own order of the system views.
         SidebarSystemOrder.defaultsKey(.account(accountId))]
    }

    static func isMoreExpanded(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: moreKey)
    }

    static func setMoreExpanded(_ open: Bool, _ defaults: UserDefaults = .standard) {
        // Closed is the default: store only the open state.
        if open { defaults.set(true, forKey: moreKey) } else { defaults.removeObject(forKey: moreKey) }
    }

    static func expandedLabels(accountId: String,
                               _ defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: expandedLabelsKey(accountId: accountId)) ?? [])
    }

    static func setLabel(_ labelId: String, accountId: String, expanded: Bool,
                         _ defaults: UserDefaults = .standard) {
        var ids = expandedLabels(accountId: accountId, defaults)
        if expanded { ids.insert(labelId) } else { ids.remove(labelId) }
        let key = expandedLabelsKey(accountId: accountId)
        if ids.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(ids.sorted(), forKey: key) }
    }

    /// A removed label leaves nothing behind (DEC-019).
    static func forget(_ labelId: String, accountId: String,
                       _ defaults: UserDefaults = .standard) {
        setLabel(labelId, accountId: accountId, expanded: false, defaults)
    }

    static func flag(_ key: String, _ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    static func setFlag(_ key: String, _ on: Bool, _ defaults: UserDefaults = .standard) {
        if on { defaults.set(true, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

/// The selected view once the account in scope changes.
enum SidebarScope {
    /// A label view of another account than `account` falls back to the
    /// Inbox (its list would be empty, still titled with the old label).
    /// Every other view, and any view once all accounts are in scope, stays.
    static func view(_ view: MailboxView, afterSwitchingTo account: String?) -> MailboxView {
        guard let account, case .label(let owner, _, _) = view, owner != account else { return view }
        return .inbox
    }
}

/// The name Gmail's "New label" dialog creates.
enum NewLabelName {
    /// `parent/name` when nested, else `name`; trimmed of spaces and of
    /// slashes at either end (a leading or trailing `/` would make an empty
    /// level). nil when nothing is left.
    static func full(name: String, parent: String?) -> String? {
        let trimmed = name.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "/")))
        guard !trimmed.isEmpty else { return nil }
        guard let parent, !parent.isEmpty else { return trimmed }
        return "\(parent)/\(trimmed)"
    }

    enum Check: Equatable {
        case ok(String)
        case empty
        case duplicate
        /// The parent is not one of this account's labels (for example
        /// still the one picked on another account): never create it,
        /// it would carry one account's label name into another.
        case unknownParent
    }

    /// What the dialog may create on the account whose labels are `rows`.
    static func check(name: String, nest: Bool, parent: String, rows: [LabelRow]) -> Check {
        if nest, !rows.contains(where: { $0.name == parent }) { return .unknownParent }
        guard let full = full(name: name, parent: nest ? parent : nil) else { return .empty }
        return exists(full, in: rows) ? .duplicate : .ok(full)
    }

    /// Whether an account already has a label of that name. Gmail refuses a
    /// duplicate, ignoring case.
    static func exists(_ fullName: String, in rows: [LabelRow]) -> Bool {
        rows.contains { $0.name.compare(fullName, options: [.caseInsensitive]) == .orderedSame }
    }
}
