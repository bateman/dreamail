import SwiftUI

/// Settings → Signatures: each account's named signatures (add, rename,
/// edit, delete, import from Gmail) and the default of each address the
/// account sends as, for new messages and for replies and forwards.
///
/// A signature is written like the compose body: Markdown, with ⌘B, ⌘I,
/// links and lists; that is what the recipient sees rendered.
struct SignatureSettings: View {
    @Environment(MailStore.self) private var store
    /// The account shown; kept so "Show Signatures…" and compose's "Manage
    /// signatures" can open the pane on a given account.
    @AppStorage(SignatureSettings.accountKey) private var accountId = ""

    static let accountKey = MailStore.signatureSettingsAccountKey

    /// Opens on `accountId` the next time the pane shows.
    static func open(accountId: String) {
        UserDefaults.standard.set(accountId, forKey: accountKey)
        UserDefaults.standard.set(SettingsView.Pane.signatures.rawValue, forKey: "settingsPane")
    }

    @State private var editing: SignatureRecord?
    @State private var deleting: SignatureRecord?
    @State private var importing = false
    /// The last write that failed, shown under the list.
    @State private var writeError: String?

    private var signatures: [SignatureRecord] {
        store.signatureBook.signatures(for: accountId)
    }

    /// The addresses the account sends as, primary first.
    private var addresses: [String] {
        let aliases = store.sendIdentities
            .filter { $0.accountId.caseInsensitiveCompare(accountId) == .orderedSame }
            .map(\.email)
            .filter { $0.caseInsensitiveCompare(accountId) != .orderedSame }
        var seen = Set<String>()
        return ([accountId] + aliases.sorted()).filter { seen.insert($0.lowercased()).inserted }
    }

