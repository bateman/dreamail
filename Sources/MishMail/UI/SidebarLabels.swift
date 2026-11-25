import SwiftUI

/// Open/closed state of the sidebar's disclosure rows, kept in UserDefaults
/// (`SidebarDisclosure`) and mirrored here so a toggle re-renders at once.
/// Used by the sidebar only, on the main thread.
@Observable
final class SidebarDisclosureModel {
    var moreOpen = SidebarDisclosure.isMoreExpanded() {
        didSet { SidebarDisclosure.setMoreExpanded(moreOpen) }
    }
    var categoriesOpen = SidebarDisclosure.flag(SidebarDisclosure.categoriesKey) {
        didSet { SidebarDisclosure.setFlag(SidebarDisclosure.categoriesKey, categoriesOpen) }
    }
    /// Loaded per account on first use.
    private var expanded: [String: Set<String>] = [:]
    private var labelsMore: [String: Bool] = [:]
    private var accountCollapsed: [String: Bool] = [:]

    func isExpanded(_ node: SidebarLabelNode) -> Bool {
        expandedSet(node.accountId).contains(node.gmailLabelId)
    }

    func setExpanded(_ node: SidebarLabelNode, _ open: Bool) {
        var set = expandedSet(node.accountId)
        if open { set.insert(node.gmailLabelId) } else { set.remove(node.gmailLabelId) }
        expanded[node.accountId] = set
        SidebarDisclosure.setLabel(node.gmailLabelId, accountId: node.accountId, expanded: open)
    }

    private func expandedSet(_ accountId: String) -> Set<String> {
        if let set = expanded[accountId] { return set }
        return SidebarDisclosure.expandedLabels(accountId: accountId)
    }

    func labelsMoreOpen(_ accountId: String) -> Bool {
        labelsMore[accountId]
            ?? SidebarDisclosure.flag(SidebarDisclosure.labelsMoreKey(accountId: accountId))
    }

    func setLabelsMoreOpen(_ accountId: String, _ open: Bool) {
        labelsMore[accountId] = open
        SidebarDisclosure.setFlag(SidebarDisclosure.labelsMoreKey(accountId: accountId), open)
    }

    func accountOpen(_ accountId: String) -> Bool {
        !(accountCollapsed[accountId]
          ?? SidebarDisclosure.flag(SidebarDisclosure.accountCollapsedKey(accountId: accountId)))
    }

    func setAccountOpen(_ accountId: String, _ open: Bool) {
        accountCollapsed[accountId] = !open
        SidebarDisclosure.setFlag(SidebarDisclosure.accountCollapsedKey(accountId: accountId), !open)
    }
}

/// What the "+" next to Labels, or a label's "Add sublabel…", opens.
struct NewLabelRequest: Identifiable {
    let id = UUID()
    /// nil in the all-accounts sidebar with more than one account: the
    /// sheet asks.
    var accountId: String?
    var parent: String?
}

/// One account's labels in the sidebar: the listed tree, then Gmail's
/// trailing "More" row with the labels it hides.
struct SidebarLabelTreeView: View {
    @Environment(MailStore.self) private var store
    let accountId: String
    let disclosure: SidebarDisclosureModel
    let onNewLabel: (NewLabelRequest) -> Void

    var body: some View {
        let roots = store.labelTrees[accountId] ?? []
        let parts = SidebarLabelTree.split(roots) { unread(for: $0) }
        ForEach(parts.listed) { node in
            SidebarLabelNodeView(node: node, disclosure: disclosure, onNewLabel: onNewLabel)
        }
        if !parts.more.isEmpty {
            let open = disclosure.labelsMoreOpen(accountId)
            SidebarMoreToggle(open: open, identifier: "sidebar.labels.more.\(accountId)") {
                disclosure.setLabelsMoreOpen(accountId, !open)
            }
            if open {
                ForEach(parts.more) { node in
                    SidebarLabelNodeView(node: node, disclosure: disclosure, onNewLabel: onNewLabel)
                }
            } else if let selected = selectedBehindMore(parts) {
                // Closed "More": the open label stays visible.
                SidebarLabelRow(node: selected, onNewLabel: onNewLabel)
            }
        }
    }

