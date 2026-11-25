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
            reason: "MishMail cannot save changes right now. Try again after a restart.")
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

    /// The Gmail signature of each send-as address of the account, read
    /// from Gmail now (gmail.settings.basic, already granted for send-as).
    /// Addresses without one are left out.
    func gmailSignatures(accountId: String) async throws -> [(email: String, html: String)] {
        guard !demoMode else { return [] }
        return try await client(for: accountId).listSendAs().compactMap { row in
            guard let html = row.signature,
                  !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return (row.sendAsEmail, html)
        }
    }

    /// Copies one Gmail signature into MishMail as a new signature of the
    /// account. Returns what the conversion left out; throws with the
    /// reason when nothing was saved.
    func importGmailSignature(accountId: String, email: String,
                              html: String) throws -> SignatureImport.Result {
        let result = SignatureImport.markdown(fromGmailHTML: html)
        if result.tooLarge {
            throw SignatureWriteError(reason: "That signature is too large to import.")
        }
        guard !result.body.isEmpty else {
            throw SignatureWriteError(reason: "That signature has no text MishMail can keep.")
        }
        try addSignature(accountId: accountId, name: "Gmail – \(email)", body: result.body)
        return result
    }
}
