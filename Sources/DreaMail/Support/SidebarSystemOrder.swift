import Foundation

/// The order of the sidebar's system views, reorderable by dragging
/// (including across the "More" row), kept on this Mac.
///
/// Pure and hostless-tested (`SidebarSystemOrderTests`). An order is a list
/// of ids: one per system view plus `moreId`, the "More" row. Rows before
/// `moreId` are always listed; rows after it belong to "More" and are listed
/// only while it is open. A closed "More" lists nothing of what is under it,
/// the open view included.
enum SidebarSystemOrder {
    static let moreId = "more"
    /// The sidebar being shown: one account, or the all-accounts view.
    enum Scope: Hashable {
        case all
        case account(String)
    }

    /// UserDefaults key of a sidebar's order: one per account, and one for
    /// the all-accounts view. Absent means the default order. An account
    /// address always has an `@`, so it never clashes with `all`.
    static func defaultsKey(_ scope: Scope) -> String {
        switch scope {
        case .all: return "sidebar.system.order.all"
        case .account(let id): return "sidebar.system.order.\(id)"
        }
    }

    private static let views: [(id: String, view: MailboxView)] = [
        ("inbox", .inbox), ("starred", .starred), ("snoozed", .snoozed),
        ("important", .important), ("sent", .sent), ("drafts", .drafts),
        ("allMail", .allMail), ("trash", .trash), ("outbox", .outbox),
        ("scheduled", .scheduled), ("reminders", .reminders),
        ("promotions", .promotions), ("social", .social), ("spam", .spam),
    ]

    static func view(for id: String) -> MailboxView? {
        views.first { $0.id == id }?.view
    }

    /// Gmail's order, then "More" with DreaMail's own views. Reminders sits
    /// above "More" once something has a reminder, under it otherwise (as
    /// before ordering existed).
    static func defaultOrder(hasReminders: Bool) -> [String] {
        var order = ["inbox", "starred", "snoozed", "important", "sent", "drafts",
                     "allMail", "trash", "outbox"]
        if hasReminders { order.append("reminders") }
        order.append(moreId)
        order += ["scheduled"]
        if !hasReminders { order.append("reminders") }
        order += ["promotions", "social", "spam"]
        return order
    }

    /// The full order for a stored value: unknown and repeated ids are
    /// dropped; an id the stored value lacks (a view a later version added)
    /// goes after its default predecessor. `nil`: the default.
    static func resolve(_ stored: [String]?, hasReminders: Bool) -> [String] {
        let fallback = defaultOrder(hasReminders: hasReminders)
        guard let stored else { return fallback }
        let known = Set(fallback)
        var seen = Set<String>()
        var order = stored.filter { known.contains($0) && seen.insert($0).inserted }
        for (i, id) in fallback.enumerated() where !seen.contains(id) {
            var at = 0
            for earlier in fallback[..<i].reversed() {
                if let index = order.firstIndex(of: earlier) { at = index + 1; break }
            }
            order.insert(id, at: at)
        }
        return order
    }

    /// What the sidebar lists. `above` and `under` hold the ids of the rows
    /// that exist now. "More" is always listed, even with nothing under it,
    /// so a row can be dropped back below it.
    struct Layout: Equatable {
        var above: [String]
        var under: [String]

        /// The ids in sidebar order: what is under "More" only when open.
        func rows(moreOpen: Bool) -> [String] {
            above + [SidebarSystemOrder.moreId] + (moreOpen ? under : [])
        }
    }

    /// `exists` tells whether a row exists now (Outbox and Scheduled only
    /// when they hold something); a row that does not keeps its slot.
    /// `aboveMore`: rows that are listed above "More" whatever their slot
    /// (Reminders once something has a reminder, DEC-063), at the end of
    /// what is above it.
    static func layout(_ order: [String], exists: (String) -> Bool,
                       aboveMore: Set<String> = []) -> Layout {
        let split = order.firstIndex(of: moreId) ?? order.endIndex
        var above = order[..<split].filter(exists)
        var under = order[split...].filter { $0 != moreId && exists($0) }
        let lifted = under.filter(aboveMore.contains)
        under.removeAll(where: aboveMore.contains)
        above += lifted
        return Layout(above: above, under: under)
    }

    /// The system rows a sidebar lists now, for a stored order: one call for
    /// both presentations (the full sidebar and the icon strip), so they
    /// always agree. Reminders is lifted above "More" while one exists
    /// (DEC-063).
    static func listed(stored: [String]?, hasReminders: Bool, moreOpen: Bool,
                       exists: (String) -> Bool) -> [String] {
        layout(resolve(stored, hasReminders: hasReminders), exists: exists,
               aboveMore: hasReminders ? ["reminders"] : [])
            .rows(moreOpen: moreOpen)
    }

    /// Tooltip and VoiceOver text of an icon in the strip, which shows no
    /// numbers: the view's name, then its count. `total`: the count is not
    /// of unread mail (Drafts, Scheduled, Outbox, Reminders).
    static func stripHelp(title: String, count: Int?, total: Bool) -> String {
        guard let count, count > 0 else { return title }
        return total ? "\(title), \(count)" : "\(title), \(count) unread"
    }

    /// The order after the listed rows `rows` (as `List.onMove` reports:
    /// offsets in `rows`, destination before the row now at `to`) are moved.
    /// Rows that are not listed keep their slot, and stay on their side of
    /// "More": a conditional row never changes between above and under it.
    static func move(_ order: [String], rows: [String],
                     from: IndexSet, to: Int) -> [String] {
        let moving = from.filter { rows.indices.contains($0) }
        guard !moving.isEmpty else { return order }
        let moved = AccountOrder.moved(rows, from: IndexSet(moving),
                                       to: max(0, min(to, rows.count)))
        // A drop on the same place changes nothing.
        guard moved != rows else { return order }

        let listed = Set(rows)
        var result = order
        var next = moved.makeIterator()
        for (i, id) in order.enumerated() where listed.contains(id) {
            if let id = next.next() { result[i] = id }
        }
        guard let oldMore = order.firstIndex(of: moreId) else { return result }
        for id in order where !listed.contains(id) && id != moreId {
            let wasAbove = order.firstIndex(of: id)! < oldMore
            let now = result.firstIndex(of: id)!, more = result.firstIndex(of: moreId)!
            guard (now < more) != wasAbove else { continue }
            result.remove(at: now)
            let at = result.firstIndex(of: moreId)!
            result.insert(id, at: wasAbove ? at : at + 1)
        }
        return result
    }

    static func stored(_ scope: Scope, _ defaults: UserDefaults = .standard) -> [String]? {
        defaults.stringArray(forKey: defaultsKey(scope))
    }

    /// `nil` restores the default (the key is removed).
    static func store(_ order: [String]?, _ scope: Scope, _ defaults: UserDefaults = .standard) {
        if let order {
            defaults.set(order, forKey: defaultsKey(scope))
        } else {
            defaults.removeObject(forKey: defaultsKey(scope))
        }
    }
}
