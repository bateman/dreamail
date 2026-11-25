import Foundation
import GRDB

/// One named signature of an account. `body` is the compose editor's own
/// format (Markdown: bold, italic, links, lists), never HTML: the HTML a
/// recipient sees is rendered from it at send time by the same code as the
/// rest of the message (`ComposeQuote.authoredHeadHTML`), which escapes
/// every character it does not itself emit.
struct SignatureRecord: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "signature"
    var id: Int64?
    var accountId: String
    var name: String
    var body: String
    var createdAt: Date
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Which messages a default applies to. Forwards use the reply default, as
/// in Gmail ("For reply/forward use").
enum SignatureUse: String, Codable, CaseIterable, Sendable {
    case newMessage = "new"
    case reply = "reply"
}

/// The default signature of one sending address for one use. No row: the
/// address follows the account's primary address (an alias), or has no
/// default (the primary). A row with `signatureId == nil` means "No
/// signature" on purpose, which an alias needs to differ from the primary.
struct SignatureDefaultRecord: Codable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "signatureDefault"
    var accountId: String
    /// Lowercased.
    var sendAsEmail: String
    var use: String
    var signatureId: Int64?
}

/// What a sending address uses by default, as the Settings picker offers it.
enum SignatureDefaultChoice: Hashable, Sendable {
    /// No row: an alias follows the primary address; the primary has none.
    case followPrimary
    case none
    case signature(Int64)
}

/// The signatures and defaults of every account, as loaded from the
/// database. Pure, so the default rules are unit-tested.
struct SignatureBook: Equatable, Sendable {
    var signatures: [SignatureRecord] = []
    var defaults: [SignatureDefaultRecord] = []

    static let empty = SignatureBook()

    func signatures(for accountId: String) -> [SignatureRecord] {
        signatures.filter { $0.accountId.caseInsensitiveCompare(accountId) == .orderedSame }
    }

    func signature(id: Int64?) -> SignatureRecord? {
        guard let id else { return nil }
        return signatures.first { $0.id == id }
    }

    /// The stored choice of one address, without the alias fallback.
    func choice(use: SignatureUse, accountId: String, email: String) -> SignatureDefaultChoice {
        let key = email.lowercased()
        guard let row = defaults.first(where: {
            $0.accountId.caseInsensitiveCompare(accountId) == .orderedSame
                && $0.sendAsEmail == key && $0.use == use.rawValue
        }) else { return .followPrimary }
        return row.signatureId.map { .signature($0) } ?? .none
    }

    /// The signature a message gets when sent as `email` through
    /// `accountId`: the address's own default, else (an alias without a
    /// choice) the primary address's, else none.
    func defaultSignature(use: SignatureUse, accountId: String, email: String) -> SignatureRecord? {
        switch choice(use: use, accountId: accountId, email: email) {
        case .signature(let id):
            return signature(id: id).flatMap {
                $0.accountId.caseInsensitiveCompare(accountId) == .orderedSame ? $0 : nil
            }
        case .none:
            return nil
        case .followPrimary:
            guard email.caseInsensitiveCompare(accountId) != .orderedSame else { return nil }
            return defaultSignature(use: use, accountId: accountId, email: accountId)
        }
    }
}

/// The signature tables (migration v63) and their writes. Both cascade from
/// `account`, so removing an account removes its signatures; the database's
/// `secure_delete` and WAL scrub (`DeletionObserver`) then overwrite the
/// deleted rows (DEC-019). Signature text is never logged.
enum SignatureStore {
    /// Gmail's own limit for a signature.
    static let maxBodyLength = 10_000
    static let maxNameLength = 100

    static func createTables(_ db: Database) throws {
        try db.create(table: SignatureRecord.databaseTableName) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("accountId", .text).notNull().indexed()
                .references("account", onDelete: .cascade)
            t.column("name", .text).notNull()
            t.column("body", .text).notNull()
            t.column("createdAt", .datetime).notNull()
        }
        try db.create(table: SignatureDefaultRecord.databaseTableName) { t in
            t.column("accountId", .text).notNull()
                .references("account", onDelete: .cascade)
            t.column("sendAsEmail", .text).notNull()
            t.column("use", .text).notNull()
            // Deleting a signature drops the defaults that named it.
            t.column("signatureId", .integer)
                .references(SignatureRecord.databaseTableName, onDelete: .cascade)
            t.primaryKey(["accountId", "sendAsEmail", "use"])
        }
    }

    static func load(_ db: Database) throws -> SignatureBook {
        SignatureBook(
            signatures: try SignatureRecord
                .order(Column("accountId"), Column("name").collating(.nocase),
                       Column("id"))
                .fetchAll(db),
            defaults: try SignatureDefaultRecord.fetchAll(db))
    }

    /// The name and text as stored: trimmed, bounded, and with no line the
    /// compose body would take for the start of a signature
    /// (`ComposeSignature.delimiter`), so a signature is always one block.
    static func normalized(name: String, body: String) -> (name: String, body: String) {
        var cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if cleanName.isEmpty { cleanName = "Signature" }
        let cleanBody = ComposeSignature.normalizedBody(body)
        return (String(cleanName.prefix(maxNameLength)), String(cleanBody.prefix(maxBodyLength)))
    }

    @discardableResult
    static func insert(_ db: Database, accountId: String, name: String, body: String,
                       at date: Date = Date()) throws -> SignatureRecord {
        let clean = normalized(name: name, body: body)
        var row = SignatureRecord(id: nil, accountId: accountId, name: clean.name,
                                  body: clean.body, createdAt: date)
        try row.insert(db)
        return row
    }

    static func update(_ db: Database, id: Int64, name: String, body: String) throws {
        let clean = normalized(name: name, body: body)
        try db.execute(sql: "UPDATE signature SET name = ?, body = ? WHERE id = ?",
                       arguments: [clean.name, clean.body, id])
    }

    static func delete(_ db: Database, id: Int64) throws {
        _ = try SignatureRecord.deleteOne(db, key: id)
    }

    /// Sets one address's default. A signature of another account is refused.
    static func setDefault(_ db: Database, accountId: String, email: String, use: SignatureUse,
                           choice: SignatureDefaultChoice) throws {
        let key = email.lowercased()
        try db.execute(
            sql: "DELETE FROM signatureDefault WHERE accountId = ? AND sendAsEmail = ? AND use = ?",
            arguments: [accountId, key, use.rawValue])
        switch choice {
        case .followPrimary:
            return
        case .none:
            try SignatureDefaultRecord(accountId: accountId, sendAsEmail: key, use: use.rawValue,
                                       signatureId: nil).insert(db)
        case .signature(let id):
            guard let owner = try String.fetchOne(
                db, sql: "SELECT accountId FROM signature WHERE id = ?", arguments: [id]),
                  owner.caseInsensitiveCompare(accountId) == .orderedSame else { return }
            try SignatureDefaultRecord(accountId: accountId, sendAsEmail: key, use: use.rawValue,
                                       signatureId: id).insert(db)
        }
    }

    /// The account is being removed: its signatures and defaults go. They
    /// also cascade with the account row; deleted by name so the purge does
    /// not depend on the foreign key alone.
    static func forget(_ db: Database, accountId: String) throws {
        try db.execute(sql: "DELETE FROM signatureDefault WHERE accountId = ?", arguments: [accountId])
        try db.execute(sql: "DELETE FROM signature WHERE accountId = ?", arguments: [accountId])
    }
}
