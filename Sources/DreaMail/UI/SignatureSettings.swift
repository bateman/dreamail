import SwiftUI
import AppKit

/// Settings → Signatures: each account's named signatures (add, rename,
/// edit, delete; the Gmail one of each address arrives by itself) and the default of each address the
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
            store.refreshGmailSignaturesIfDue(accountId: accountId)
        }
        // An account removed (or added) while the pane is open.
        .onChange(of: store.accounts.map(\.id)) { validateAccount() }
        .onChange(of: accountId) {
            writeError = nil
            store.refreshGmailSignaturesIfDue(accountId: accountId)
        }
        .sheet(item: $editing) { signature in
            SignatureEditor(signature: signature)
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
                Button("New signature") {
                    editing = SignatureRecord(id: nil, accountId: accountId, name: "",
                                              body: "", createdAt: Date())
                }
                .accessibilityIdentifier("settings.signatures.new")
            }
            gmailStatus
            if signatures.isEmpty {
                Text("No signatures for \(accountId) yet.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(signatures) { signature in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(signature.name).font(.system(size: 13, weight: .medium))
                                SignaturePreviewBox(html: Self.previewHTML(signature))
                                    .padding(.vertical, 2)
                                gmailNote(signature)
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

    /// Signatures follow Gmail by themselves; this says when they last did,
    /// and refreshes now on request.
    private var gmailStatus: some View {
        HStack(spacing: 6) {
            Text(gmailStatusText)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.signatures.gmailStatus")
            Button("Refresh from Gmail") {
                Task { await store.refreshGmailSignatures(accountId: accountId, force: true) }
            }
            .controlSize(.small)
            .disabled(store.signatureSync[accountId]?.status == .refreshing)
            .help("Read this account's signatures from Gmail now")
            .accessibilityIdentifier("settings.signatures.refresh")
        }
    }

    private var gmailStatusText: String {
        let lead = "The signature each address has in Gmail is added here by itself."
        guard let state = store.signatureSync[accountId] else { return lead }
        var parts = [lead]
        switch state.status {
        case .refreshing:
            parts.append("Reading Gmail…")
        case .done:
            parts.append("Checked \(state.lastAttempt.formatted(date: .omitted, time: .shortened)).")
        case .offline:
            parts.append("Gmail could not be reached; nothing changed here.")
        case .failed:
            parts.append("Gmail did not answer; nothing changed here. Signing in again may help.")
        }
        for (email, reason) in state.unusable.sorted(by: { $0.key < $1.key }) {
            parts.append("Gmail's signature for \(email) was not added: \(reason).")
        }
        return parts.joined(separator: " ")
    }

    /// Where a signature stands against Gmail.
    @ViewBuilder
    private func gmailNote(_ signature: SignatureRecord) -> some View {
        let state = store.signatureBook.gmailState(of: signature)
        let dropped = signature.gmailAddress.flatMap {
            store.signatureBook.gmailRecord(accountId: signature.accountId, email: $0)
        }.flatMap(Self.droppedNote)
        switch state {
        case .local:
            EmptyView()
        case .synced:
            Text(["From Gmail.", dropped].compactMap { $0 }.joined(separator: " "))
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
        case .differs:
            HStack(spacing: 6) {
                Text("Edited here; Gmail's version differs.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                Button("Use Gmail's") {
                    if let id = signature.id { perform { try store.useGmailSignature(id: id) } }
                }
                .controlSize(.mini)
                .accessibilityLabel("Use Gmail's version of \(signature.name)")
            }
        case .gone:
            Text("No longer on Gmail.")
                .font(.system(size: 10.5)).foregroundStyle(.orange)
        }
    }

    /// What a recipient sees: Gmail's look for an unchanged copy, else the
    /// text as compose renders it.
    static func previewHTML(_ signature: SignatureRecord) -> String {
        if let html = signature.html, let rich = SignatureHTML.cachedSanitize(html) {
            return ComposeSignature.htmlBlock(innerHTML: rich.html)
        }
        return ComposeQuote.authoredHeadHTML("-- \n" + signature.body)
    }

    /// What the conversion of Gmail's signature left out, in words.
    static func droppedNote(_ record: SignatureGmailRecord) -> String? {
        var left: [String] = []
        switch record.droppedImages {
        case 0: break
        case 1: left.append("its image")
        default: left.append("its \(record.droppedImages) images")
        }
        switch record.droppedLinks {
        case 0: break
        case 1: left.append("one link, kept as text")
        default: left.append("\(record.droppedLinks) links, kept as text")
        }
        guard !left.isEmpty else { return nil }
        return "Without " + left.joined(separator: " and ")
            + ": DreaMail signatures hold text, formatting and links only."
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
    /// The last rich paste (`SignaturePaste`): its text, and its look while
    /// the text is still that text.
    @State private var pastedBody: String?
    @State private var pastedLook: String?
    /// "Remove formatting" on the signature's own look.
    @State private var lookRemoved = false
    @State private var pasteNote: String?

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

    /// The look that will be sent: a pasted one, or the signature's own,
    /// only while the text is the one it came with. Editing the text drops
    /// it, as in compose, and the preview goes away.
    private var shownLook: String? {
        if let pastedBody {
            return text == pastedBody ? pastedLook : nil
        }
        guard !lookRemoved, text == signature.body else { return nil }
        return signature.html
    }

    /// A paste carrying HTML (or RTF): when it replaces the whole text, the
    /// text and the look come from it (`SignaturePaste`, off the main
    /// thread: a browser copy can be large). A paste into part of the text
    /// goes in as plain text; one with no readable text, or over the size
    /// bounds, puts the pasteboard's plain text in instead, and says so.
    private func pasteRich(_ pasteboard: NSPasteboard) -> Bool {
        let length = (text as NSString).length
        let replacesAll = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (selection.location == 0 && selection.length >= length)
        guard replacesAll else { return false }
        let html = ComposeBodyTextView.pastedHTML(from: pasteboard)
        let plain = pasteboard.string(forType: .string) ?? ""
        Task { @MainActor in
            var pasted: SignaturePaste.Result?
            if let html {
                pasted = await Task.detached(priority: .userInitiated) {
                    SignaturePaste.read(html: html)
                }.value
            }
            guard let pasted else {
                pastedBody = nil
                pastedLook = nil
                pasteNote = SignaturePaste.unreadableNote
                replaceText(with: plain)
                return
            }
            pastedBody = pasted.body
            pastedLook = pasted.html
            lookRemoved = false
            pasteNote = pasted.note
            replaceText(with: pasted.body)
        }
        return true
    }

    /// Through the text system, as compose's signature swap: one undo step.
    private func replaceText(with next: String) {
        let caret = (next as NSString).length
        if formatTarget.replaceText?(next, caret) != true { text = next }
        self.caret = caret
    }

    private func removeFormatting() {
        pastedLook = nil
        if pastedBody == nil { lookRemoved = true }
    }

    private func save() throws {
        let look = shownLook
        if let id = signature.id {
            let change: SignatureStore.LookChange
            if let look, pastedBody != nil {
                change = .set(look)
            } else if lookRemoved || (pastedBody != nil && look == nil && signature.html != nil) {
                // Removed, or replaced by a paste whose look was not kept.
                change = .remove
            } else {
                change = .keep
            }
            try store.updateSignature(id: id, name: name, body: text, look: change)
        } else {
            try store.addSignature(accountId: signature.accountId, name: name, body: text,
                                   html: look)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(signature.id == nil ? "New signature" : "Edit signature").font(.headline)
            TextField("Name (only you see it)", text: $name)
                .accessibilityIdentifier("settings.signatures.name")
            if let look = shownLook,
               let rich = SignatureHTML.cachedSanitize(look)?.html {
                VStack(alignment: .leading, spacing: 4) {
                    SignaturePreviewBox(html: ComposeSignature.htmlBlock(innerHTML: rich))
                        .accessibilityIdentifier("settings.signatures.look")
                    HStack(spacing: 8) {
                        Text("Sent like this. Editing the text below drops this formatting.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Remove formatting") { removeFormatting() }
                            .controlSize(.small)
                            .accessibilityIdentifier("settings.signatures.removeFormatting")
                    }
                }
            }
            ComposeBodyEditor(text: $text, isFocused: $focused, caretUTF16: $caret,
                              selection: $selection, formatTarget: formatTarget, fontSize: 13,
                              onRichPaste: { pasteRich($0) })
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .accessibilityIdentifier("settings.signatures.body")
            Text("Written like a message: **bold** (⌘B), *italic* (⌘I), [link](https://…), lists with “- ”. DreaMail adds the “-- ” line above it. You can paste a signature copied from Gmail; images are dropped.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let pasteNote {
                Text(pasteNote).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.signatures.pasteNote")
            }
            if signature.html != nil, pastedBody == nil, !lookRemoved {
                Text("This signature has Gmail's layout and colours. A change to its text here sends it as text, without them; “Use Gmail's” brings them back.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                        try save()
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

/// Settings → Accounts, one account's box: opens the Signatures pane on it.
struct ShowSignaturesButton: View {
    let accountId: String
    @AppStorage("settingsPane") private var pane: SettingsView.Pane = .accounts
    @AppStorage(SignatureSettings.accountKey) private var signaturesAccount = ""

    var body: some View {
        LabeledContent("Signatures") {
            Button("Show Signatures…") {
                signaturesAccount = accountId
                pane = .signatures
            }
            .accessibilityIdentifier("settings.account.signatures.\(accountId)")
            .accessibilityLabel("Show signatures of \(accountId)")
        }
    }
}
