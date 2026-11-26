import Foundation
import GRDB

/// One named signature of an account. `body` is the compose editor's own
/// format (Markdown: bold, italic, links, lists): the HTML a recipient sees
/// is rendered from it at send time by the same code as the rest of the
/// message (`ComposeQuote.authoredHeadHTML`), which escapes every character
/// it does not itself emit. A copy of a Gmail signature also keeps Gmail's
/// look in `html` (rebuilt from an allow-list by `SignatureHTML`), which is
/// sent instead while the body carries that signature unchanged.
struct SignatureRecord: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "signature"
    var id: Int64?
    var accountId: String
    var name: String
    var body: String
    var createdAt: Date
    /// The send-as address (lowercased) whose Gmail signature this is a
    /// copy of (v67); nil for a signature made in DreaMail.
    var gmailAddress: String? = nil
    /// The text was changed here after it came from Gmail: a later change
    /// on Gmail is shown, not applied (`SignatureStore.applyGmail`).
    var editedHere = false
    /// The look of a Gmail copy: Gmail's HTML rebuilt by `SignatureHTML`,
    /// sent in place of the rendered `body` while the body's signature is
    /// this one word for word. Nil for a signature made or edited here.
    var html: String? = nil
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// The last signature Gmail returned for one send-as address, converted
/// (v67). What a copy is compared with, and what "Use Gmail's" restores.
/// Cascades from the account, like the signatures.
struct SignatureGmailRecord: Codable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "signatureGmail"
    var accountId: String
    /// Lowercased.
    var sendAsEmail: String
    var body: String
    /// `SignatureHTML`'s rebuild of Gmail's HTML; nil when none was kept.
    var html: String?
    /// What the conversion left out, to say so in Settings.
    var droppedImages: Int
    var droppedLinks: Int
}

/// One address's signature as read from Gmail.
enum GmailSignature: Equatable, Sendable {
    /// Converted text (the editor's Markdown) and the look (rebuilt HTML),
    /// ready to store.
    case text(String, html: String? = nil, droppedImages: Int = 0, droppedLinks: Int = 0)
    /// Gmail has one, but it cannot be kept (too large, no text left, or a
    /// line compose would take for quoted mail): what is here stays.
    case unusable(reason: String)

    /// Gmail's HTML for an address, converted with `SignatureImport`. Nil
    /// when the address has no signature on Gmail.
    static func from(html: String?) -> GmailSignature? {
        guard let html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let result = SignatureImport.markdown(fromGmailHTML: html)
        if result.tooLarge { return .unusable(reason: "too large") }
        guard !result.body.isEmpty else { return .unusable(reason: "no text DreaMail can keep") }
        if ComposeSignature.saveProblem(result.body, maxLength: SignatureStore.maxBodyLength) != nil {
            return .unusable(reason: "a line DreaMail cannot keep")
        }
        return .text(result.body, html: SignatureHTML.sanitize(html)?.html,
                     droppedImages: result.droppedImages, droppedLinks: result.droppedLinks)
    }
}

/// Where a signature stands against Gmail, as Settings shows it.
enum SignatureGmailState: Equatable, Sendable {
    /// Made in DreaMail.
    case local
    /// The same as Gmail's.
    case synced
    /// Edited here; Gmail's version is `gmailBody`.
    case differs(gmailBody: String)
    /// Its address has no signature on Gmail any more.
    case gone
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
    var gmail: [SignatureGmailRecord] = []

    static let empty = SignatureBook()

    func signatures(for accountId: String) -> [SignatureRecord] {
        signatures.filter { $0.accountId.caseInsensitiveCompare(accountId) == .orderedSame }
    }

    func signature(id: Int64?) -> SignatureRecord? {
        guard let id else { return nil }
        return signatures.first { $0.id == id }
    }

    /// Gmail's last signature for `email` of `accountId`.
    func gmailRecord(accountId: String, email: String) -> SignatureGmailRecord? {
        let key = email.lowercased()
        return gmail.first {
            $0.accountId.caseInsensitiveCompare(accountId) == .orderedSame && $0.sendAsEmail == key
        }
    }

