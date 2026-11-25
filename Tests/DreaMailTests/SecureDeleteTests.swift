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
            .appendingPathComponent("dreamail-securedelete-\(UUID().uuidString)", isDirectory: true)
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

    /// Plain SQL, not the `Account` record: some tests insert on an older
    /// schema (before v52's `labelColor`), which the record would not fit.
    private func insertAccount(_ db: Database, _ id: String) throws {
        try db.execute(sql: "INSERT INTO account (id, displayName, senderName) VALUES (?, ?, '')",
                       arguments: [id, id])
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

    /// A message with one cached inline image (`InlineImageCache`).
    private func insertInlineImage(_ db: Database, account: String, gmailId: String,
                                   image: Data, daysAgo: Double = 1) throws {
        try insertMessage(db, account: account, gmailId: gmailId,
                          subject: "Image \(gmailId)", body: "image body", daysAgo: daysAgo)
        let id = "\(account):\(gmailId)"
        let html = "<p>Logo</p><img src=\"cid:logo\">"
        try db.execute(sql: "UPDATE message_body SET bodyHTML = ? WHERE messageId = ?",
                       arguments: [html, id])
        let row = AttachmentRow(id: nil, messageId: id, gmailAttachmentId: "att-\(gmailId)",
                                filename: "logo.png", mimeType: "image/png",
                                size: image.count, contentId: "logo")
        try row.insert(db)
        let attachmentId = db.lastInsertedRowID
        let stored = try InlineImageCache.store(db, .init(
            messageId: id, accountId: account, bodyDigest: InlineImageCache.bodyDigest(html),
            parts: [.init(attachmentId: attachmentId, contentId: "logo",
                          mimeType: "image/png", data: image)]), now: Date())
        XCTAssertTrue(stored)
    }

    /// A message with one cached remote image (`RemoteImageCache`).
    private func insertRemoteImage(_ db: Database, account: String, gmailId: String,
                                   image: Data, daysAgo: Double = 1) throws {
        try insertMessage(db, account: account, gmailId: gmailId,
                          subject: "Remote \(gmailId)", body: "remote body", daysAgo: daysAgo)
        let id = "\(account):\(gmailId)"
        let url = "https://img.example.com/\(gmailId).png"
        try db.execute(sql: "UPDATE message_body SET bodyHTML = ? WHERE messageId = ?",
                       arguments: ["<img src=\"\(url)\">", id])
        let written = try RemoteImageCache.store(db, .init(
            messageId: id, accountId: account,
            images: [.init(urlKey: RemoteImageHTML.urlKey(url), mimeType: "image/png", data: image)]),
            now: Date())
        XCTAssertEqual(written, 1)
    }

    /// Image bytes large enough to spill over several overflow pages, with
    /// the marker on each of them.
    private func imageBytes(_ marker: String) -> Data {
        var data = Data()
        for i in 0..<80 {
            data.append(Data(marker.utf8))
            data.append(Data(repeating: UInt8(i), count: 1_000))
        }
        return data
    }

    private func foldAndTruncate(_ pool: DatabasePool, freePageLimit: Int) throws -> Bool {
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

    // MARK: Cached inline images

    /// A deleted message's cached inline images, a message whose content
    /// changed, and an evicted message's images: zeroed in the file and gone
    /// from the log, like the mail they belong to.
    func testCachedInlineImagesLeaveNeitherTheFileNorTheLog() throws {
        let pool = try openUnkeyedPool()
        let deleted = marker("imgdeleted")
        let revised = marker("imgrevised")
        let evicted = marker("imgevicted")
        let kept = marker("imgkept")
        try pool.write { db in
            try insertAccount(db, "me@example.com")
            try insertFiller(db, account: "me@example.com", range: 0..<30)
            try insertInlineImage(db, account: "me@example.com", gmailId: "deleted",
                                  image: imageBytes(deleted))
            try insertInlineImage(db, account: "me@example.com", gmailId: "revised",
                                  image: imageBytes(revised))
            try insertInlineImage(db, account: "me@example.com", gmailId: "evicted",
                                  image: imageBytes(evicted))
            try insertInlineImage(db, account: "me@example.com", gmailId: "kept",
                                  image: imageBytes(kept))
            // "kept" was used last: it is the one eviction keeps.
            try InlineImageCache.touch(db, messageIds: ["me@example.com:kept"],
                                       now: Date().addingTimeInterval(2 * 86_400))
            try insertFiller(db, account: "me@example.com", range: 30..<60)
        }
        for text in [deleted, revised, evicted, kept] {
            XCTAssertTrue(try onDisk(text), "the scan must see \(text) while it is live")
        }

        try pool.write { db in
            _ = try Message.deleteOne(db, key: "me@example.com:deleted")
            // A full re-fetch: new body, new attachment rows.
            var updated = try XCTUnwrap(try Message.fetchOne(db, key: "me@example.com:revised"))
            updated.bodyText = "edited"
            updated.bodyHTML = "<p>Edited</p><img src=\"cid:logo\">"
            let replacement = AttachmentRow(
                id: nil, messageId: updated.id, gmailAttachmentId: "att-new",
                filename: "logo.png", mimeType: "image/png", size: 10, contentId: "logo")
            _ = try SyncEngine.upsertPending(
                db, items: [.init(message: updated, attachments: [replacement])])
            let size = try Int.fetchOne(
                db, sql: "SELECT byteCount FROM inlineImage WHERE messageId = ?",
                arguments: ["me@example.com:kept"]) ?? 0
            XCTAssertEqual(try InlineImageCache.evict(db, budget: size), ["me@example.com:evicted"])
        }
        XCTAssertTrue(try foldAndTruncate(pool, freePageLimit: AppDatabase.freePagesPerCheckpoint))
        XCTAssertEqual(walSize(), 0, "the log is truncated")
        for text in [deleted, revised, evicted] {
            XCTAssertFalse(try onDisk(text), "\(text) still on disk")
        }
        XCTAssertTrue(try onDisk(kept), "the image still cached stays")
        try pool.close()
        for text in [deleted, revised, evicted] {
            XCTAssertFalse(try onDisk(text), "\(text) on disk after close")
        }
    }

    /// The other ways a message's images go: a local prune, the deletion
    /// of the last message of a thread, and the launch sweep of rows whose
    /// attachment row is gone.
    func testPrunedThreadDeletedAndOrphanedImagesLeaveNeitherTheFileNorTheLog() throws {
        let pool = try openUnkeyedPool()
        let pruned = marker("imgpruned")
        let threadGone = marker("imgthread")
        let orphan = marker("imgorphan")
        let kept = marker("imgkept")
        try pool.write { db in
            try insertAccount(db, "me@example.com")
            try insertFiller(db, account: "me@example.com", range: 0..<30)
            try insertInlineImage(db, account: "me@example.com", gmailId: "pruned",
                                  image: imageBytes(pruned), daysAgo: 200)
            try insertInlineImage(db, account: "me@example.com", gmailId: "thread",
                                  image: imageBytes(threadGone))
            try insertInlineImage(db, account: "me@example.com", gmailId: "orphan",
                                  image: imageBytes(orphan))
            try insertInlineImage(db, account: "me@example.com", gmailId: "kept",
                                  image: imageBytes(kept))
            try insertFiller(db, account: "me@example.com", range: 30..<60)
        }
        for text in [pruned, threadGone, orphan, kept] {
            XCTAssertTrue(try onDisk(text), "the scan must see \(text) while it is live")
        }

        try pool.write { db in
            try SyncEngine.pruneMessages(db, accountId: "me@example.com",
                                         olderThan: Date().addingTimeInterval(-90 * 86_400))
            XCTAssertEqual(try SyncEngine.deleteLocalMessage(
                db, messageId: "me@example.com:thread", threadId: "me@example.com:t-thread",
                accountId: "me@example.com"), .threadDeleted)
        }
        // A row left behind by a write with foreign keys off, then the sweep.
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "DELETE FROM attachment WHERE messageId = 'me@example.com:orphan'")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        try pool.write { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT count(*) FROM inlineImage WHERE messageId = 'me@example.com:orphan'
                """), 1, "fixture: the orphaned row is still there")
            try AccountLifecycle.purgeOrphanRows(db)
        }
        XCTAssertTrue(try foldAndTruncate(pool, freePageLimit: AppDatabase.freePagesPerCheckpoint))
        XCTAssertEqual(walSize(), 0, "the log is truncated")
        for text in [pruned, threadGone, orphan] {
            XCTAssertFalse(try onDisk(text), "\(text) still on disk")
        }
        XCTAssertTrue(try onDisk(kept), "the image still cached stays")
        try pool.close()
    }

    // MARK: Cached remote images

    /// A deleted message's cached remote images, an evicted message's, a
    /// pruned message's, a deleted thread's and an orphan's: zeroed in the
    /// file and gone from the log, like the mail they belong to.
    func testCachedRemoteImagesLeaveNeitherTheFileNorTheLog() throws {
        let pool = try openUnkeyedPool()
        let deleted = marker("rimgdeleted")
        let evicted = marker("rimgevicted")
        let pruned = marker("rimgpruned")
        let threadGone = marker("rimgthread")
        let orphan = marker("rimgorphan")
        let kept = marker("rimgkept")
        try pool.write { db in
            try insertAccount(db, "me@example.com")
            try insertFiller(db, account: "me@example.com", range: 0..<30)
            try insertRemoteImage(db, account: "me@example.com", gmailId: "deleted",
                                  image: imageBytes(deleted))
            try insertRemoteImage(db, account: "me@example.com", gmailId: "evicted",
                                  image: imageBytes(evicted))
            try insertRemoteImage(db, account: "me@example.com", gmailId: "pruned",
                                  image: imageBytes(pruned), daysAgo: 200)
            try insertRemoteImage(db, account: "me@example.com", gmailId: "thread",
                                  image: imageBytes(threadGone))
            try insertRemoteImage(db, account: "me@example.com", gmailId: "orphan",
                                  image: imageBytes(orphan))
            try insertRemoteImage(db, account: "me@example.com", gmailId: "kept",
                                  image: imageBytes(kept))
            // Everything but "evicted" used later: it is the one eviction takes.
            try RemoteImageCache.touch(
                db, messageIds: ["deleted", "pruned", "thread", "orphan", "kept"]
                    .map { "me@example.com:\($0)" },
                now: Date().addingTimeInterval(2 * 86_400))
            try insertFiller(db, account: "me@example.com", range: 30..<60)
        }
        for text in [deleted, evicted, pruned, threadGone, orphan, kept] {
            XCTAssertTrue(try onDisk(text), "the scan must see \(text) while it is live")
        }

        try pool.write { db in
            _ = try Message.deleteOne(db, key: "me@example.com:deleted")
            let total = try RemoteImageCache.totalBytes(db)
            let one = imageBytes(kept).count
            XCTAssertEqual(try RemoteImageCache.evict(db, budget: total - one),
                           ["me@example.com:evicted"])
            try SyncEngine.pruneMessages(db, accountId: "me@example.com",
                                         olderThan: Date().addingTimeInterval(-90 * 86_400))
            XCTAssertEqual(try SyncEngine.deleteLocalMessage(
                db, messageId: "me@example.com:thread", threadId: "me@example.com:t-thread",
                accountId: "me@example.com"), .threadDeleted)
        }
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "DELETE FROM message WHERE id = 'me@example.com:orphan'")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        try pool.write { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT count(*) FROM remoteImage WHERE messageId = 'me@example.com:orphan'
                """), 1, "fixture: the orphaned row is still there")
            try AccountLifecycle.purgeOrphanRows(db)
        }
        XCTAssertTrue(try foldAndTruncate(pool, freePageLimit: AppDatabase.freePagesPerCheckpoint))
        XCTAssertEqual(walSize(), 0, "the log is truncated")
        for text in [deleted, evicted, pruned, threadGone, orphan] {
            XCTAssertFalse(try onDisk(text), "\(text) still on disk")
        }
        XCTAssertTrue(try onDisk(kept), "the image still cached stays")
        try pool.close()
        for text in [deleted, evicted, pruned, threadGone, orphan] {
            XCTAssertFalse(try onDisk(text), "\(text) on disk after close")
        }
    }

    /// Account removal: that account's remote images leave the file and log.
    func testRemovedAccountsRemoteImagesLeaveNeitherTheFileNorTheLog() throws {
        let pool = try openUnkeyedPool()
        let gone = marker("rimggone")
        let kept = marker("rimgother")
        try pool.write { db in
            try insertAccount(db, "me@example.com")
            try insertAccount(db, "other@example.com")
            try insertFiller(db, account: "other@example.com", range: 0..<30)
            try insertRemoteImage(db, account: "me@example.com", gmailId: "a", image: imageBytes(gone))
            try insertRemoteImage(db, account: "other@example.com", gmailId: "a", image: imageBytes(kept))
            try insertFiller(db, account: "other@example.com", range: 30..<60)
        }
        XCTAssertTrue(try onDisk(gone))
        try pool.write { db in try AccountLifecycle.purgeAccount(db, id: "me@example.com") }
        XCTAssertTrue(try foldAndTruncate(pool, freePageLimit: AppDatabase.freePagesPerCheckpoint))
        XCTAssertFalse(try onDisk(gone), "removed account's image still on disk")
        XCTAssertTrue(try onDisk(kept), "the other account's stays")
        try pool.close()
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

    /// A bulk delete (local prune) suspends the per-row index work and
    /// rebuilds the index at the end: the deleted terms must still be gone,
    /// and the index must delete securely again afterwards. The index here
    /// is filled row by row by the sync triggers, as in the app; an
    /// `optimize` in place of the rebuild left the term behind on it.
    func testBulkPruneLeavesNoTermInTheSearchIndex() throws {
        let pool = try openUnkeyedPool()
        let term = marker("qxjbulk")
        let tail = String(term.dropFirst(3))
        let old = SearchIndexDeletes.bulkThreshold + 50
        try pool.write { db in
            try insertAccount(db, "me@example.com")
            for i in 0..<old {
                try insertMessage(db, account: "me@example.com", gmailId: "old-\(i)",
                                  subject: i == old / 2 ? "Old \(term) note" : "Old note \(i)",
                                  body: "old body \(i)", daysAgo: 400)
            }
            try insertFiller(db, account: "me@example.com", range: 0..<30)
        }
        try pool.read { db in XCTAssertTrue(try inSearchIndex(db, tail)) }

        try pool.write { db in
            try SyncEngine.pruneMessages(db, accountId: "me@example.com",
                                         olderThan: Date().addingTimeInterval(-90 * 86_400))
        }
        try pool.read { db in
            XCTAssertEqual(try Message.fetchCount(db), 30)
            XCTAssertFalse(try inSearchIndex(db, tail), "pruned term still in the index")
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT count(*) FROM message_fts WHERE message_fts MATCH 'routine'
                """), 30, "the kept mail stays searchable")
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT v FROM message_fts_config WHERE k = 'secure-delete'
                """), 1, "secure-delete is back on after the bulk delete")
        }
        XCTAssertTrue(try foldAndTruncate(pool, freePageLimit: AppDatabase.freePagesPerCheckpoint))
        XCTAssertFalse(try onDisk(tail), "pruned term still on disk")
        XCTAssertFalse(try onDisk("old body \(old / 2)"), "pruned body still on disk")
        try pool.close()
    }

    /// What an earlier build left in the index: terms of messages deleted
    /// before secure-delete existed. The migration only requests the
    /// rebuild (it would block the launch); the deferred rebuild clears them.
    func testUpgradeClearsTermsOfMessagesDeletedBefore() throws {
        let pool = try DatabasePool(
            path: path,
            configuration: AppDatabase.connectionConfiguration(keyString: nil, readonly: false))
        try AppDatabase.migrator.migrate(pool, upTo: "v48")
        let term = marker("qxjolder")
        let tail = String(term.dropFirst(3))
        try pool.write { db in
            try insertAccount(db, "me@example.com")
            try insertFiller(db, account: "me@example.com", range: 0..<30)
            try insertMessage(db, account: "me@example.com", gmailId: "secret",
                              subject: "Earlier \(term) mail", body: "body")
            try insertFiller(db, account: "me@example.com", range: 30..<60)
        }
        try pool.write { db in
            _ = try Message.deleteOne(db, key: "me@example.com:secret")
        }
        try pool.read { db in
            XCTAssertTrue(try inSearchIndex(db, tail), "fixture: the old index keeps deleted terms")
        }
        try AppDatabase.migrator.migrate(pool)
        try pool.read { db in
            XCTAssertTrue(try SearchIndexDeletes.rebuildIsPending(db), "v49 requests the rebuild")
        }
        try pool.write { db in try SearchIndexDeletes.rebuildIfPending(db) }
        try pool.read { db in
            XCTAssertFalse(try SearchIndexDeletes.rebuildIsPending(db), "and it runs once")
            XCTAssertFalse(try inSearchIndex(db, tail), "the upgrade must clear it")
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT count(*) FROM message_fts WHERE message_fts MATCH 'routine'
                """), 60)
        }
        XCTAssertTrue(try foldAndTruncate(pool, freePageLimit: AppDatabase.freePagesPerCheckpoint))
        XCTAssertFalse(try onDisk(tail), "deleted term still on disk after the upgrade")
        try pool.close()
    }

    func testBulkPathOnlyWhenTheRebuildIsCheaper() {
        let threshold = SearchIndexDeletes.bulkThreshold
        XCTAssertFalse(SearchIndexDeletes.usesBulkPath(deleting: 20, of: 1_000))
        XCTAssertFalse(SearchIndexDeletes.usesBulkPath(deleting: threshold - 1, of: threshold))
        XCTAssertTrue(SearchIndexDeletes.usesBulkPath(deleting: threshold, of: threshold))
        XCTAssertTrue(SearchIndexDeletes.usesBulkPath(deleting: 2_000, of: 3_000))
        // A few hundred deletes in a very large mailbox: rebuilding every
        // remaining row would cost more than deleting securely.
        XCTAssertFalse(SearchIndexDeletes.usesBulkPath(
            deleting: threshold, of: threshold * (SearchIndexDeletes.rebuildCostRatio + 2)))
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
        let goneImage = marker("goneimage")
        let keptImage = marker("keptimage")
        try pool.write { db in
            try insertAccount(db, "gone@example.com")
            try insertAccount(db, "kept@example.com")
            try insertInlineImage(db, account: "gone@example.com", gmailId: "img",
                                  image: imageBytes(goneImage))
            try insertInlineImage(db, account: "kept@example.com", gmailId: "img",
                                  image: imageBytes(keptImage))
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
            let draft = LocalDraft(
                id: nil, accountId: "gone@example.com", fromEmail: "", toHeader: "x@example.com",
                ccHeader: "", bccHeader: "", subject: "Draft", body: "Draft \(goneDraft)",
                replyToMessageId: nil, forward: false, replacingDraftId: nil,
                attachmentsJSON: Data("[]".utf8), createdAt: Date(), updatedAt: Date())
            try draft.insert(db)
        }
        for text in [goneBody, String(goneTerm.dropFirst(3)), goneDraft, keptBody, goneImage, keptImage] {
            XCTAssertTrue(try onDisk(text), "the scan must see \(text) while it is live")
        }

        try pool.write { db in
            try AccountLifecycle.purgeAccount(db, id: "gone@example.com")
        }
        // What account removal runs right after the purge.
        XCTAssertTrue(try foldAndTruncate(pool, freePageLimit: AppDatabase.freePagesPerCheckpoint))
        XCTAssertEqual(walSize(), 0)
        for text in [goneBody, String(goneTerm.dropFirst(3)), goneDraft, goneImage] {
            XCTAssertFalse(try onDisk(text), "removed account's \(text) still on disk")
        }
        XCTAssertTrue(try onDisk(keptBody), "the other account's mail stays")
        XCTAssertTrue(try onDisk(keptImage), "and its cached images")
        try pool.close()
    }

    // MARK: Automatic scrub after a delete

    /// The app's own database: a committed delete schedules the scrub by
    /// itself, with no caller having to ask, and the scrub empties the log.
    /// The delay is an hour, so nothing fires on its own; the test runs the
    /// scrub at the point the timer would.
    func testCommittedDeleteSchedulesTheScrubThatTruncatesTheLog() throws {
        let database = try AppDatabase(path: path, key: key, allowConversion: true,
                                       timing: .init(scrubDelay: 3_600))
        defer { database.close() }
        XCTAssertTrue(database.scrubIsPending, "the open schedules one (crash leftovers)")
        database.runScheduledScrub()
        XCTAssertFalse(database.scrubIsPending)

        try database.dbPool.write { db in
            try insertAccount(db, "me@example.com")
            try insertFiller(db, account: "me@example.com", range: 0..<20)
        }
        XCTAssertGreaterThan(database.walSizeBytes, 0)
        XCTAssertFalse(database.scrubIsPending, "an insert must not schedule the scrub")

        try database.dbPool.write { db in
            _ = try Message.deleteOne(db, key: "me@example.com:filler-5")
        }
        XCTAssertTrue(database.scrubIsPending, "the commit of a delete schedules it")
        database.runScheduledScrub()
        XCTAssertEqual(database.walSizeBytes, 0, "the delete must be folded out of the log")
    }

    /// An eviction through the app's writer (`InlineImageStore`) is a
    /// committed delete like any other: it schedules the scrub, and the
    /// scrub empties the log.
    func testEvictionThroughTheStoreSchedulesTheScrub() async throws {
        let database = try AppDatabase(path: path, key: key, allowConversion: true,
                                       timing: .init(scrubDelay: 3_600))
        defer { database.close() }
        let oneImage = try seedTwoCachedImages(database)
        XCTAssertFalse(database.scrubIsPending)

        // Two days later "b" is shown again: "a" is the least recently used
        // and goes, to fit a budget of one image.
        let later = Date().addingTimeInterval(2 * 86_400)
        let store = InlineImageStore(db: database.dbPool, budget: oneImage,
                                     flushDelayNanoseconds: 1_000_000, now: { later })
        await store.noteUsed(["me@example.com:b"])
        await store.flush()
        await store.shutDown()
        XCTAssertEqual(try cachedImageMessages(database), ["me@example.com:b"])
        XCTAssertTrue(database.scrubIsPending, "the eviction's commit schedules the scrub")
        database.runScheduledScrub()
        XCTAssertEqual(database.walSizeBytes, 0, "the evicted bytes are folded out of the log")
    }

    /// Synchronous on purpose (called from an async test). Returns one
    /// image's size.
    private func seedTwoCachedImages(_ database: AppDatabase) throws -> Int {
        database.runScheduledScrub()
        try database.dbPool.write { db in
            try insertAccount(db, "me@example.com")
            try insertFiller(db, account: "me@example.com", range: 0..<20)
            try insertInlineImage(db, account: "me@example.com", gmailId: "a",
                                  image: imageBytes(marker("imga")))
            try insertInlineImage(db, account: "me@example.com", gmailId: "b",
                                  image: imageBytes(marker("imgb")))
        }
        return imageBytes(marker("imgx")).count
    }

    private func cachedImageMessages(_ database: AppDatabase) throws -> [String] {
        try database.dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT messageId FROM inlineImage ORDER BY messageId")
        }
    }

    /// The timer itself, end to end, with a short delay.
    func testScheduledScrubFiresOnItsOwn() throws {
        let database = try AppDatabase(path: path, key: key, allowConversion: true,
                                       timing: .init(scrubDelay: 0.05))
        defer { database.close() }
        try database.dbPool.write { db in
            try insertAccount(db, "me@example.com")
            try insertFiller(db, account: "me@example.com", range: 0..<20)
            _ = try Message.deleteOne(db, key: "me@example.com:filler-5")
        }
        let deadline = Date().addingTimeInterval(30)
        while database.walSizeBytes > 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(database.walSizeBytes, 0)
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

        let database = try AppDatabase(path: path, key: key, allowConversion: false,
                                       timing: .init(scrubDelay: 0.05))
        XCTAssertFalse(database.allowsWrites)
        XCTAssertEqual(try database.dbPool.read(secureDelete), 1)
        XCTAssertFalse(database.checkpoint())
        XCTAssertFalse(database.checkpoint(force: true, waitForReaders: true))
        XCTAssertFalse(database.scrubIsPending, "no scrub on a read-only cache")
        database.scheduleScrub()
        database.rebuildSearchIndexIfPending()
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

        for file in ["Sources/DreaMail/Gmail/GmailClient.swift",
                     "Sources/DreaMail/Auth/OAuth.swift",
                     "Sources/DreaMail/App/MailStore+Accounts.swift"] {
            let text = try String(contentsOf: LogHygieneTests.repoRoot.appendingPathComponent(file),
                                  encoding: .utf8)
            XCTAssertFalse(text.contains("URLSession.shared"), "\(file) uses the shared session")
            XCTAssertTrue(text.contains("GoogleHTTP.session"), file)
        }
    }

    // MARK: Files set aside

    private func makePlaintextCache(at file: String, marker secret: String) throws {
        let plain = try DatabaseQueue(path: file)
        try AppDatabase.migrator.migrate(plain)
        try plain.write { db in
            try insertAccount(db, "me@example.com")
            try insertMessage(db, account: "me@example.com", gmailId: "kept",
                              subject: "Subject", body: "Only copy \(secret)")
            let draft = LocalDraft(
                id: nil, accountId: "me@example.com", fromEmail: "", toHeader: "x@example.com",
                ccHeader: "", bccHeader: "", subject: "Draft", body: "Unsent \(secret)",
                replyToMessageId: nil, forward: false, replacingDraftId: nil,
                attachmentsJSON: Data("[]".utf8), createdAt: Date(), updatedAt: Date())
            try draft.insert(db)
        }
        try plain.close()
    }

    private func encryptedRows(_ file: String, table: String) throws -> Int {
        var config = Configuration()
        let raw = AppDatabase.rawKeyLiteral(key)
        config.prepareDatabase { db in try db.usePassphrase(raw) }
        let queue = try DatabaseQueue(path: file, configuration: config)
        defer { try? queue.close() }
        return try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM \"\(table)\"") ?? 0
        }
    }

    private func noFileHolds(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            let data = try Data(contentsOf: dir.appendingPathComponent(name))
            XCTAssertNil(data.range(of: Data(text.utf8)), "\(name) holds it in plaintext",
                         file: file, line: line)
        }
    }

    /// A plaintext cache that reaches the reset path while it can still be
    /// read (here: its one-time encryption fails after the export) is the
    /// only copy of the unsent draft: it is set aside at once, encrypted in
    /// the deferred startup work, and only then is the plaintext deleted.
    func testRecoverablePlaintextOnTheResetPathIsKeptEncrypted() throws {
        let secret = marker("plainsecret")
        try makePlaintextCache(at: path, marker: secret)
        struct ExportFailed: Error {}
        let database = try AppDatabase(path: path, key: key, allowConversion: true,
                                       beforeSwap: { _ in throw ExportFailed() })
        XCTAssertEqual(database.storageState, .writable, "a fresh cache")
        let aside = path + ".unreadable"
        XCTAssertTrue(AppDatabase.isPlaintext(aside), "set aside as it was, off the launch path")
        database.encryptSetAsideIfPlaintext()
        database.close()

        XCTAssertFalse(AppDatabase.isPlaintext(aside), "kept aside encrypted")
        XCTAssertEqual(try encryptedRows(aside, table: "localDraft"), 1, "the draft survives")
        XCTAssertEqual(try encryptedRows(aside, table: "message_body"), 1)
        try noFileHolds(secret)
    }

    /// A rename that fails after a good export says nothing about the file:
    /// it stays as it was, read-only (F-02), and nothing is set aside.
    func testFailedSwapDefersTheEncryptionInsteadOfResetting() throws {
        let secret = marker("plainsecret")
        try makePlaintextCache(at: path, marker: secret)
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        let database = try AppDatabase(path: path, key: key, allowConversion: true,
                                       beforeSwap: { _ in throw AppDatabase.RekeyError.swapFailed(EXDEV) })
        XCTAssertFalse(database.allowsWrites, "deferred, as when busy")
        database.close()
        XCTAssertTrue(AppDatabase.isPlaintext(path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: path + ".unreadable"))
        XCTAssertFalse(fm.fileExists(atPath: path + ".encrypting"), "no partial copy left")

        // The next launch converts it.
        let next = try AppDatabase(path: path, key: key, allowConversion: true)
        XCTAssertEqual(next.storageState, .writable)
        next.close()
        XCTAssertEqual(try encryptedRows(path, table: "localDraft"), 1)
    }

    /// A plaintext file that cannot be read at all cannot be copied: it is
    /// kept aside as it was rather than destroyed.
    func testUnreadablePlaintextIsKeptAsItWas() throws {
        var bytes = Data("SQLite format 3\u{0}".utf8)
        bytes.append(contentsOf: [0x00, 0x03])   // an impossible page size
        bytes.append(Data(String(repeating: "mail ", count: 200).utf8))
        try bytes.write(to: URL(fileURLWithPath: path))

        let database = try AppDatabase(path: path, key: key, allowConversion: true)
        XCTAssertEqual(database.storageState, .writable)
        database.encryptSetAsideIfPlaintext()
        let aside = path + ".unreadable"
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: aside)), bytes)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: aside + AppDatabase.salvageFailedSuffix), "tried once, and recorded")
        database.encryptSetAsideIfPlaintext()
        database.close()
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: aside)), bytes)
    }

    /// The salvage keeps the plaintext unless the copy is provably complete:
    /// a source that fails its integrity check, or has nothing to copy, is
    /// left alone.
    func testSalvageRefusesADamagedOrEmptySource() throws {
        let fm = FileManager.default
        let target = dir.appendingPathComponent("copy.sqlite").path

        let empty = dir.appendingPathComponent("empty.sqlite").path
        let emptyQueue = try DatabaseQueue(path: empty)
        try emptyQueue.write { db in try db.execute(sql: "PRAGMA user_version = 1") }
        try emptyQueue.close()
        XCTAssertFalse(AppDatabase.salvagePlaintext(from: empty, into: target, key: key))
        XCTAssertFalse(fm.fileExists(atPath: target))

        let damaged = dir.appendingPathComponent("damaged.sqlite").path
        let queue = try DatabaseQueue(path: damaged)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE t (id INTEGER PRIMARY KEY, body TEXT)")
            for i in 0..<2_000 {
                try db.execute(sql: "INSERT INTO t (body) VALUES (?)",
                               arguments: [String(repeating: "row \(i) ", count: 20)])
            }
        }
        try queue.close()
        // Overwrite a page in the middle of the table's b-tree.
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: damaged))
        try handle.seek(toOffset: 4096 * 20)
        try handle.write(contentsOf: Data((0..<4096).map { _ in UInt8.random(in: 0...255) }))
        try handle.close()
        let before = try Data(contentsOf: URL(fileURLWithPath: damaged))

        XCTAssertFalse(AppDatabase.salvagePlaintext(from: damaged, into: target, key: key))
        XCTAssertFalse(fm.fileExists(atPath: target))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: damaged)), before,
                       "the source is read-only")
    }

    /// What an earlier build kept aside in plaintext is encrypted in the
    /// deferred startup work; an encrypted copy (post-mortems) is left alone.
    func testPlaintextLeftoverFromAnEarlierBuildIsEncryptedLater() throws {
        let secret = marker("plainsecret")
        let aside = path + ".unreadable"
        try makePlaintextCache(at: aside, marker: secret)
        XCTAssertTrue(AppDatabase.isPlaintext(aside))

        var database = try AppDatabase(path: path, key: key, allowConversion: true)
        database.encryptSetAsideIfPlaintext()
        database.close()
        XCTAssertFalse(AppDatabase.isPlaintext(aside))
        XCTAssertEqual(try encryptedRows(aside, table: "localDraft"), 1)
        try noFileHolds(secret)

        let cipherLike = Data((0..<4096).map { _ in UInt8.random(in: 0...255) })
        try cipherLike.write(to: URL(fileURLWithPath: aside))
        database = try AppDatabase(path: path, key: key, allowConversion: true)
        database.encryptSetAsideIfPlaintext()
        database.close()
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: aside)), cipherLike,
                       "an encrypted post-mortem copy is left alone")
    }
}