    var body: some View {
        PaneScaffold(title: "Signatures",
                     subtitle: "Added at the end of the messages you write, above the quoted text in replies. Each account has its own.") {
            if store.accounts.isEmpty {
                Text("Add a Google account first.")
                    .foregroundStyle(.secondary)
                    .padding(20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if store.accounts.count > 1 {
                            Picker("Account", selection: $accountId) {
                                ForEach(store.accounts) { account in
                                    Text(account.id).tag(account.id)
                                }
                            }
                            .frame(maxWidth: 360)
                            .accessibilityIdentifier("settings.signatures.account")
                        }
                        signatureList
                        if let writeError {
                            Text(writeError).font(.system(size: 11)).foregroundStyle(.red)
                        }
                        defaultsSection
                    }
                    .padding(20)
                }
            }
        }
        .onAppear {
            store.reloadSignatures()
            validateAccount()
        }
        // An account removed (or added) while the pane is open.
        .onChange(of: store.accounts.map(\.id)) { validateAccount() }
        .onChange(of: accountId) { writeError = nil }
        .sheet(item: $editing) { signature in
            SignatureEditor(signature: signature)
        }
        .sheet(isPresented: $importing) {
            GmailSignatureImportSheet(accountId: accountId)
        }
        .confirmationDialog("Delete this signature?",
                            isPresented: Binding(get: { deleting != nil },
                                                 set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { signature in
            Button("Delete “\(signature.name)”", role: .destructive) {
                if let id = signature.id { perform { try store.deleteSignature(id: id) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Messages already written keep it. Defaults that used it become “No signature”.")
        }
    }

    /// The shown account must be a signed-in one.
    private func validateAccount() {
        guard !store.accounts.contains(where: {
            $0.id.caseInsensitiveCompare(accountId) == .orderedSame
        }) else { return }
        accountId = store.activeAccountId.flatMap { active in
            store.accounts.first { $0.id == active }?.id
        } ?? store.accounts.first?.id ?? ""
    }

    private func perform(_ write: () throws -> Void) {
        do {
            try write()
            writeError = nil
        } catch {
            writeError = error.localizedDescription
        }
    }

    private var signatureList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Signatures").font(.headline)
                Spacer()
                Button("Import from Gmail…") { importing = true }
                    .help("Copy the signature Gmail has for one of this account's addresses")
                    .accessibilityIdentifier("settings.signatures.import")
                Button("New signature") {
                    editing = SignatureRecord(id: nil, accountId: accountId, name: "",
                                              body: "", createdAt: Date())
                }
                .accessibilityIdentifier("settings.signatures.new")
            }
            if signatures.isEmpty {
                Text("No signatures for \(accountId) yet.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(signatures) { signature in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(signature.name).font(.system(size: 13, weight: .medium))
                                Text(signature.body.replacingOccurrences(of: "\n", with: " · "))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button("Edit…") { editing = signature }
                            Button {
                                deleting = signature
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Delete")
                            .accessibilityLabel("Delete \(signature.name)")
                        }
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
            }
        }
    }

    private var defaultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Defaults").font(.headline)
            Text("Chosen automatically in compose. You can still pick another one, or none, in the compose window.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("Address").font(.system(size: 11, weight: .medium))
                    Text("New messages").font(.system(size: 11, weight: .medium))
                    Text("Replies and forwards").font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary)
                ForEach(addresses, id: \.self) { email in
                    GridRow {
                        Text(email).lineLimit(1).truncationMode(.middle)
                        defaultPicker(email: email, use: .newMessage)
                        defaultPicker(email: email, use: .reply)
                    }
                }
            }
        }
    }

    private func defaultPicker(email: String, use: SignatureUse) -> some View {
        let isPrimary = email.caseInsensitiveCompare(accountId) == .orderedSame
        let binding = Binding<SignatureDefaultChoice>(
            get: {
                let choice = store.signatureBook.choice(use: use, accountId: accountId, email: email)
                // The primary has nothing to follow: no row reads as none.
                if isPrimary, choice == .followPrimary { return .none }
                return choice
            },
            set: { choice in
                perform {
                    try store.setSignatureDefault(
                        accountId: accountId, email: email, use: use,
                        choice: isPrimary && choice == .none ? .followPrimary : choice)
                }
            })
        return Picker("", selection: binding) {
            if !isPrimary {
                Text("Same as \(accountId)").tag(SignatureDefaultChoice.followPrimary)
            }
            Text("No signature").tag(SignatureDefaultChoice.none)
            ForEach(signatures) { signature in
                if let id = signature.id {
                    Text(signature.name).tag(SignatureDefaultChoice.signature(id))
                }
            }
        }
        .labelsHidden()
        .frame(width: 190)
        .accessibilityLabel(use == .newMessage ? "Default for new messages from \(email)"
                                               : "Default for replies and forwards from \(email)")
    }
}

/// Add or edit one signature: its name and its text.
private struct SignatureEditor: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let signature: SignatureRecord
    @State private var name: String
    @State private var text: String
    @State private var focused = false
    @State private var caret = 0
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var formatTarget = ComposeBodyFormatTarget()
    @State private var saveError: String?

    init(signature: SignatureRecord) {
        self.signature = signature
        _name = State(initialValue: signature.name)
        _text = State(initialValue: signature.body)
    }

    /// Why the text cannot be saved as it is (shown as the user types).
    private var problem: String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ComposeSignature.saveProblem(text, maxLength: SignatureStore.maxBodyLength)
    }

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && problem == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(signature.id == nil ? "New signature" : "Edit signature").font(.headline)
            TextField("Name (only you see it)", text: $name)
                .accessibilityIdentifier("settings.signatures.name")
            ComposeBodyEditor(text: $text, isFocused: $focused, caretUTF16: $caret,
                              selection: $selection, formatTarget: formatTarget, fontSize: 13)
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .accessibilityIdentifier("settings.signatures.body")
            Text("Written like a message: **bold** (⌘B), *italic* (⌘I), [link](https://…), lists with “- ”. MishMail adds the “-- ” line above it. No images.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message = saveError ?? problem {
                Text(message).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    // Closes only once the signature is stored.
                    do {
                        if let id = signature.id {
                            try store.updateSignature(id: id, name: name, body: text)
                        } else {
                            try store.addSignature(accountId: signature.accountId,
                                                   name: name, body: text)
                        }
                        dismiss()
                    } catch {
                        saveError = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onChange(of: text) { saveError = nil }
    }
}

