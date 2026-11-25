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
    @AppStorage(PGPCenter.settingsAccountKey) private var accountId = ""
    @State private var keys: [PGPKeySummary] = []
    @State private var loadError: String?
    @State private var importing: ImportKind?
    @State private var importResult: String?
    @State private var deleting: PGPKeySummary?
    @State private var expanded: Set<PGPKeyReference> = []
    /// A file read and inspected, waiting for the user to confirm.
    @State private var reviewing: PendingImport?

    struct PendingImport: Identifiable {
        let id = UUID()
        let accountId: String
        let data: Data
        let kind: ImportKind
        let keys: [PGPKeySummary]
        let claimedElsewhere: [PGPKeyReference: [String]]
    }

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
                        Text("A secret key stays under its own passphrase. DreaMail asks for it when a message needs it and keeps it in memory only, until it quits, the screen locks or the Mac sleeps.")
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
        .sheet(item: $reviewing) { pending in
            PGPImportReviewSheet(pending: pending,
                                 onImport: {
                                     reviewing = nil
                                     Task { await confirmImport(pending) }
                                 },
                                 onCancel: { reviewing = nil })
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
                    if key.userIDs.isEmpty {
                        Text("No user ID").font(.system(size: 13, weight: .medium))
                    }
                    // Every user ID: each one is an address this key can
                    // sign for.
                    ForEach(key.userIDs, id: \.self) { userID in
                        Text(PGPDisplay.safeUserID(userID)).font(.system(size: 13, weight: .medium))
                    }
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
                    ForEach(key.userIDs, id: \.self) { Text(PGPDisplay.safeUserID($0)).font(.system(size: 12)) }
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

    /// Reads at most one byte more than the limit, whatever the file says
    /// its size is, then shows what it holds; nothing is stored until the
    /// user confirms.
    private func importFile(_ url: URL, kind: ImportKind) async {
        let account = accountId
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            importResult = "That file can’t be read."
            return
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: PGPCenter.maxKeyFileBytes + 1), !data.isEmpty else {
            importResult = "That file can’t be read."
            return
        }
        do {
            let keys = try await store.openPGP.inspect(data, accountId: account)
            // Fails closed: without the stored keys the clash check cannot
            // run, so no sheet opens.
            let stored = try await store.openPGP.keys(accountId: account)
            reviewing = PendingImport(accountId: account, data: data, kind: kind, keys: keys,
                                      claimedElsewhere: PGPDisplay.addressesClaimedElsewhere(keys, stored: stored))
            importResult = nil
        } catch {
            importResult = Self.message(error)
        }
    }

    private func confirmImport(_ pending: PendingImport) async {
        do {
            let imported = try await store.openPGP.importKeys(pending.data, accountId: pending.accountId,
                                                              secret: pending.kind == .secretKeys)
            let notValid = imported.filter { $0.validity == .revoked || $0.validity == .expired }.count
            importResult = (imported.count == 1 ? "Imported 1 key." : "Imported \(imported.count) keys.")
                + (notValid > 0 ? " Revoked or expired: \(notValid). A stored revoked or expired copy is kept; delete the key first to replace it." : "")
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
        case .malformed?, .unsupported?: return "That file holds no key DreaMail can use."
        case .tooLarge?: return "That file is too large (at most 1 MB and 50 keys)."
        case .unavailable?: return "This version of DreaMail has no OpenPGP support."
        case .passphraseRequired?, .notIntegrityProtected?: return "That didn’t work."
        case .keysUnavailable?: return "Your keys can’t be read right now. Unlock your Mac and try again."
        case nil: return error.localizedDescription
        }
    }
}

/// What a key file holds, before anything is stored: every key with its
/// fingerprint, all its user IDs (none verified) and its validity, and the
/// addresses another stored key already claims.
private struct PGPImportReviewSheet: View {
    let pending: PGPKeySettings.PendingImport
    let onImport: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(pending.kind == .secretKeys ? "Import your secret key?" : "Import these keys?")
                .font(.headline)
            Text("A key can name any address. Import it only if you got it from its owner, and compare the fingerprint with them.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(pending.keys, id: \.key) { key in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(PGPDisplay.grouped(key.key.fingerprint))
                                .font(.system(size: 12).monospaced())
                                .textSelection(.enabled)
                            ForEach(key.userIDs, id: \.self) { Text(PGPDisplay.safeUserID($0)).font(.system(size: 12)) }
                            if key.userIDs.isEmpty {
                                Text("No user ID").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Text(PGPKeySettings.validityText(key))
                                .font(.system(size: 11))
                                .foregroundStyle(key.validity == .valid ? Color.secondary : Color.orange)
                            if let clash = pending.claimedElsewhere[key.key] {
                                Label("Another of your keys already claims \(clash.joined(separator: ", ")).",
                                      systemImage: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.orange)
                            }
                        }
                        .accessibilityIdentifier("settings.openPGP.review.key")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Import", action: onImport)
                    .accessibilityIdentifier("settings.openPGP.review.import")
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