    /// The open label of this account when only the "More" list holds it.
    private func selectedBehindMore(
        _ parts: (listed: [SidebarLabelNode], more: [SidebarLabelNode])
    ) -> SidebarLabelNode? {
        guard case .label(let account, let labelId, _) = store.selectedView,
              account == accountId,
              SidebarLabelTree.find(labelId, in: parts.listed) == nil else { return nil }
        // A closed parent hides its sublabels, the open one included.
        return SidebarLabelTree.find(labelId, in: parts.more, isOpen: disclosure.isExpanded)
    }

    private func unread(for node: SidebarLabelNode) -> Int {
        store.unreadCounts[SidebarCounts.labelKey(accountId: node.accountId,
                                                  labelId: node.gmailLabelId)] ?? 0
    }
}

/// A label row, with its sublabels under a disclosure triangle.
struct SidebarLabelNodeView: View {
    let node: SidebarLabelNode
    let disclosure: SidebarDisclosureModel
    let onNewLabel: (NewLabelRequest) -> Void

    var body: some View {
        if node.children.isEmpty {
            SidebarLabelRow(node: node, onNewLabel: onNewLabel)
        } else {
            DisclosureGroup(isExpanded: Binding(
                get: { disclosure.isExpanded(node) },
                set: { disclosure.setExpanded(node, $0) })
            ) {
                ForEach(node.children) { child in
                    SidebarLabelNodeView(node: child, disclosure: disclosure, onNewLabel: onNewLabel)
                }
            } label: {
                SidebarLabelRow(node: node, onNewLabel: onNewLabel)
            }
        }
    }
}

/// One label: the tag in the label's color, its name, its unread count.
/// Opens the label's view (`MailboxView.label`), a parent included.
struct SidebarLabelRow: View {
    @Environment(MailStore.self) private var store
    @Environment(\.mailAccent) private var accent
    let node: SidebarLabelNode
    let onNewLabel: (NewLabelRequest) -> Void
    @State private var hovering = false
    @State private var pickingColor = false

    var body: some View {
        let view = MailboxView.label(account: node.accountId, labelId: node.gmailLabelId,
                                     name: node.fullName)
        let selected = store.selectedView == view
        // Same reselect gating as the system rows (`Sidebar.sidebarItem`).
        let reselect = ListReselectPolicy.mountsHandler(row: view, selected: store.selectedView)
        let unread = store.unreadCounts[SidebarCounts.labelKey(
            accountId: node.accountId, labelId: node.gmailLabelId)] ?? 0
        Label {
            Text(node.displayName)
                .fontWeight(selected || unread > 0 ? .semibold : .regular)
                .lineLimit(1)
                .mailRowTitleStyle()
        } icon: {
            SidebarLabelTag(colors: node.colors)
        }
        .listItemTint(.monochrome)
        // Gmail's "⋮" takes the count's place on hover and on the open label.
        .modifier(SidebarCount(count: showsMenuButton(selected) ? 0 : unread,
                               painted: accent.paintsSelection))
        .help(node.fullName)
        .accessibilityIdentifier("sidebar.label.\(node.accountId).\(node.gmailLabelId)")
        .overlay(alignment: .trailing) {
            if showsMenuButton(selected) {
                LabelMenuButton(node: node, onNewLabel: onNewLabel) { pickingColor = true }
            }
        }
        .onHover { hovering = $0 }
        .popover(isPresented: $pickingColor, arrowEdge: .trailing) {
            if let row = store.labelRow(node) {
                LabelColorPalette(label: row) { pickingColor = false }
            }
        }
        .listRowBackground(AccentSelectionBackground.sidebar(selected: selected, accent: accent))
        .contextMenu {
            LabelMenuItems(node: node, onNewLabel: onNewLabel) { pickingColor = true }
        }
        .simultaneousGesture(
            TapGesture().onEnded { store.goTo(view) },
            including: reselect ? .gesture : .subviews)
        .tag(view)
    }
}

extension SidebarLabelRow {
    fileprivate func showsMenuButton(_ selected: Bool) -> Bool { hovering || selected || pickingColor }
}

