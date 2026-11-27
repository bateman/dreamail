import SwiftUI
import AppKit

/// Order, rows and counts of the sidebar's system views for the account in
/// scope: one source for the full sidebar (`Sidebar`) and the icon strip
/// (`SidebarIconStrip`), so both always list the same views, in the same
/// order, with the same "More" rule.
@MainActor
struct SidebarSystemRows {
    let store: MailStore
    let disclosure: SidebarDisclosureModel

    /// Whose order the sidebar shows: the account in scope (the only one, as
    /// for the labels), else the all-accounts view's own.
    var scope: SidebarSystemOrder.Scope {
        if let account = store.activeAccountId { return .account(account) }
        if store.accounts.count == 1, let only = store.accounts.first { return .account(only.id) }
        return .all
    }

    /// The full order of the system views, with the "More" row.
    var order: [String] {
        SidebarSystemOrder.resolve(disclosure.systemOrder(scope), hasReminders: hasReminders)
    }

    /// The rows listed now: nothing under a closed "More", the open view
    /// included (the list on the right keeps showing it).
    var rows: [String] {
        SidebarSystemOrder.listed(stored: disclosure.systemOrder(scope), hasReminders: hasReminders,
                                  moreOpen: disclosure.moreOpen, exists: exists)
    }

    /// Outbox and Scheduled exist only while they hold something (or are
    /// open); Reminders is always listed, wherever it sits.
    func exists(_ id: String) -> Bool {
        switch id {
        case "outbox": return !store.localDrafts.isEmpty || store.selectedView == .outbox
        case "scheduled": return !store.scheduledSends.isEmpty || store.selectedView == .scheduled
        // Promotions and Social: per account (`CategoryRows`); the stored
        // order keeps their slot while they are closed.
        case "promotions", "social": return store.categoryRowsShown
        default: return true
        }
    }

    /// Any conversation with a reminder (the Reminders count).
    var hasReminders: Bool {
        (store.unreadCounts["reminders"] ?? 0) > 0
    }

    func badge(_ view: MailboxView) -> Int? {
        switch view {
        case .inbox: return store.unreadCounts["inbox"]
        case .starred: return store.unreadCounts["starred"]
        case .snoozed: return store.unreadCounts["snoozed"]
        // Count is total drafts (not unread).
        case .drafts: return store.unreadCounts["drafts"]
        case .scheduled: return store.scheduledSends.count
        case .outbox: return store.localDrafts.count
        case .reminders: return store.unreadCounts["reminders"]
        case .spam: return store.unreadCounts["spam"]
        case .promotions: return store.unreadCounts["promotions"]
        case .social: return store.unreadCounts["social"]
        default: return nil
        }
    }

    /// Whether `badge` counts all items rather than the unread ones.
    static func countsTotal(_ view: MailboxView) -> Bool {
        switch view {
        case .drafts, .scheduled, .outbox, .reminders: return true
        default: return false
        }
    }
}

/// The collapsed sidebar, Gmail-style: icons only, right of the account rail
/// and exactly as wide as the top band's step past it
/// (`AccountRailMetrics.stripWidth`). Search, then the system views down to
/// and including "More" (and what is under it while open). No labels, saved
/// views or counts: a view's count is in its tooltip.
struct SidebarIconStrip: View {
    @Environment(MailStore.self) private var store
    @Environment(SidebarDisclosureModel.self) private var disclosure
    @Environment(\.mailAccent) private var accent
    /// Focuses the search field in the list column's top bar (as `/`).
    let onSearch: () -> Void

    private typealias Metrics = AccountRailMetrics

    var body: some View {
        let system = SidebarSystemRows(store: store, disclosure: disclosure)
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 2) {
                item(id: "sidebarStrip.search", glyph: "magnifyingglass", selected: false,
                     help: "Search (/)", label: "Search", value: "", action: onSearch)
                    .padding(.bottom, 6)
                ForEach(system.rows, id: \.self) { id in
                    if id == SidebarSystemOrder.moreId {
                        let open = disclosure.moreOpen
                        item(id: "sidebarStrip.more", glyph: open ? "chevron.up" : "chevron.down",
                             selected: false, help: open ? "Less" : "More",
                             label: open ? "Less" : "More", value: "") { disclosure.moreOpen.toggle() }
                    } else if let view = SidebarSystemOrder.view(for: id) {
                        let selected = store.selectedView == view
                        let count = system.badge(view)
                        let total = SidebarSystemRows.countsTotal(view)
                        item(id: "sidebarStrip.\(id)", glyph: view.icon(selected: selected),
                             selected: selected,
                             help: SidebarSystemOrder.stripHelp(title: view.title, count: count, total: total),
                             label: view.title,
                             value: SidebarSystemOrder.stripCount(count, total: total)) { store.goTo(view) }
                    }
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
        .frame(width: Metrics.stripWidth)
        .frame(maxHeight: .infinity)
        .background(Color.mailSidebar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebarStrip")
    }

    /// `label` is the view's name, `value` its count ("12 unread"), so the
    /// element's name stays the same as mail arrives.
    private func item(id: String, glyph: String, selected: Bool, help: String, label: String,
                      value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: glyph)
                .mailIconStyle(selected: selected)
                .frame(width: Metrics.stripWidth, height: Metrics.stripItemHeight)
                .background { selection(selected) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    /// The open view keeps the selection colour (DEC-077), as its row does
    /// in the full sidebar; before macOS 26, the system's unemphasized fill.
    @ViewBuilder private func selection(_ selected: Bool) -> some View {
        if accent.keepsSelectionColor {
            AccentSelectionBackground(selected: selected, accent: accent)
        } else if selected {
            Rectangle()
                .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
        }
    }
}
