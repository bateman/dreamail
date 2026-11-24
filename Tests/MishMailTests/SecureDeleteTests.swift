import XCTest
import GRDB

/// "Deleted means gone": once a row is deleted and the maintenance that
/// follows a deletion has run, its content is in neither the database file
/// nor the write-ahead log.
///
/// The byte scans run on unkeyed files opened with the app's own connection
/// configuration (`AppDatabase.connectionConfiguration`): under SQLCipher a
/// scan of ciphertext would prove nothing, and an unkeyed file is where a
/// marker that survived a delete is visible. Each scan is preceded by a
/// positive check that the same scan does find live content.
final class SecureDeleteTests: XCTestCase {
    private let key = String(repeating: "cd", count: 32)
    private var dir: URL!
    private var path: String { dir.appendingPathComponent("mail.sqlite").path }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mishmail-securedelete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Helpers

    /// A unique lowercase token (FTS5's tokenizer lowercases and splits on
    /// punctuation, so the marker must be one plain alphanumeric word).
    private func marker(_ prefix: String) -> String {
        prefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// An unkeyed, writable, migrated pool with the app's per-connection
    /// configuration.
    private func openUnkeyedPool() throws -> DatabasePool {
        let pool = try DatabasePool(
            path: path,
            configuration: AppDatabase.connectionConfiguration(keyString: nil, readonly: false))
        try AppDatabase.migrator.migrate(pool)
        return pool
    }

    private func walSize() -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path + "-wal")
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Whether `text` appears in the database file or its WAL.
    private func onDisk(_ text: String) throws -> Bool {
        let needle = Data(text.utf8)
        for suffix in ["", "-wal"] where FileManager.default.fileExists(atPath: path + suffix) {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path + suffix))
            if bytes.range(of: needle) != nil { return true }
        }
        return false
    }

    /// Whether `text` appears in any block of the full-text index. Read
    /// through SQL, so it sees the index whatever the file's encryption.
    private func inSearchIndex(_ db: Database, _ text: String) throws -> Bool {
        let needle = Data(text.utf8)
        return try Data.fetchAll(db, sql: "SELECT block FROM message_fts_data WHERE block IS NOT NULL")
            .contains { $0.range(of: needle) != nil }
    }

    private func insertAccount(_ db: Database, _ id: String) throws {
        try Account(id: id, displayName: id, historyId: nil,
                    lastSyncAt: nil, senderName: "").insert(db)
    }

    private func insertMessage(_ db: Database, account: String, gmailId: String,
                               subject: String, body: String, daysAgo: Double = 1) throws {
        let id = "\(account):\(gmailId)"
        try Message(
            id: id, accountId: account, gmailId: gmailId,
            threadId: "\(account):t-\(gmailId)", fromHeader: "Sender <s@example.com>",
            toHeader: account, ccHeader: "", subject: subject,
            date: Date().addingTimeInterval(-daysAgo * 86_400),
            snippet: "", bodyText: "", bodyHTML: nil, messageIdHeader: "",
            referencesHeader: "", labelIds: "INBOX", isUnread: false,
            hasAttachment: false).insert(db)
        try MessageBody(messageId: id, bodyText: body, bodyHTML: nil).insert(db)
    }

    /// Ordinary mail around the row under test, so its page stays in use
    /// after the delete: what is left behind then sits in the page's free
    /// space, which only an overwrite on delete clears.
    private func insertFiller(_ db: Database, account: String, range: Range<Int>) throws {
        for i in range {
            try insertMessage(db, account: account, gmailId: "filler-\(i)",
                              subject: "Routine update number \(i)",
                              body: "fillerbody \(i) " + String(repeating: "lorem ipsum ", count: 12))
        }
    }

    private func foldAndTruncate(_ pool: DatabasePool, freePageLimit: Int?) throws -> Bool {
        try pool.writeWithoutTransaction { db in
            try AppDatabase.foldAndTruncateLog(db, freePageLimit: freePageLimit)
        }
    }

    // MARK: Main tables

    func testDeletedMessageLeavesNeitherTheFileNorTheLog() throws {
        let pool = try openUnkeyedPool()
        let secret = marker("bodysecret")
        try pool.write { db in
            try insertAccount(db, "me@example.com")
            try insertFiller(db, account: "me@example.com", range: 0..<30)
            try insertMessage(db, account: "me@example.com", gmailId: "secret",
                              subject: "Plain subject", body: "Private text \(secret) ends here.")
            try insertFiller(db, account: "me@example.com", range: 30..<60)
        }
        XCTAssertTrue(try onDisk(secret), "the scan must see live content")

        try pool.write { db in
            _ = try Message.deleteOne(db, key: "me@example.com:secret")
        }
        XCTAssertTrue(try foldAndTruncate(pool, freePageLimit: AppDatabase.freePagesPerCheckpoint))
        XCTAssertEqual(walSize(), 0, "the log is truncated")
        XCTAssertFalse(try onDisk(secret), "deleted body still on disk")
        XCTAssertTrue(try onDisk("fillerbody 59"), "live mail stays")
        try pool.close()
        XCTAssertFalse(try onDisk(secret), "deleted body on disk after close")
    }

    // MARK: Full-text index

    func testDeletedMessageLeavesNoTermInTheSearchIndex() throws {
        let pool = try openUnkeyedPool()
        let term = marker("qxjsubject")
        // FTS5 leaves share a term's leading bytes with the previous term on
        // the page; the tail is stored verbatim.
        let tail = String(term.dropFirst(3))
        try pool.write { db in
            try insertAccount(db, "me@example.com")
            try insertFiller(db, account: "me@example.com", range: 0..<30)
            try insertMessage(db, account: "me@example.com", gmailId: "secret",
                              subject: "Quarterly \(term) plan", body: "body")
            try insertFiller(db, account: "me@example.com", range: 30..<60)
        }
        try pool.read { db in
            XCTAssertTrue(try inSearchIndex(db, tail), "the scan must see live terms")
        }
        XCTAssertTrue(try onDisk(tail))

        try pool.write { db in
            _ = try Message.deleteOne(db, key: "me@example.com:secret")
        }
        try pool.read { db in
            XCTAssertFalse(try inSearchIndex(db, tail), "deleted term still in the index")
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT count(*) FROM message_fts WHERE message_fts MATCH 'routine'
                """), 60, "live terms stay")
        }
        XCTAssertTrue(try foldAndTruncate(pool, freePageLimit: AppDatabase.freePagesPerCheckpoint))
        XCTAssertFalse(try onDisk(tail), "deleted term still on disk")
        try pool.close()
    }

    /// The setting lives in the index's own config table, so a migration
    /// that rebuilds `message_fts` must set it again.
    func testSearchIndexDeletesSecurelyInTheCurrentSchema() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue)
        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT v FROM message_fts_config WHERE k = 'secure-delete'
                """), 1)
        }
    }

    // MARK: Every connection

    private func secureDelete(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "PRAGMA secure_delete") ?? -1
    }

    /// Writer and readers, encrypted and not, writable and read-only.
    private func assertSecureDeleteOnEveryConnection(_ pool: DatabasePool, _ label: String,
                                                     file: StaticString = #filePath,
                                                     line: UInt = #line) throws {
        if !pool.configuration.readonly {
            XCTAssertEqual(try pool.writeWithoutTransaction(secureDelete), 1,
                           "\(label) writer", file: file, line: line)
        }
        // Concurrent reads open several reader connections.
        let seen = Seen()
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            let value = (try? pool.read { db -> Int in
                Thread.sleep(forTimeInterval: 0.05)
                return try self.secureDelete(db)
            }) ?? -1
            seen.append(value)
        }
        XCTAssertEqual(seen.values, [1, 1, 1, 1], "\(label) readers", file: file, line: line)
    }

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Int] = []
        func append(_ value: Int) { lock.lock(); stored.append(value); lock.unlock() }
        var values: [Int] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    func testSecureDeleteIsOnForEveryConnectionOfThePool() throws {
        // Unkeyed writable: the configuration itself, with no SQLCipher help.
        let unkeyed = try openUnkeyedPool()
        try assertSecureDeleteOnEveryConnection(unkeyed, "unkeyed")
        try unkeyed.close()
        try FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // The app's encrypted pool.
        XCTAssertEqual(try AppDatabase.prepareDatabaseFile(path: path, key: key), .raw)
        let encrypted = try AppDatabase.openAndMigrate(path: path, key: key, scheme: .raw)
        try assertSecureDeleteOnEveryConnection(encrypted, "raw-keyed")
        try encrypted.close()
        try FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // A deferred plaintext cache, read-only.
        let plain = try DatabasePool(path: path)
        try AppDatabase.migrator.migrate(plain)
        try plain.close()
        let readOnly = try AppDatabase.openAndMigrate(path: path, key: key, scheme: .plaintext)
        try assertSecureDeleteOnEveryConnection(readOnly, "read-only plaintext")
        try readOnly.close()
    }

    // MARK: Account removal

    func testRemovedAccountLeavesNothingInTheFileOrTheLog() throws {
        let pool = try openUnkeyedPool()
        let goneBody = marker("gonebody")
        let goneTerm = marker("qxjgone")
        let goneDraft = marker("gonedraft")
        let keptBody = marker("keptbody")
        try pool.write { db in
            try insertAccount(db, "gone@example.com")
            try insertAccount(db, "kept@example.com")
            // Interleaved, so the removed account's rows share pages with
            // rows that stay.
            for i in 0..<40 {
                let gone = i == 20
                try insertMessage(db, account: "gone@example.com", gmailId: "m\(i)",
                                  subject: gone ? "About \(goneTerm)" : "Gone account \(i)",
                                  body: gone ? "Text \(goneBody) end" : "gone filler \(i)")
                try insertMessage(db, account: "kept@example.com", gmailId: "m\(i)",
                                  subject: "Kept account \(i)",
                                  body: i == 20 ? "Text \(keptBody) end" : "kept filler \(i)")
            }
            var draft = LocalDraft(
                id: nil, accountId: "gone@example.com", fromEmail: "", toHeader: "x@example.com",
                ccHeader: "", bccHeader: "", subject: "Draft", body: "Draft \(goneDraft)",
                replyToMessageId: nil, forward: false, replacingDraftId: nil,
                attachmentsJSON: Data("[]".utf8), createdAt: Date(), updatedAt: Date())
            try draft.insert(db)
        }
        for text in [goneBody, String(goneTerm.dropFirst(3)), goneDraft, keptBody] {
            XCTAssertTrue(try onDisk(text), "the scan must see \(text) while it is live")
        }

        try pool.write { db in
            try AccountLifecycle.purgeAccount(db, id: "gone@example.com")
        }
        // What account removal runs right after the purge.
        XCTAssertTrue(try foldAndTruncate(pool, freePageLimit: nil))
        XCTAssertEqual(walSize(), 0)
        for text in [goneBody, String(goneTerm.dropFirst(3)), goneDraft] {
            XCTAssertFalse(try onDisk(text), "removed account's \(text) still on disk")
        }
        XCTAssertTrue(try onDisk(keptBody), "the other account's mail stays")
        try pool.close()
    }

    // MARK: Automatic scrub after a delete

    /// The app's own database: a committed delete schedules the scrub by
    /// itself, with no caller having to ask, and the log ends empty.
    func testCommittedDeleteTruncatesTheLogWithoutBeingAsked() throws {
        let database = try AppDatabase(path: path, key: key, allowConversion: true, scrubDelay: 0.2)
        defer { database.close() }
        try database.dbPool.write { db in
            try insertAccount(db, "me@example.com")
            try insertFiller(db, account: "me@example.com", range: 0..<20)
        }
        XCTAssertTrue(database.checkpoint())
        try database.dbPool.write { db in
            try insertFiller(db, account: "me@example.com", range: 20..<40)
        }
        // Inserts alone schedule nothing.
        Thread.sleep(forTimeInterval: 1)
        XCTAssertGreaterThan(database.walSizeBytes, 0, "an insert must not trigger the scrub")

        try database.dbPool.write { db in
            _ = try Message.deleteOne(db, key: "me@example.com:filler-5")
        }
        let deadline = Date().addingTimeInterval(15)
        while database.walSizeBytes > 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertEqual(database.walSizeBytes, 0, "the delete must be folded out of the log")
    }

    // MARK: Read-only cache

    /// A plaintext cache awaiting encryption must not change (F-02): the
    /// pragma is a connection setting, and every maintenance entry point,
    /// including the scrub a delete schedules, is a no-op on it.
    func testReadOnlyCacheGetsThePragmaButNoMaintenanceWrite() throws {
        let plain = try DatabasePool(path: path)
        try AppDatabase.migrator.migrate(plain)
        try plain.write { db in
            try insertAccount(db, "me@example.com")
            try insertFiller(db, account: "me@example.com", range: 0..<20)
            _ = try Message.deleteOne(db, key: "me@example.com:filler-3")
        }
        try plain.close()
        let before = try Data(contentsOf: URL(fileURLWithPath: path))

        let database = try AppDatabase(path: path, key: key, allowConversion: false, scrubDelay: 0.05)
        XCTAssertFalse(database.allowsWrites)
        XCTAssertEqual(try database.dbPool.read(secureDelete), 1)
        XCTAssertFalse(database.checkpoint())
        XCTAssertFalse(database.checkpoint(force: true, reclaimAllFreePages: true))
        database.scheduleScrub()
        Thread.sleep(forTimeInterval: 0.5)
        database.close()

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before,
                       "the plaintext file must stay byte-identical")
        let wal = (try? FileManager.default.attributesOfItem(atPath: path + "-wal")[.size]
                   as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(wal, 0, "nothing was logged for the plaintext file")
    }

    // MARK: Google HTTP

    /// Gmail responses (mail bodies, headers, attachments) must never reach
    /// the on-disk HTTP cache, where deleting them only unlinks rows.
    func testGoogleRequestsAreNeverCachedOnDisk() throws {
        let config = GoogleHTTP.configuration
        XCTAssertNil(config.urlCache)
        XCTAssertNil(config.httpCookieStorage)
        XCTAssertFalse(config.httpShouldSetCookies)
        XCTAssertEqual(config.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(GoogleHTTP.session.configuration.urlCache)

        for file in ["Sources/MishMail/Gmail/GmailClient.swift",
                     "Sources/MishMail/Auth/OAuth.swift",
                     "Sources/MishMail/App/MailStore+Accounts.swift"] {
            let text = try String(contentsOf: LogHygieneTests.repoRoot.appendingPathComponent(file),
                                  encoding: .utf8)
            XCTAssertFalse(text.contains("URLSession.shared"), "\(file) uses the shared session")
            XCTAssertTrue(text.contains("GoogleHTTP.session"), file)
        }
    }

    // MARK: Files set aside

    /// A damaged plaintext cache is reset; its unencrypted mail must not be
    /// kept next to the new file.
    func testDamagedPlaintextCacheIsNotKeptAside() throws {
        let secret = marker("plainsecret")
        var bytes = Data("SQLite format 3\u{0}".utf8)
        bytes.append(contentsOf: [0x00, 0x03])   // an impossible page size
        bytes.append(Data(String(repeating: "mail \(secret) ", count: 200).utf8))
        try bytes.write(to: URL(fileURLWithPath: path))

        let database = try AppDatabase(path: path, key: key, allowConversion: true)
        XCTAssertEqual(database.storageState, .writable)
        database.close()
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: path + ".unreadable"),
                       "a plaintext cache must not be kept aside")
        let names = try fm.contentsOfDirectory(atPath: dir.path)
        for name in names {
            let data = try Data(contentsOf: dir.appendingPathComponent(name))
            XCTAssertNil(data.range(of: Data(secret.utf8)), "\(name) keeps the plaintext mail")
        }
    }

    /// What an earlier build kept aside: a plaintext copy goes at the next
    /// open; an encrypted one (unreadable without the key, kept for
    /// post-mortems) stays.
    func testPlaintextLeftoverFromAnEarlierBuildIsRemovedAtOpen() throws {
        let fm = FileManager.default
        let aside = path + ".unreadable"
        let legacy = try DatabaseQueue(path: aside)
        try legacy.write { db in try db.execute(sql: "CREATE TABLE t (body TEXT)") }
        try legacy.close()
        XCTAssertTrue(AppDatabase.isPlaintext(aside))

        var database = try AppDatabase(path: path, key: key, allowConversion: true)
        database.close()
        XCTAssertFalse(fm.fileExists(atPath: aside), "plaintext leftover must go")

        let cipherLike = Data((0..<4096).map { _ in UInt8.random(in: 0...255) })
        try cipherLike.write(to: URL(fileURLWithPath: aside))
        database = try AppDatabase(path: path, key: key, allowConversion: true)
        database.close()
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: aside)), cipherLike,
                       "an encrypted post-mortem copy is left alone")
    }
}