    func gmailState(of signature: SignatureRecord) -> SignatureGmailState {
        guard let address = signature.gmailAddress else { return .local }
        guard let remote = gmailRecord(accountId: signature.accountId, email: address) else {
            return .gone
        }
        if signature.editedHere, remote.body != signature.body {
            return .differs(gmailBody: remote.body)
        }
        return .synced
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
            // Deleting a signature turns the defaults that named it into
            // "No signature" (NULL): an alias must not start following the
            // primary's signature because its own was deleted.
            t.column("signatureId", .integer)
                .references(SignatureRecord.databaseTableName, onDelete: .setNull)
            t.primaryKey(["accountId", "sendAsEmail", "use"])
        }
    }

    static func load(_ db: Database) throws -> SignatureBook {
        SignatureBook(
            signatures: try SignatureRecord
                .order(Column("accountId"), Column("name").collating(.nocase),
                       Column("id"))
                .fetchAll(db),
            defaults: try SignatureDefaultRecord.fetchAll(db),
            gmail: try SignatureGmailRecord.fetchAll(db))
    }

    /// v67: the link of a signature to the Gmail address it was copied
    /// from, and Gmail's last version of each address's signature.
    static func addGmailSync(_ db: Database) throws {
        try db.alter(table: SignatureRecord.databaseTableName) { t in
            t.add(column: "gmailAddress", .text)
            t.add(column: "editedHere", .boolean).notNull().defaults(to: false)
            t.add(column: "html", .text)
        }
        try db.create(table: SignatureGmailRecord.databaseTableName) { t in
            t.column("accountId", .text).notNull()
                .references("account", onDelete: .cascade)
            t.column("sendAsEmail", .text).notNull()
            t.column("body", .text).notNull()
            t.column("html", .text)
            t.column("droppedImages", .integer).notNull().defaults(to: 0)
            t.column("droppedLinks", .integer).notNull().defaults(to: 0)
            t.primaryKey(["accountId", "sendAsEmail"])
        }
    }

    /// A signature that cannot be saved, with the reason to show.
    struct InvalidSignature: LocalizedError, Equatable {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// The name and text as stored: trimmed, and with no line the compose
    /// body would take for the start of a signature
    /// (`ComposeSignature.delimiter`), so a signature is always one block.
    /// Refused, never cut, when the text is empty, too long, or has a line
    /// compose would take for quoted mail (`ComposeSignature.saveProblem`).
    static func normalized(name: String, body: String) throws -> (name: String, body: String) {
        if let problem = ComposeSignature.saveProblem(body, maxLength: maxBodyLength) {
            throw InvalidSignature(reason: problem)
        }
        var cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if cleanName.isEmpty { cleanName = "Signature" }
        return (String(cleanName.prefix(maxNameLength)), ComposeSignature.normalizedBody(body))
    }

    /// `html`: the look of a pasted signature (`SignaturePaste`), sanitised
    /// again here, at the sink. The signature stays local: not a Gmail copy.
    @discardableResult
    static func insert(_ db: Database, accountId: String, name: String, body: String,
                       html: String? = nil, at date: Date = Date()) throws -> SignatureRecord {
        let clean = try normalized(name: name, body: body)
        var row = SignatureRecord(id: nil, accountId: accountId, name: clean.name,
                                  body: clean.body, createdAt: date)
        row.html = html.flatMap { SignatureHTML.sanitize($0)?.html }
        try row.insert(db)
        return row
    }

    /// What an edit does to a signature's look.
    enum LookChange: Equatable {
        /// The look follows the text (dropped when the text changes).
        case keep
        /// A pasted look (`SignaturePaste`), sanitised again here.
        case set(String)
        /// "Remove formatting".
        case remove
    }

    /// A copy of a Gmail signature counts as edited here while its text
    /// differs from Gmail's (a rename does not count).
    static func update(_ db: Database, id: Int64, name: String, body: String,
                       look: LookChange = .keep) throws {
        let clean = try normalized(name: name, body: body)
        guard var row = try SignatureRecord.fetchOne(db, key: id) else { return }
        if look != .keep {
            // A look set or removed here is the user's: a Gmail copy then
            // counts as edited here, and the import shows Gmail's changes
            // instead of applying them.
            if case .set(let html) = look {
                row.html = SignatureHTML.sanitize(html)?.html
            } else {
                row.html = nil
            }
            if row.gmailAddress != nil { row.editedHere = true }
        } else if let address = row.gmailAddress, clean.body != row.body {
            let remote = try SignatureGmailRecord.fetchOne(
                db, key: ["accountId": row.accountId, "sendAsEmail": address])
            row.editedHere = remote?.body != clean.body
            // The look follows the text: Gmail's while it is Gmail's text.
            row.html = row.editedHere ? nil : remote?.html
        } else if clean.body != row.body {
            row.html = nil
        }
        row.name = clean.name
        row.body = clean.body
        try row.update(db)
    }

    /// "Use Gmail's": the copy takes Gmail's text again and follows it.
    static func useGmailVersion(_ db: Database, id: Int64) throws {
        guard var row = try SignatureRecord.fetchOne(db, key: id),
              let address = row.gmailAddress,
              let remote = try SignatureGmailRecord.fetchOne(
                db, key: ["accountId": row.accountId, "sendAsEmail": address]) else { return }
        row.body = remote.body
        row.html = remote.html
        row.editedHere = false
        try row.update(db)
    }

    /// What a refresh from Gmail changed.
    struct GmailOutcome: Equatable {
        var added = 0
        var updated = 0
    }

    /// Applies what Gmail returned for every send-as address of the account
    /// (`gmail`: lowercased address → its signature; an address without one
    /// is left out). The rules:
    /// - New on Gmail (or changed there while no copy is here): a copy is
    ///   added, named after the address. Only the first time an address's
    ///   signature is seen, an existing signature with the same text (a #61
    ///   manual import) becomes the copy instead, and the copy becomes the
    ///   address's default for new messages unless it has one. Gmail's API
    ///   gives the new-mail signature only: the reply default is left alone.
    /// - Changed on Gmail: the copy follows, unless it was edited here; then
    ///   Settings shows that Gmail's differs.
    /// - Gone from Gmail: nothing is deleted; the copy stays, shown as no
    ///   longer on Gmail.
    /// - A copy deleted here is not added again until Gmail's text changes.
    /// - An unusable signature (too large, no text) changes nothing.
    @discardableResult
    static func applyGmail(_ db: Database, accountId: String,
                           gmail: [String: GmailSignature]) throws -> GmailOutcome {
        var outcome = GmailOutcome()
        let previous = try SignatureGmailRecord
            .filter(Column("accountId") == accountId).fetchAll(db)
        var rows = try SignatureRecord.filter(Column("accountId") == accountId)
            .order(Column("id")).fetchAll(db)
        for (rawEmail, signature) in gmail.sorted(by: { $0.key < $1.key }) {
            let email = rawEmail.lowercased()
            guard case .text(let body, let html, let images, let links) = signature else { continue }
            let prev = previous.first { $0.sendAsEmail == email }
            if let i = rows.firstIndex(where: { $0.gmailAddress == email }) {
                if !rows[i].editedHere, rows[i].body != body || rows[i].html != html {
                    rows[i].body = body
                    rows[i].html = html
                    try rows[i].update(db)
                    outcome.updated += 1
                } else if rows[i].editedHere, rows[i].body == body {
                    rows[i].editedHere = false
                    rows[i].html = html
                    try rows[i].update(db)
                }
            } else if prev?.body != body || prev?.html != html {
                if prev == nil,
                   let i = rows.firstIndex(where: { $0.gmailAddress == nil && $0.body == body }) {
                    rows[i].gmailAddress = email
                    rows[i].html = html
                    try rows[i].update(db)
                } else {
                    var row = SignatureRecord(
                        id: nil, accountId: accountId,
                        name: String(email.prefix(maxNameLength)), body: body,
                        createdAt: Date(), gmailAddress: email, html: html)
                    try row.insert(db)
                    rows.append(row)
                    outcome.added += 1
                    let hasDefault = try SignatureDefaultRecord
                        .filter(Column("accountId") == accountId && Column("sendAsEmail") == email
                                && Column("use") == SignatureUse.newMessage.rawValue)
                        .fetchCount(db) > 0
                    if prev == nil, !hasDefault, let id = row.id {
                        try setDefault(db, accountId: accountId, email: email, use: .newMessage,
                                       choice: .signature(id))
                    }
                }
            }
            try SignatureGmailRecord(accountId: accountId, sendAsEmail: email, body: body,
                                     html: html, droppedImages: images,
                                     droppedLinks: links).save(db)
        }
        // Gone from Gmail: no signature for the address any more.
        for prev in previous where gmail.keys.first(where: {
            $0.lowercased() == prev.sendAsEmail
        }) == nil {
            try SignatureGmailRecord.deleteOne(
                db, key: ["accountId": accountId, "sendAsEmail": prev.sendAsEmail])
        }
        return outcome
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
        try db.execute(sql: "DELETE FROM signatureGmail WHERE accountId = ?", arguments: [accountId])
        try db.execute(sql: "DELETE FROM signature WHERE accountId = ?", arguments: [accountId])
    }
}
