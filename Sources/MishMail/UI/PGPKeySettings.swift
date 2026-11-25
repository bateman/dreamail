import SwiftUI
import UniformTypeIdentifiers

/// Settings → OpenPGP keys (step 4B, scope B): each account's keys. Import
/// public keys (your correspondents') and your own secret keys from a file,
/// see each key's fingerprint, user IDs and expiry, delete it. Shown only
/// when the build turns OpenPGP on.
///
/// Public keys are kept in the encrypted database, secret keys in the
/// Keychain on this Mac only. Deleting a key removes both, at once.
struct PGPKeySettings: View {
    @Environment(MailStore.self) private var store
    @AppStorage("settings.openPGP.account") private var accountId = ""
    @State private var keys: [PGPKeySummary] = []
    @State private var loadError: String?
    @State private var importing: ImportKind?
    @State private var importResult: String?
    @State private var deleting: PGPKeySummary?
    @State private var expanded: Set<PGPKeyReference> = []

    enum ImportKind: Identifiable {
        case publicKeys, secretKeys
        var id: Self { self }
    }

    var body: some View {
        PaneScaffold(title: "OpenPGP keys",
                     subtitle: "Used to check signed mail and to read encrypted mail. Each account has its own keys.") {
            if store.accounts.isEmpty {
                Text("Add a Google account first.")
                    .foregroundStyle(.secondary)
                    .padding(20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if store.accounts.count > 1 {
                            Picker("Account", selection: $accountId) {
                                ForEach(store.accounts) { account in
                                    Text(account.id).tag(account.id)
                                }
                            }
                            .frame(maxWidth: 360)
                            .accessibilityIdentifier("settings.openPGP.account")
                        }
                        HStack {
                            Button("Import public key…") { importing = .publicKeys }
                                .accessibilityIdentifier("settings.openPGP.importPublic")
                            Button("Import your secret key…") { importing = .secretKeys }
                                .accessibilityIdentifier("settings.openPGP.importSecret")
                        }
                        Text("A secret key stays under its own passphrase. MishMail asks for it when a message needs it and keeps it only until it quits.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        if let importResult {
                            Text(importResult).font(.system(size: 11)).foregroundStyle(.secondary)
                                .accessibilityIdentifier("settings.openPGP.importResult")
                        }
                        if let loadError {
                            Text(loadError).font(.system(size: 11)).foregroundStyle(.red)
                        }
                        keyList
                    }
                    .padding(20)
                }
            }
        }
        .onAppear(perform: validateAccount)
        .onChange(of: store.accounts.map(\.id)) { validateAccount() }
        .task(id: "\(accountId)|\(store.openPGP.keysRevision)") { await reload() }
        .fileImporter(isPresented: Binding(get: { importing != nil },
                                           set: { if !$0 { importing = nil } }),
                      allowedContentTypes: [.data, .plainText]) { result in
            let kind = importing ?? .publicKeys
            importing = nil
            if case .success(let url) = result { Task { await importFile(url, kind: kind) } }
        }
        .confirmationDialog("Delete this key?",
                            isPresented: Binding(get: { deleting != nil },
                                                 set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { key in
            Button("Delete", role: .destructive) { Task { await delete(key) } }
            Button("Cancel", role: .cancel) {}
        } message: { key in
            Text(key.hasSecretKey
                 ? "The key and its secret half are removed from this Mac. Mail encrypted to it can no longer be read here."
                 : "Signatures by this key will read “Can’t verify” again.")
        }
    }

    @ViewBuilder
    private var keyList: some View {
        if keys.isEmpty {
            Text("No keys for this account yet.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.openPGP.empty")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(keys, id: \.key) { key in
                    keyRow(key)
                    Divider()
                }
            }
            .accessibilityIdentifier("settings.openPGP.keys")
        }
    }

    private func keyRow(_ key: PGPKeySummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Button {
                    if expanded.contains(key.key) { expanded.remove(key.key) } else { expanded.insert(key.key) }
                } label: {
                    Image(systemName: expanded.contains(key.key) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Details")
                VStack(alignment: .leading, spacing: 2) {
                    Text(key.userIDs.first ?? "No user ID").font(.system(size: 13, weight: .medium))
                    Text(PGPDisplay.grouped(key.key.fingerprint))
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                if key.hasSecretKey {
                    Text("Your key").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(Self.validityText(key))
                    .font(.system(size: 11))
                    .foregroundStyle(key.validity == .valid ? Color.secondary : Color.orange)
                Button {
                    deleting = key
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Delete key \(PGPDisplay.grouped(key.key.fingerprint))")
            }
            if expanded.contains(key.key) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(key.userIDs, id: \.self) { Text($0).font(.system(size: 12)) }
                    Text("User IDs are stated by the key; nobody has verified them. Compare the fingerprint with its owner.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if let created = key.created {
                        Text("Created \(created.formatted(date: .abbreviated, time: .omitted))")
                            .font(.system(size: 11))
                    }
                    Text(key.expires.map { "Expires \($0.formatted(date: .abbreviated, time: .omitted))" }
                         ?? "Does not expire")
                        .font(.system(size: 11))
                }
                .padding(.leading, 22)
            }
        }
        .padding(.vertical, 8)
    }

    static func validityText(_ key: PGPKeySummary) -> String {
        switch key.validity {
        case .valid: return "Valid"
        case .expired: return "Expired"
        case .revoked: return "Revoked"
        case .broken: return "Broken"
        case .unsupported: return "Unsupported"
        }
    }

    private func validateAccount() {
        guard !store.accounts.contains(where: { $0.id == accountId }) else { return }
        accountId = store.activeAccountId.flatMap { active in
            store.accounts.first { $0.id == active }?.id
        } ?? store.accounts.first?.id ?? ""
    }

    private func reload() async {
        guard !accountId.isEmpty else { keys = []; return }
        do {
            keys = try await store.openPGP.keys(accountId: accountId)
            loadError = nil
        } catch {
            keys = []
            loadError = Self.message(error)
        }
    }

    private func importFile(_ url: URL, kind: ImportKind) async {
        let account = accountId
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= RPGPEngine.maxInputBytes, let data = try? Data(contentsOf: url) else {
            importResult = "That file can’t be read as an OpenPGP key."
            return
        }
        do {
            let imported = try await store.openPGP.importKeys(data, accountId: account,
                                                              secret: kind == .secretKeys)
            importResult = imported.count == 1 ? "Imported 1 key." : "Imported \(imported.count) keys."
        } catch {
            importResult = Self.message(error)
        }
    }

    private func delete(_ key: PGPKeySummary) async {
        do {
            try await store.openPGP.delete(key.key, accountId: accountId)
            loadError = nil
        } catch {
            loadError = Self.message(error)
        }
    }

    static func message(_ error: Error) -> String {
        switch error as? PGPEngineError {
        case .noSecretKey?: return "No usable secret key in that file (it may be expired, revoked or public only)."
        case .malformed?, .unsupported?: return "That file holds no key MishMail can use."
        case .tooLarge?: return "That file is too large."
        case .unavailable?: return "This version of MishMail has no OpenPGP support."
        case .passphraseRequired?, .notIntegrityProtected?: return "That didn’t work."
        case nil: return error.localizedDescription
        }
    }
}
