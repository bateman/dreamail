import Foundation

/// One row of the organizer sheet: a label, how deep it sits in its family,
/// and the name the row shows.
struct LabelOrganizerEntry: Identifiable, Hashable, Sendable {
    let row: LabelRow
    /// 0 for a top-level label; 1 for a sublabel; and so on.
    let depth: Int
    /// The leaf name (`amazon` for `ecommerce/amazon`), as the sidebar shows it.
    let displayName: String
    var id: String { row.id }
}

/// The organizer's order, pure. The sheet shows each label's family together
/// (parent, then its sublabels under it) and moves a family as one block.
///
/// Families are the sidebar's (`SidebarLabelTree`: a label nests under the
/// longest existing label whose name is a `/`-prefix of its own, which makes
/// its descendants exactly `LabelFamily.descendants`). The stored order is
/// `sortOrder`; siblings are read in that order, so the sidebar and the sheet
/// show the same thing.
enum LabelOrganizerOrder {
    /// One account's labels as the sheet shows them: every family contiguous
    /// at its parent's position, children in their stored relative order.
    static func entries(_ rows: [LabelRow]) -> [LabelOrganizerEntry] {
        entries(tree: SidebarLabelTree.build(rows), rows: rows)
    }

    /// As `entries(_:)`, from a tree already built for `rows` (`MailStore.labelTrees`).
    static func entries(tree: [SidebarLabelNode], rows: [LabelRow]) -> [LabelOrganizerEntry] {
        var out: [LabelOrganizerEntry] = []
        let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func walk(_ nodes: [SidebarLabelNode], depth: Int) {
            for node in nodes {
                if let row = byId[node.id] {
                    out.append(.init(row: row, depth: depth, displayName: node.displayName))
                }
                walk(node.children, depth: depth + 1)
            }
        }
        walk(tree, depth: 0)
        return out
    }

    /// The end (exclusive) of the block of `index`: the row and the rows
    /// under it.
    static func blockEnd(of index: Int, in entries: [LabelOrganizerEntry]) -> Int {
        var end = index + 1
        while end < entries.count, entries[end].depth > entries[index].depth { end += 1 }
        return end
    }

    /// Insertion offsets (as `List.onMove` counts them, in the list that
    /// still holds the row) where the row's block may land and change the
    /// order: before one of its siblings, or after the last. Never inside
    /// another family and never under another parent.
    static func allowedDestinations(for index: Int, in entries: [LabelOrganizerEntry]) -> [Int] {
        guard entries.indices.contains(index) else { return [] }
        let depth = entries[index].depth
        // The parent's block, or the whole list for a top-level label.
        var start = 0
        var end = entries.count
        if depth > 0, let parent = (0..<index).last(where: { entries[$0].depth < depth }) {
            start = parent + 1
            end = blockEnd(of: parent, in: entries)
        }
        let own = index..<blockEnd(of: index, in: entries)
        var spots = (start..<end).filter { entries[$0].depth == depth }
        spots.append(end)
        return spots.filter { !(own.contains($0) || $0 == own.upperBound) }
    }

    /// The new order of the whole list after dragging `index` to `destination`
    /// (`List.onMove`'s offset). The block moves together, in its own order.
    /// nil when the move is refused or changes nothing.
    static func moved(_ entries: [LabelOrganizerEntry], from index: Int, to destination: Int)
        -> [LabelRow]? {
        guard allowedDestinations(for: index, in: entries).contains(destination) else { return nil }
        let end = blockEnd(of: index, in: entries)
        let block = Array(entries[index..<end])
        var rest = entries
        rest.removeSubrange(index..<end)
        rest.insert(contentsOf: block, at: destination > index ? destination - block.count : destination)
        return rest.map(\.row)
    }
}
