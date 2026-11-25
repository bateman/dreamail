import SwiftUI

/// Gmail's label menu (the "⋮" on a label row, and its context menu), in
/// Gmail's order and wording. Acts on the label's own account only.
struct LabelMenuItems: View {
    @Environment(MailStore.self) private var store
    let node: SidebarLabelNode
    let onNewLabel: (NewLabelRequest) -> Void
    let onPickColor: () -> Void

    var body: some View {
        if let row = store.labelRow(node) {
            Menu("Label color") {
                Button("Choose color…", action: onPickColor)
                    .accessibilityIdentifier("labelMenu.color.choose")
                Divider()
                // The two colors stay apart (DEC-023): Gmail's, and the one
                // only on this Mac that wins on display.
                let family = store.labelFamily(row)
                // Both kinds go, on the label and its sublabels: no color is
                // what is seen.
                Button("Remove color") { store.setGmailLabelColor(row, to: nil) }
                    .disabled(!family.contains { $0.gmailBackgroundColor != nil || $0.color != nil })
                    .accessibilityIdentifier("labelMenu.color.remove")
                Button("Remove color only on this Mac") { store.setLabelColor(row, hex: nil) }
                    .disabled(!family.contains { $0.color != nil })
                    .accessibilityIdentifier("labelMenu.color.removeLocal")
            }
            .accessibilityIdentifier("labelMenu.color")

            Section("In label list") {
                let current = SidebarLabelNode.Visibility(raw: row.listVisibility)
                choice("Show", on: current == .show, id: "labelMenu.labelList.show") {
                    store.setLabelListVisibility(row, .show)
                }
                choice("Show if unread", on: current == .showIfUnread,
                       id: "labelMenu.labelList.showIfUnread") {
                    store.setLabelListVisibility(row, .showIfUnread)
                }
                choice("Hide", on: current == .hide, id: "labelMenu.labelList.hide") {
                    store.setLabelListVisibility(row, .hide)
                }
            }

            Section("In message list") {
                let current = MessageListVisibility(raw: row.messageListVisibility)
                choice("Show", on: current == .show, id: "labelMenu.messageList.show") {
                    store.setMessageListVisibility(row, .show)
                }
                choice("Hide", on: current == .hide, id: "labelMenu.messageList.hide") {
                    store.setMessageListVisibility(row, .hide)
                }
            }

            Divider()
            Button("Edit") { store.labelMenu.editing = row }
                .accessibilityIdentifier("labelMenu.edit")
            Button("Remove label") { store.labelMenu.removing = row }
                .accessibilityIdentifier("labelMenu.remove")
            Button("Add sublabel") {
                onNewLabel(NewLabelRequest(accountId: node.accountId, parent: node.fullName))
            }
            .accessibilityIdentifier("labelMenu.addSublabel")
            Divider()
            Button("Organize Labels…") { store.showLabelOrganizer = true }
                .accessibilityIdentifier("labelMenu.organize")
        }
    }

    /// A menu item with Gmail's check mark on the current choice.
    private func choice(_ title: String, on: Bool, id: String,
                        action: @escaping () -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { on }, set: { if $0 { action() } }))
            .accessibilityIdentifier(id)
    }
}

/// The "⋮" at the right of a label row: the same menu as a right-click.
struct LabelMenuButton: View {
    let node: SidebarLabelNode
    let onNewLabel: (NewLabelRequest) -> Void
    let onPickColor: () -> Void

    var body: some View {
        Menu {
            LabelMenuItems(node: node, onNewLabel: onNewLabel, onPickColor: onPickColor)
        } label: {
            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Options")
        .accessibilityLabel(Text(verbatim: "Options for label " + LabelText.safe(node.displayName)))
        .accessibilityIdentifier("sidebar.label.menu.\(node.accountId).\(node.gmailLabelId)")
    }
}

/// The label menu's dialogs, hosted once by the sidebar: Edit, the Remove
/// confirmation, and a failure with its retry.
struct LabelMenuPresentation: ViewModifier {
    @Environment(MailStore.self) private var store