/// Gmail's label glyph: a tag filled with the label's color (the Mac-only
/// color first, DEC-023), outlined only when the fill would vanish into the
/// sidebar (the dots' rule, DEC-029).
struct SidebarLabelTag: View {
    let colors: LabelColors
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.sidebarRowSize) private var rowSize

    var body: some View {
        let metrics = MailIconMetrics(rowSize: rowSize)
        let style = LabelPillStyle.resolve(colors, appearance: .init(colorScheme), shape: .dot)
        Image(systemName: "tag.fill")
            .font(metrics.font)
            .imageScale(.medium)
            .foregroundStyle(Color(style.fill))
            .overlay {
                if style.needsBorder {
                    Image(systemName: "tag")
                        .font(metrics.font)
                        .imageScale(.medium)
                        .foregroundStyle(Color(style.border))
                }
            }
            .frame(width: metrics.columnWidth)
            .accessibilityHidden(true)
    }
}

/// Gmail's "More" / "Less" row: not a mailbox, so not selectable.
struct SidebarMoreToggle: View {
    let open: Bool
    let identifier: String
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Label {
                Text(open ? "Less" : "More")
                    .mailRowTitleStyle()
            } icon: {
                Image(systemName: open ? "chevron.up" : "chevron.down")
                    .mailIconStyle(selected: false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

/// The header of one account's labels in the all-accounts sidebar: its
/// colored dot and name.
struct SidebarAccountHeader: View {
    let account: Account

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(nsColor: AccountLabelColor.nsColor(hex: account.labelColor,
                                                               accountId: account.id)))
                .frame(width: 8, height: 8)
            Text(AccountLabelColor.title(account))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityIdentifier("sidebar.labels.account.\(account.id)")
    }
}

/// Gmail's "New label" dialog: a name, and optionally the label to nest it
/// under.
struct NewLabelSheet: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: NewLabelRequest
    @State private var name = ""
    @State private var nest = false
    @State private var parent = ""
    @State private var accountId = ""
    @State private var saving = false
    @State private var failure: String?

    var body: some View {
        let rows = store.userLabels(forAccount: accountId)
        let check = NewLabelName.check(name: name, nest: nest, parent: parent, rows: rows)
        VStack(alignment: .leading, spacing: 12) {
            Text("New label").font(.headline)
            if request.accountId == nil && store.accounts.count > 1 {
                Picker("Account", selection: $accountId) {
                    ForEach(store.accounts) { account in
                        Text(AccountLabelColor.title(account)).tag(account.id)
                    }
                }
            }
            TextField("Please enter a new label name", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("newLabel.name")
            Toggle("Nest label under:", isOn: $nest)
                .disabled(rows.isEmpty)
            Picker("", selection: $parent) {
                ForEach(rows.map(\.name).sorted {
                    $0.compare($1, options: [.caseInsensitive]) == .orderedAscending
                }, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .disabled(!nest || rows.isEmpty)
            if check == .duplicate {
                Text("A label with this name already exists.")
                    .font(.caption).foregroundStyle(.red)
            }
            if let failure {
                Text(failure)
                    .font(.caption).foregroundStyle(.red)
                    .accessibilityIdentifier("newLabel.error")
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    saving = true
                    failure = nil
                    Task {
                        failure = await store.createLabel(
                            name: name, parent: nest ? parent : nil, accountId: accountId)
                        saving = false
                        if failure == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!Self.canCreate(check) || saving || accountId.isEmpty)
                .accessibilityIdentifier("newLabel.create")
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            accountId = request.accountId ?? store.activeAccountId ?? store.accounts.first?.id ?? ""
            if let p = request.parent {
                nest = true
                parent = p
            } else {
                resetParent()
            }
        }
        // Another account: its own labels only. A parent picked on the
        // previous account must never be sent to this one.
        .onChange(of: accountId) { old, _ in
            // The first value comes from onAppear, which set the parent.
            guard !old.isEmpty else { return }
            failure = nil
            resetParent()
        }
    }

    private func resetParent() {
        let rows = store.userLabels(forAccount: accountId)
        parent = rows.first?.name ?? ""
        if rows.isEmpty { nest = false }
    }

    private static func canCreate(_ check: NewLabelName.Check) -> Bool {
        if case .ok = check { return true }
        return false
    }
}
