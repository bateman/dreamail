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
    /// UserDefaults key: one order for the app (every account and the
    /// all-accounts view). Absent means the default order.
    static let defaultsKey = "sidebar.system.order"

    private static let views: [(id: String, view: MailboxView)] = [
        ("inbox", .inbox), ("starred", .starred), ("snoozed", .snoozed),
        ("important", .important), ("sent", .sent), ("drafts", .drafts),
        ("allMail", .allMail), ("trash", .trash), ("outbox", .outbox),
        ("scheduled", .scheduled), ("reminders", .reminders),
        ("promotions", .promotions), ("social", .social), ("spam", .spam),
    ]

    static func id(for view: MailboxView) -> String? {
        views.first { $0.view == view }?.id
    }

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
    /// that exist now; "More" is listed only while something is under it.
    struct Layout: Equatable {
        var above: [String]
        var under: [String]
        var showsMore: Bool { !under.isEmpty }

        /// The ids in sidebar order: what is under "More" only when open.
        func rows(moreOpen: Bool) -> [String] {
            above + (showsMore ? [SidebarSystemOrder.moreId] : []) + (moreOpen ? under : [])
        }
    }

    /// `exists` tells whether a row exists now (Outbox and Scheduled only
    /// when they hold something); a row that does not keeps its slot.
    static func layout(_ order: [String], exists: (String) -> Bool) -> Layout {
        let split = order.firstIndex(of: moreId) ?? order.endIndex
        return Layout(above: order[..<split].filter(exists),
                      under: order[split...].filter { $0 != moreId && exists($0) })
    }

    /// The order after the listed rows `rows` (as `List.onMove` reports:
    /// offsets in `rows`, destination before the row now at `to`) are moved.
    /// Rows that are not listed keep their slot, and stay on their side of
    /// "More": a conditional row never changes between above and under it.
    static func move(_ order: [String], rows: [String],
                     from: IndexSet, to: Int) -> [String] {
        let moving = from.filter { rows.indices.contains($0) }
        guard !moving.isEmpty else { return order }
        var moved = rows
        let items = moving.sorted().map { rows[$0] }
        for index in moving.sorted(by: >) { moved.remove(at: index) }
        let insertAt = to - moving.filter { $0 < to }.count
        moved.insert(contentsOf: items, at: max(0, min(insertAt, moved.count)))

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

    static func stored(_ defaults: UserDefaults = .standard) -> [String]? {
        defaults.stringArray(forKey: defaultsKey)
    }

    /// `nil` restores the default (the key is removed).
    static func store(_ order: [String]?, _ defaults: UserDefaults = .standard) {
        if let order { defaults.set(order, forKey: defaultsKey) } else { defaults.removeObject(forKey: defaultsKey) }
    }
}
