import Foundation
import GRDB

/// Signatures per account (Settings → Signatures, and the compose
/// signature menu). Stored in the encrypted database (`SignatureStore`);
/// signature text is never logged.
extension MailStore {
    /// UserDefaults key of the account the Signatures pane shows.
    static let signatureSettingsAccountKey = "settingsSignaturesAccount"

    /// Why a signature change was not saved.
    struct SignatureWriteError: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
        static let readOnly = SignatureWriteError(
            reason: "DreaMail cannot save changes right now. Try again after a restart.")
        static let failed = SignatureWriteError(reason: "The change could not be saved.")
    }

    func reloadSignatures() {
        signatureBook = (try? db.read { try SignatureStore.load($0) }) ?? .empty
    }

    /// Runs one signature write; reloads either way, and turns a failure
    /// into a message (an invalid text keeps its own reason).
    private func writeSignatures<T>(_ work: (Database) throws -> T) throws -> T {
        guard cacheAcceptsWrites(silent: true) else { throw SignatureWriteError.readOnly }
        defer { reloadSignatures() }
        do {
            return try db.write { try work($0) }
        } catch let invalid as SignatureStore.InvalidSignature {
            throw invalid
        } catch {
            throw SignatureWriteError.failed
        }
    }

    @discardableResult
    func addSignature(accountId: String, name: String, body: String) throws -> SignatureRecord {
        try writeSignatures { db in
            try SignatureStore.insert(db, accountId: accountId, name: name, body: body)
        }
    }

    func updateSignature(id: Int64, name: String, body: String) throws {
        try writeSignatures { db in try SignatureStore.update(db, id: id, name: name, body: body) }
    }

    func deleteSignature(id: Int64) throws {
        try writeSignatures { db in try SignatureStore.delete(db, id: id) }
    }

    func setSignatureDefault(accountId: String, email: String, use: SignatureUse,
                             choice: SignatureDefaultChoice) throws {
        try writeSignatures { db in
            try SignatureStore.setDefault(db, accountId: accountId, email: email,
                                          use: use, choice: choice)
        }
    }

    /// The signature a compose window inserts for this sender.
    func defaultSignature(use: SignatureUse, accountId: String, email: String) -> SignatureRecord? {
        signatureBook.defaultSignature(use: use, accountId: accountId, email: email)
    }

    /// The Signatures pane must not reopen on a removed account.
    func forgetSignatureSettingsAccount(_ accountId: String) {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: Self.signatureSettingsAccountKey)?
            .caseInsensitiveCompare(accountId) == .orderedSame {
            defaults.removeObject(forKey: Self.signatureSettingsAccountKey)
        }
    }

    /// "Use Gmail's": a copy edited here takes Gmail's text again.
    func useGmailSignature(id: Int64) throws {
        try writeSignatures { db in try SignatureStore.useGmailVersion(db, id: id) }
    }

    /// The signature of each send-as address of the account, read from
    /// Gmail now (`users.settings.sendAs`, under gmail.settings.basic, the
    /// scope send-as already uses). The demo account reads a fixed one.
    /// An address without a signature is left out.
    func gmailSignatures(accountId: String) async throws -> [String: GmailSignature] {
        let rows: [(String, String?)]
        if demoMode {
            rows = DemoSeed.gmailSignatures.filter {
                $0.key.caseInsensitiveCompare(accountId) == .orderedSame
            }.map { ($0.key, Optional($0.value)) }
        } else {
            rows = try await client(for: accountId).listSendAs().map { ($0.sendAsEmail, $0.signature) }
        }
        // Untrusted HTML is parsed off the main actor: a hostile signature
        // can slow a refresh, never the app.
        return await Task.detached(priority: .utility) {
            var out: [String: GmailSignature] = [:]
            for (email, html) in rows {
                if let signature = GmailSignature.from(html: html) { out[email.lowercased()] = signature }
            }
            return out
        }.value
    }

    /// Throttled refresh (Settings shown, compose opened).
    func refreshGmailSignaturesIfDue(accountId: String) {
        guard SignatureSyncPolicy.isDue(signatureSync[accountId], force: false, now: Date())
        else { return }
        Task { await refreshGmailSignatures(accountId: accountId, force: false) }
    }

    /// Reads the account's signatures from Gmail and applies them
    /// (`SignatureStore.applyGmail`). Offline or on an error, what is here
    /// stays and the state says so; nothing is shown outside Settings.
    func refreshGmailSignatures(accountId: String, force: Bool) async {
        guard !isShuttingDown, !accountId.isEmpty,
              SignatureSyncPolicy.isDue(signatureSync[accountId], force: force, now: Date())
        else { return }
        let previous = signatureSync[accountId]
        signatureSync[accountId] = SignatureSyncState(
            status: .refreshing, lastAttempt: Date(),
            unusable: previous?.unusable ?? [:])
        let result: Result<[String: GmailSignature], Error>
        do {
            result = .success(try await gmailSignatures(accountId: accountId))
        } catch {
            result = .failure(error)
        }
        // Removed while Gmail answered: nothing of it is written back.
        guard accounts.contains(where: { $0.id == accountId }) else {
            signatureSync[accountId] = nil
            return
        }
        var state = signatureSync[accountId] ?? SignatureSyncState(status: .refreshing,
                                                                     lastAttempt: Date())
        switch result {
        case .success(let gmail):
            do {
                _ = try writeSignatures { db in
                    try SignatureStore.applyGmail(db, accountId: accountId, gmail: gmail)
                }
                state.status = .done
                state.unusable = gmail.compactMapValues { (signature: GmailSignature) -> String? in
                    if case .unusable(let reason) = signature { return reason }
                    return nil
                }
            } catch {
                state.status = .failed
            }
        case .failure(let error):
            state.status = RemoteFailureKind.classify(error) == .offline ? .offline : .failed
        }
        signatureSync[accountId] = state
    }
}
