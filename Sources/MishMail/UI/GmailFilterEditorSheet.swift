import SwiftUI

/// What the Gmail filters pane is editing: a new filter (`original` nil) or
/// an existing one.
struct GmailFilterEditTarget: Identifiable {
    let id = UUID()
    let accountId: String
    let original: GFilter?
}

/// Gmail Web's filter dialog: criteria, a live preview over local mail, then
/// actions. Forwarding is not offered (it needs another Google permission).
struct GmailFilterEditorSheet: View {
    @Environment(MailStore.self) var store
    @Environment(\.dismiss) private var dismiss
    let target: GmailFilterEditTarget

    @State private var draft = GmailFilterDraft()
    @State private var saving = false
    @State private var error: String?
    @State private var preview: GmailFilterPreview.Result?
    /// The edit reached Gmail but left the original behind: saving again
    /// would add a third filter.
    @State private var finished = false

    init(target: GmailFilterEditTarget) {
        self.target = target
        _draft = State(initialValue: target.original.map(GmailFilterDraft.init) ?? GmailFilterDraft())
    }

    private var unchanged: Bool {
        guard let original = target.original else { return false }
        return draft.body == original.body
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(target.original == nil ? "New filter" : "Edit filter")
                .font(.headline)
                .padding([.horizontal, .top], 20)
            Form {
                Section("Criteria") {
                    TextField("From", text: $draft.from)
                    TextField("To", text: $draft.to)
                    TextField("Subject", text: $draft.subject)
                    TextField("Has the words", text: $draft.hasWords)
                    TextField("Doesn't have", text: $draft.doesNotHave)
                    HStack {
                        Text("Size")
                        Picker("Size comparison", selection: $draft.sizeComparison) {
                            Text("greater than").tag(GmailFilterDraft.SizeComparison.larger)
                            Text("less than").tag(GmailFilterDraft.SizeComparison.smaller)
                        }
                        .labelsHidden().fixedSize()
                        TextField("Size", text: $draft.sizeValue, prompt: Text("Any"))
                            .labelsHidden().frame(width: 70)
                        Picker("Size unit", selection: $draft.sizeUnit) {
                            ForEach(GmailFilterDraft.SizeUnit.allCases, id: \.self) {
                                Text($0.title).tag($0)
                            }
                        }
                        .labelsHidden().fixedSize()
                    }
                    Toggle("Has attachment", isOn: $draft.hasAttachment)
                }
                Section("Matching mail on this Mac") { previewView }
                Section("Actions") {
                    Toggle("Skip the Inbox (Archive it)", isOn: $draft.skipInbox)
                    Toggle("Mark as read", isOn: $draft.markRead)
                    Toggle("Star it", isOn: $draft.star)
                    Picker("Apply the label", selection: $draft.labelId) {
                        Text("None").tag(String?.none)
                        ForEach(store.userLabels(forAccount: target.accountId)) { label in
                            Text(label.name).tag(Optional(label.gmailLabelId))
                        }
                        if let id = draft.labelId,
                           !store.userLabels(forAccount: target.accountId)
                               .contains(where: { $0.gmailLabelId == id }) {
                            Text(store.labelName(id, account: target.accountId) ?? id)
                                .tag(Optional(id))
                        }
                    }
                    Toggle("Delete it", isOn: $draft.delete)
                    Toggle("Never send it to Spam", isOn: $draft.neverSpam)
                    Picker("Importance", selection: $draft.importance) {
                        Text("Leave as is").tag(GmailFilterDraft.Importance.unchanged)
                        Text("Always mark it as important").tag(GmailFilterDraft.Importance.always)
                        Text("Never mark it as important").tag(GmailFilterDraft.Importance.never)
                    }
                    Picker("Categorize as", selection: $draft.category) {
                        Text("None").tag(String?.none)
                        ForEach(GmailFilterDraft.categories, id: \.id) { category in
                            Text(category.title).tag(Optional(category.id))
                        }
                    }
                    if let forward = draft.forward {
                        Label("Forwards to \(forward). Edit forwarding in Gmail.",
                              systemImage: "arrowshape.turn.up.right")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(saving || finished)
            footer
        }
        .frame(width: 520, height: 640)
        .task(id: draft.criteria) { await refreshPreview() }
    }

    @ViewBuilder
    private var previewView: some View {
        if let preview {
            if preview.matchCount == 0 {
                Text("None of the \(preview.scanned) most recent messages match.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("\(preview.matchCount) of the \(preview.scanned) most recent messages match.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(preview.hits) { hit in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.subject.isEmpty ? "(no subject)" : hit.subject)
                            .lineLimit(1)
                        Text(hit.from).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            if preview.sizeNotChecked {
                Text("Message sizes aren't stored on this Mac, so a size criterion matches nothing here; Gmail still applies it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("Add a criterion to see which messages match.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = error ?? draft.problem {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("filterEditorMessage")
            }
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button(finished ? "Close" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(target.original == nil ? "Create filter" : "Save") {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || finished || draft.problem != nil || unchanged)
            }
        }
        .padding(20)
    }

    private func refreshPreview() async {
        // Debounce typing; `.task(id:)` cancels this when criteria change again.
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }
        let criteria = draft.criteria
        let empty = criteria.from == nil && criteria.to == nil && criteria.subject == nil
            && criteria.query == nil && criteria.negatedQuery == nil
            && criteria.hasAttachment == nil && criteria.size == nil
        guard !empty else {
            preview = nil
            return
        }
        let result = await store.previewFilter(criteria, account: target.accountId)
        guard !Task.isCancelled else { return }
        preview = result
    }

    private func save() async {
        guard draft.problem == nil, !saving else { return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            if let original = target.original {
                try await store.replaceFilter(original, with: draft.body, account: target.accountId)
            } else {
                try await store.createFilter(draft.body, account: target.accountId)
            }
            dismiss()
        } catch {
            if case GmailFilterError.oldFilterKept = error { finished = true }
            self.error = error.localizedDescription
        }
    }
}
