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
        func node(_ row: LabelRow, depth: Int) -> SidebarLabelNode {
            let display: String
            if let p = parentName[row.id] {
                display = String(row.name.dropFirst(p.count + 1))
            } else {
                display = row.name
            }
            // Names cannot repeat along one path, so depth is bounded by the
            // number of rows; the guard only defends against a cycle bug.
            let kids = depth > rows.count ? [] : (childrenOf[row.id] ?? [])
            return SidebarLabelNode(
                id: row.id, accountId: row.accountId, gmailLabelId: row.gmailLabelId,
                fullName: row.name, displayName: display, colors: row.displayColors,
                visibility: .init(raw: row.listVisibility),
                children: sorted(kids).map { node($0, depth: depth + 1) })
        }
        return sorted(roots).map { node($0, depth: 0) }
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
    /// "Categories" inside it (Promotions, Social). Not per account.
    static let categoriesKey = "sidebar.categories.expanded"

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
         accountCollapsedKey(accountId: accountId)]
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

    static func flag(_ key: String, _ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    static func setFlag(_ key: String, _ on: Bool, _ defaults: UserDefaults = .standard) {
        if on { defaults.set(true, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

/// The name Gmail's "New label" dialog creates.
enum NewLabelName {
    /// `parent/name` when nested, else `name`; trimmed. nil when the name is
    /// empty once trimmed.
    static func full(name: String, parent: String?) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let parent, !parent.isEmpty else { return trimmed }
        return "\(parent)/\(trimmed)"
    }

    /// Whether an account already has a label of that name. Gmail refuses a
    /// duplicate, ignoring case.
    static func exists(_ fullName: String, in rows: [LabelRow]) -> Bool {
        rows.contains { $0.name.compare(fullName, options: [.caseInsensitive]) == .orderedSame }
    }
}
