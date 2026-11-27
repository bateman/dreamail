import SwiftUI

/// The sidebar list's density: Compact draws the list with the small system
/// row size, which sets the rows' height; glyphs and titles keep the size of
/// the user's own setting. Comfortable changes nothing.
struct SidebarListDensity: ViewModifier {
    let density: SidebarDensity
    @Environment(\.sidebarRowSize) private var system

    func body(content: Content) -> some View {
        let size = density.listRowSize
        content
            .environment(\.mailRowSizeOverride, size == nil ? nil : system)
            .environment(\.sidebarRowSize, size ?? system)
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
            }
        }
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

    var body: some View {
        let view = MailboxView.label(account: node.accountId, labelId: node.gmailLabelId,
                                     name: node.fullName)
        let selected = store.selectedView == view
        // Same reselect gating as the system rows (`Sidebar.sidebarItem`).
        let reselect = ListReselectPolicy.mountsHandler(row: view, selected: store.selectedView)
        let unread = store.unreadCounts[SidebarCounts.labelKey(
            accountId: node.accountId, labelId: node.gmailLabelId)] ?? 0
        Label {
            // "⋮" sits in the title, at its end: the row stays the plain
            // sidebar Label (no frame or overlay around it, which made the
            // sidebar's rows taller and its outline rows unfindable).
            HStack(spacing: 4) {
                Text(node.displayName)
                    .fontWeight(selected || unread > 0 ? .semibold : .regular)
                    .lineLimit(1)
                    .mailRowTitleStyle()
                if showsMenuButton(selected) {
                    Spacer(minLength: 4)
                    LabelMenuButton(node: node, selected: selected, onNewLabel: onNewLabel, onPickColor: pickColor)
                        // Clear of the list's right edge: flush against it the
                        // ⋮ was half out of the visible area and the UI test
                        // found it "not hittable" (a 16 pt box at x 264-280).
                        .padding(.trailing, 8)
                }
            }
        } icon: {
            SidebarLabelTag(colors: node.colors)
        }
        .listItemTint(.monochrome)
        // Gmail's "⋮" takes the count's place on hover; on the open label it
        // is drawn beside the count, which stays.
        .modifier(SidebarCount(count: hidesCount ? 0 : unread, selected: selected,
                               painted: accent.paintsSelection || (selected && accent.keepsSelectionColor)))
        .environment(\.sidebarRowSelected, selected)
        .help(node.fullName)
        // A container, so the "⋮" in the title stays its own element (for
        // VoiceOver and the UI tests) instead of merging into the label.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar.label.\(node.accountId).\(node.gmailLabelId)")
        // The row's tap opens the label. "⋮" is a menu button: its click
        // opens the menu (AppKit takes the mouse down) and the UI test
        // checks it does not also reopen the label.
        .simultaneousGesture(
            TapGesture().onEnded { store.goTo(view) },
            including: reselect ? .gesture : .subviews)
        .onHover { hovering = $0 }
        .listRowBackground(AccentSelectionBackground.sidebar(selected: selected, accent: accent))
        .contextMenu {
            LabelMenuItems(node: node, onNewLabel: onNewLabel, onPickColor: pickColor)
        }
        .tag(view)
    }
}

extension SidebarLabelRow {
    fileprivate func showsMenuButton(_ selected: Bool) -> Bool { hovering || selected }

    /// "Choose color…": the Organize sheet's palette, in one sheet hosted
    /// by `LabelMenuPresentation` (not a popover on every row).
    fileprivate func pickColor() {
        if let row = store.labelRow(node) { store.labelMenu.coloring = row }
    }
    /// The count gives way to "⋮" only while the pointer is on the row.
    fileprivate var hidesCount: Bool { hovering }
}

/// Gmail's label glyph: a tag filled with the label's color (the Mac-only
/// color first, DEC-023). The drawing is `SidebarTagStyle`: in dark
/// appearance a colored label is always a visible fill (a dark grey is
/// lightened), in light the true fill with its outline where needed; only a
/// label with no color is an outline.
struct SidebarLabelTag: View {
    let colors: LabelColors
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.mailRowSize) private var rowSize

    var body: some View {
        let metrics = MailIconMetrics(rowSize: rowSize)
        let tag = SidebarTagStyle.resolve(colors, appearance: .init(colorScheme))
        Group {
            if let fill = tag.fill {
                Image(systemName: "tag.fill")
                    .foregroundStyle(Color(fill))
                    .overlay {
                        if let outline = tag.outline {
                            Image(systemName: "tag").foregroundStyle(Color(outline))
                        }
                    }
            } else if let outline = tag.outline {
                // No color: the outline only, as Gmail draws it, so any
                // fill means the label has a color (a dark grey included).
                Image(systemName: "tag").foregroundStyle(Color(outline))
            }
        }
        .font(metrics.font)
        .imageScale(.medium)
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