    func body(content: Content) -> some View {
        @Bindable var store = store
        let removing = store.labelMenu.removing
        content
            .sheet(item: $store.labelMenu.editing) { label in
                EditLabelSheet(label: label)
            }
            .sheet(item: $store.labelMenu.coloring) { label in
                LabelColorSheet(label: label)
            }
            .alert(Text(verbatim: removing.map {
                       LabelRemovalText.title(label: $0, multipleAccounts: store.accounts.count > 1)
                   } ?? ""),
                   isPresented: Binding(get: { store.labelMenu.removing != nil },
                                        set: { if !$0 { store.labelMenu.removing = nil } }),
                   presenting: removing) { label in
                // Destructive: Cancel is the default button.
                Button("Cancel", role: .cancel) { store.labelMenu.removing = nil }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("labelRemove.cancel")
                Button("Remove", role: .destructive) {
                    store.labelMenu.removing = nil
                    store.removeLabel(label)
                }
                .accessibilityIdentifier("labelRemove.confirm")
            } message: { label in
                Text(verbatim: LabelRemovalText.message(
                    label: label,
                    sublabels: LabelFamily.descendants(
                        of: label, in: store.userLabels(forAccount: label.accountId)).count,
                    savedViews: store.savedViewsRemoved(with: label).map(\.name)))
            }
            .alert(Text(verbatim: store.labelMenu.failure?.title ?? ""),
                   isPresented: Binding(get: { store.labelMenu.failure != nil },
                                        set: { if !$0 { store.labelMenu.failure = nil } }),
                   presenting: store.labelMenu.failure) { failure in
                if let retry = failure.retry {
                    Button("Retry") {
                        store.labelMenu.failure = nil
                        retry()
                    }
                    .accessibilityIdentifier("labelFailure.retry")
                }
                Button("OK", role: .cancel) { store.labelMenu.failure = nil }
            } message: { failure in
                Text(verbatim: failure.message)
            }
    }
}

/// "Label color ▸ Choose color…": the Organize sheet's palette for one
/// label, showing its colors as they are now.
struct LabelColorSheet: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let label: LabelRow

    var body: some View {
        let row = store.userLabels(forAccount: label.accountId).first { $0.id == label.id } ?? label
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "Label color: " + LabelText.quoted(row.name)).font(.headline)
                .padding([.top, .horizontal], 12)
            LabelColorPalette(label: row) { dismiss() }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("labelColor.done")
            }
            .padding([.bottom, .horizontal], 12)
        }
        // Escape closes it, whatever holds the focus (a swatch button can
        // take the key before the Done button's cancel shortcut sees it).
        .onExitCommand { dismiss() }
    }
}

/// Gmail's "Edit label" dialog: the name, and "Nest label under" to move
/// it. Its sublabels move with it.
struct EditLabelSheet: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let label: LabelRow
    @State private var name = ""
    @State private var nest = false
    @State private var parent = ""
    @State private var saving = false
    @State private var failure: String?

    var body: some View {
        let rows = store.userLabels(forAccount: label.accountId)
        // Not under itself nor one of its own sublabels.
        let parents = rows.map(\.name)
            .filter { $0 != label.name && !$0.hasPrefix(label.name + "/") }
            .sorted { $0.compare($1, options: [.caseInsensitive]) == .orderedAscending }
        let plan = LabelRename.plan(label: label, name: name, parent: nest ? parent : nil, rows: rows)
        let problem = Self.shownProblem(plan)
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit label").font(.headline)
            TextField("Label name", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("editLabel.name")
            Toggle("Nest label under:", isOn: $nest)
                .disabled(parents.isEmpty)
                .accessibilityIdentifier("editLabel.nest")
            Picker("", selection: $parent) {
                ForEach(parents, id: \.self) { Text(verbatim: LabelText.safe($0)).tag($0) }
            }
            .labelsHidden()
            .disabled(!nest || parents.isEmpty)
            .accessibilityIdentifier("editLabel.parent")
            if let problem {
                Text(verbatim: problem).font(.caption).foregroundStyle(.red)
            }
            if let failure {
                Text(verbatim: failure)
                    .font(.caption).foregroundStyle(.red)
                    .accessibilityIdentifier("editLabel.error")
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    saving = true
                    failure = nil
                    Task {
                        failure = await store.renameLabel(label, name: name, parent: nest ? parent : nil)
                        saving = false
                        if failure == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || !Self.canSave(plan))
                .accessibilityIdentifier("editLabel.save")
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            let byName = Dictionary(rows.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            if let p = SidebarLabelTree.parent(of: label.name, among: byName) {
                nest = true
                parent = p.name
                name = String(label.name.dropFirst(p.name.count + 1))
            } else {
                name = label.name
                parent = parents.first ?? ""
            }
        }
    }

    /// What the dialog says before Save is pressed.
    private static func shownProblem(_ plan: Result<[LabelRename.Change], LabelRename.Problem>) -> String? {
        guard case .failure(let problem) = plan,
              problem == .duplicate || problem == .intoItself else { return nil }
        return problem.message
    }

    private static func canSave(_ plan: Result<[LabelRename.Change], LabelRename.Problem>) -> Bool {
        switch plan {
        case .success: return true
        case .failure(let problem): return problem == .unchanged
        }
    }
}
