import Foundation
import GRDB

/// Signatures per account (Settings → Signatures, and the compose
/// signature menu). Stored in the encrypted database (`SignatureStore`);
/// signature text is never logged.
extension MailStore {
    func reloadSignatures() {
        signatureBook = (try? db.read { try SignatureStore.load($0) }) ?? .empty
    }

    @discardableResult
    func addSignature(accountId: String, name: String, body: String) -> SignatureRecord? {
        guard cacheAcceptsWrites() else { return nil }
        let row = try? db.write { db in
            try SignatureStore.insert(db, accountId: accountId, name: name, body: body)
        }
        reloadSignatures()
        return row
    }

    func updateSignature(id: Int64, name: String, body: String) {
        guard cacheAcceptsWrites() else { return }
        try? db.write { db in try SignatureStore.update(db, id: id, name: name, body: body) }
        reloadSignatures()
    }

    func deleteSignature(id: Int64) {
        guard cacheAcceptsWrites() else { return }
        try? db.write { db in try SignatureStore.delete(db, id: id) }
        reloadSignatures()
    }

    func setSignatureDefault(accountId: String, email: String, use: SignatureUse,
                             choice: SignatureDefaultChoice) {
        guard cacheAcceptsWrites() else { return }
        try? db.write { db in
            try SignatureStore.setDefault(db, accountId: accountId, email: email,
                                          use: use, choice: choice)
        }
        reloadSignatures()
    }

    /// The signature a compose window inserts for this sender.
    func defaultSignature(use: SignatureUse, accountId: String, email: String) -> SignatureRecord? {
        signatureBook.defaultSignature(use: use, accountId: accountId, email: email)
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
    /// account. Returns how many images were dropped (the compose editor
    /// has none), or nil when nothing was saved.
    func importGmailSignature(accountId: String, email: String, html: String) -> Int? {
        let result = SignatureImport.markdown(fromGmailHTML: html)
        guard !result.body.isEmpty,
              addSignature(accountId: accountId, name: "Gmail – \(email)", body: result.body) != nil
        else { return nil }
        return result.droppedImages
    }
}