/// The Gmail signature of each of the account's send-as addresses, read
/// from Gmail when the sheet opens; "Import" copies one into MishMail.
private struct GmailSignatureImportSheet: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let accountId: String

    private struct Entry: Identifiable {
        var id: String { email }
        let email: String
        let html: String
        let preview: String
    }

    private enum Load {
        case loading
        case loaded([Entry])
        case failed
    }
    @State private var load: Load = .loading
    @State private var note: String?
    @State private var imported: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import from Gmail").font(.headline)
            Text("Copies the signature Gmail has for an address into MishMail, as a new signature of \(accountId). Gmail's own signature is not changed.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content.frame(minHeight: 120, maxHeight: 300)
            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task { await fetch() }
    }

    @ViewBuilder
    private var content: some View {
        switch load {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading your Gmail signatures…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            VStack(spacing: 8) {
                Text("Gmail did not answer. Check the connection, or sign in to this account again.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try Again") { Task { await fetch() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let entries) where entries.isEmpty:
            Text("Gmail has no signature for this account's addresses.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let entries):
            List(entries) { entry in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.email).font(.system(size: 12.5, weight: .medium))
                        Text(entry.preview).font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    Spacer()
                    Button(imported.contains(entry.email) ? "Imported" : "Import") {
                        importEntry(entry)
                    }
                    .disabled(imported.contains(entry.email))
                }
            }
        }
    }

    private func fetch() async {
        load = .loading
        do {
            let rows = try await store.gmailSignatures(accountId: accountId)
            load = .loaded(rows.map {
                let converted = SignatureImport.markdown(fromGmailHTML: $0.html)
                return Entry(email: $0.email, html: $0.html,
                             preview: converted.tooLarge ? "Too large to import." : converted.body)
            })
        } catch {
            load = .failed
        }
    }

    private func importEntry(_ entry: Entry) {
        let result: SignatureImport.Result
        do {
            result = try store.importGmailSignature(accountId: accountId, email: entry.email,
                                                    html: entry.html)
        } catch {
            note = error.localizedDescription
            return
        }
        imported.insert(entry.email)
        note = Self.importNote(result)
    }

    /// What the import left out, in words.
    static func importNote(_ result: SignatureImport.Result) -> String {
        var left: [String] = []
        switch result.droppedImages {
        case 0: break
        case 1: left.append("its image")
        default: left.append("its \(result.droppedImages) images")
        }
        switch result.droppedLinks {
        case 0: break
        case 1: left.append("one link, kept as text (a link type MishMail does not send, or one whose text names another address)")
        default: left.append("\(result.droppedLinks) links, kept as text (link types MishMail does not send, or links whose text names another address)")
        }
        guard !left.isEmpty else {
            return "Imported. Choose it as a default below the list, or in compose."
        }
        return "Imported without " + left.joined(separator: " and ")
            + ". MishMail signatures hold text, formatting and links only."
    }
}

/// Settings → Accounts, one account's box: opens the Signatures pane on it.
struct ShowSignaturesButton: View {
    let accountId: String
    @AppStorage("settingsPane") private var pane: SettingsView.Pane = .accounts
    @AppStorage(SignatureSettings.accountKey) private var signaturesAccount = ""

    var body: some View {
        Button("Show Signatures…") {
            signaturesAccount = accountId
            pane = .signatures
        }
        .accessibilityIdentifier("settings.account.showSignatures")
    }
}
