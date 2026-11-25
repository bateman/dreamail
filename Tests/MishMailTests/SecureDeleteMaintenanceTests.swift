import XCTest
import GRDB

/// The maintenance around secure delete: the bulk path through an account
/// removal, the index setting surviving a failure, the scrub's guarantees
/// (at open, after updates, behind busy readers), and the copies of
/// deleted mail kept outside the database.
final class SecureDeleteMaintenanceTests: XCTestCase {
    private let key = String(repeating: "cd", count: 32)
    private var dir: URL!
    private var path: String { dir.appendingPathComponent("mail.sqlite").path }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mishmail-sdmaint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Helpers

    private func marker(_ prefix: String) -> String {
        prefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private func openUnkeyedPool() throws -> DatabasePool {
        let pool = try DatabasePool(
            path: path,
            configuration: AppDatabase.connectionConfiguration(keyString: nil, readonly: false))
        try AppDatabase.migrator.migrate(pool)
        return pool
    }

    private func onDisk(_ text: String) throws -> Bool {
        let needle = Data(text.utf8)
        for suffix in ["", "-wal"] where FileManager.default.fileExists(atPath: path + suffix) {
            if try Data(contentsOf: URL(fileURLWithPath: path + suffix)).range(of: needle) != nil {
                return true
            }
        }
        return false
    }

    private func inSearchIndex(_ db: Database, _ text: String) throws -> Bool {
        let needle = Data(text.utf8)
        return try Data.fetchAll(db, sql: "SELECT block FROM message_fts_data WHERE block IS NOT NULL")
            .contains { $0.range(of: needle) != nil }
    }

    private func secureDeleteSetting(_ db: Database) throws -> Int? {
        try Int.fetchOne(db, sql: "SELECT v FROM message_fts_config WHERE k = 'secure-delete'")
    }

    private func insertAccount(_ db: Database, _ id: String) throws {
        try Account(id: id, displayName: id, historyId: nil,
                    lastSyncAt: nil, senderName: "").insert(db)
    }

    private func insertMessage(_ db: Database, account: String, gmailId: String,
                               subject: String, body: String = "body") throws {
        let id = "\(account):\(gmailId)"
        try Message(
            id: id, accountId: account, gmailId: gmailId,
            threadId: "\(account):t-\(gmailId)", fromHeader: "Sender <s@example.com>",
            toHeader: account, ccHeader: "", subject: subject, date: Date(),
            snippet: "", bodyText: "", bodyHTML: nil, messageIdHeader: "",
            referencesHeader: "", labelIds: "INBOX", isUnread: false,
            hasAttachment: true).insert(db)
        try MessageBody(messageId: id, bodyText: body, bodyHTML: nil).insert(db)
    }

    private func foldAndTruncate(_ pool: DatabasePool) throws -> Bool {
        try pool.writeWithoutTransaction { db in
            try AppDatabase.foldAndTruncateLog(db, freePageLimit: AppDatabase.freePagesPerCheckpoint)
        }
    }

    // MARK: Bulk path

    /// Removing an account with many messages takes the bulk path (the
    /// cascade is one statement); its terms must still be gone.
    func testAccountRemovalOnTheBulkPathLeavesNoTerm() throws {
        let pool = try openUnkeyedPool()
        let term = marker("qxjbulkgone")
        let tail = String(term.dropFirst(3))
        let gone = SearchIndexDeletes.bulkThreshold + 100
        try pool.write { db in
            try insertAccount(db, "gone@example.com")
            try insertAccount(db, "kept@example.com")
            for i in 0..<gone {
                try insertMessage(db, account: "gone@example.com", gmailId: "m\(i)",
                                  subject: i == gone / 2 ? "About \(term)" : "Gone \(i)")
            }
            for i in 0..<50 {
                try insertMessage(db, account: "kept@example.com", gmailId: "m\(i)",
                                  subject: "Routine kept \(i)")
            }
        }
        XCTAssertTrue(SearchIndexDeletes.usesBulkPath(deleting: gone, of: gone + 50))
        try pool.write { db in try AccountLifecycle.purgeAccount(db, id: "gone@example.com") }
        try pool.read { db in
            XCTAssertFalse(try inSearchIndex(db, tail), "removed account's term in the index")
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT count(*) FROM message_fts WHERE message_fts MATCH 'routine'
                """), 50)
            XCTAssertEqual(try secureDeleteSetting(db), 1)
        }
        XCTAssertTrue(try foldAndTruncate(pool))
        XCTAssertFalse(try onDisk(tail))
        try pool.close()
    }

    /// A body that throws inside a transaction the caller still commits
    /// must not leave the index deleting insecurely.
    func testBulkDeleteThatThrowsRestoresSecureDelete() throws {
        let pool = try openUnkeyedPool()
        let count = SearchIndexDeletes.bulkThreshold + 10
        try pool.write { db in
            try insertAccount(db, "me@example.com")
            for i in 0..<count {
                try insertMessage(db, account: "me@example.com", gmailId: "m\(i)", subject: "S \(i)")
            }
        }
        struct Failed: Error {}
        try pool.write { db in
            XCTAssertThrowsError(try SearchIndexDeletes.deleting(db, messages: count) {
                try db.execute(sql: "DELETE FROM message")
                throw Failed()
            })
        }
        try pool.read { db in XCTAssertEqual(try secureDeleteSetting(db), 1) }
        try pool.close()
    }

    /// Whatever turned it off, opening the database turns it back on.
    func testOpeningTheDatabaseRestoresSecureDelete() throws {
        XCTAssertEqual(try AppDatabase.prepareDatabaseFile(path: path, key: key), .raw)
        var pool = try AppDatabase.openAndMigrate(path: path, key: key, scheme: .raw)
        try pool.write { db in
            try db.execute(sql: "INSERT INTO message_fts(message_fts, rank) VALUES('secure-delete', 0)")
        }
        try pool.read { db in XCTAssertEqual(try secureDeleteSetting(db), 0) }
        try pool.close()
        pool = try AppDatabase.openAndMigrate(path: path, key: key, scheme: .raw)
        try pool.read { db in XCTAssertEqual(try secureDeleteSetting(db), 1) }
        try pool.close()
    }

    // MARK: Log truncation

    func testStaleLogIsDueEvenWithoutADeletion() {
        let big = AppDatabase.checkpointThresholdBytes
        XCTAssertTrue(AppDatabase.checkpointIsDue(walBytes: big, sinceLastTruncation: 0, staleAfter: 300))
        XCTAssertTrue(AppDatabase.checkpointIsDue(walBytes: 4096, sinceLastTruncation: 301, staleAfter: 300))
        XCTAssertFalse(AppDatabase.checkpointIsDue(walBytes: 4096, sinceLastTruncation: 10, staleAfter: 300))
        XCTAssertFalse(AppDatabase.checkpointIsDue(walBytes: 0, sinceLastTruncation: 10_000, staleAfter: 300))
    }

    /// An update (text cleared from a draft) schedules nothing, but the
    /// post-sync check truncates a log that has been there too long.
    func testUpdatedDraftLeavesTheLogAtThePostSyncCheck() throws {
        let database = try AppDatabase(path: path, key: key, allowConversion: true,
                                       timing: .init(scrubDelay: 3_600, staleLogInterval: 0))
        defer { database.close() }
        database.runScheduledScrub()
        try database.dbPool.write { db in
            try insertAccount(db, "me@example.com")
            var draft = LocalDraft(
                id: nil, accountId: "me@example.com", fromEmail: "", toHeader: "",
                ccHeader: "", bccHeader: "", subject: "", body: "Text the user then cleared",
                replyToMessageId: nil, forward: false, replacingDraftId: nil,
                attachmentsJSON: Data("[]".utf8), createdAt: Date(), updatedAt: Date())
            draft = try draft.inserted(db)
            draft.body = ""
            try draft.update(db)
        }
        XCTAssertFalse(database.scrubIsPending)
        XCTAssertGreaterThan(database.walSizeBytes, 0)
        database.checkpointIfNeeded()
        XCTAssertEqual(database.walSizeBytes, 0)
    }

    /// Page images a crash left in the log go at the next open, with no
    /// deletion needed.
    func testOpeningAfterACrashTruncatesTheLeftoverLog() throws {
        // Copy a database while its writer still holds frames: what a crash
        // leaves on disk.
        let sourcePath = dir.appendingPathComponent("source.sqlite").path
        XCTAssertEqual(try AppDatabase.prepareDatabaseFile(path: sourcePath, key: key), .raw)
        let source = try AppDatabase.openAndMigrate(path: sourcePath, key: key, scheme: .raw)
        try source.write { db in
            try insertAccount(db, "me@example.com")
            try insertMessage(db, account: "me@example.com", gmailId: "m", subject: "S")
        }
        for suffix in ["", "-wal", "-shm"] {
            try FileManager.default.copyItem(atPath: sourcePath + suffix, toPath: path + suffix)
        }
        try source.close()

        let database = try AppDatabase(path: path, key: key, allowConversion: true,
                                       timing: .init(scrubDelay: 3_600))
        defer { database.close() }
        XCTAssertTrue(database.scrubIsPending)
        database.runScheduledScrub()
        XCTAssertEqual(database.walSizeBytes, 0)
        XCTAssertEqual(try database.dbPool.read { db in try Message.fetchCount(db) }, 1)
    }

    /// A reader holding a snapshot makes the ordinary checkpoint give up;
    /// the barrier one waits for it and completes.
    func testBarrierCheckpointIsNotStarvedByAReader() throws {
        let database = try AppDatabase(path: path, key: key, allowConversion: true,
                                       timing: .init(scrubDelay: 3_600))
        defer { database.close() }
        database.runScheduledScrub()
        try database.dbPool.write { db in
            try insertAccount(db, "me@example.com")
            try insertMessage(db, account: "me@example.com", gmailId: "m", subject: "S")
        }
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let readerDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? database.dbPool.read { db -> Int in
                let count = try Message.fetchCount(db)
                started.signal()
                release.wait()
                return count
            }
            readerDone.signal()
        }
        started.wait()
        XCTAssertFalse(database.checkpoint(), "a reader in the log makes it busy")

        var truncated = false
        let barrierDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            truncated = database.checkpoint(waitForReaders: true)
            barrierDone.signal()
        }
        Thread.sleep(forTimeInterval: 0.2)
        release.signal()
        XCTAssertEqual(barrierDone.wait(timeout: .now() + 20), .success)
        XCTAssertEqual(readerDone.wait(timeout: .now() + 20), .success)
        XCTAssertTrue(truncated)
        XCTAssertEqual(database.walSizeBytes, 0)
    }

    // MARK: Copies outside the database

    func testDeletedMessagesAreQueuedWithTheirIds() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue)
        try queue.write { db in
            try insertAccount(db, "me@example.com")
            try insertMessage(db, account: "me@example.com", gmailId: "g1", subject: "S")
            try insertMessage(db, account: "me@example.com", gmailId: "g2", subject: "S")
            try SyncEngine.pruneMessages(db, accountId: "me@example.com", olderThan: nil)
        }
        let items = try queue.read { db in try DeletedMessageResidue.pending(db) }
        XCTAssertEqual(items.map(\.gmailId).sorted(), ["g1", "g2"])
        XCTAssertEqual(Set(items.map(\.threadId)),
                       ["me@example.com:t-g1", "me@example.com:t-g2"])
        try queue.write { db in try DeletedMessageResidue.forget(db, items) }
        XCTAssertEqual(try queue.read { db in try DeletedMessageResidue.pending(db) }, [])
    }

    /// The scrub hands what is gone to the app, then empties the queue.
    func testScrubHandsDeletedMailToTheApp() throws {
        let database = try AppDatabase(path: path, key: key, allowConversion: true,
                                       timing: .init(scrubDelay: 3_600))
        defer { database.close() }
        let seen = Seen()
        database.deletedMessageHandler = { seen.add($0) }
        try database.dbPool.write { db in
            try insertAccount(db, "me@example.com")
            try insertMessage(db, account: "me@example.com", gmailId: "g1", subject: "S")
        }
        try database.dbPool.write { db in
            _ = try Message.deleteOne(db, key: "me@example.com:g1")
        }
        database.runScheduledScrub()
        XCTAssertEqual(seen.removals, [DeletedMessageResidue.Removal(
            messages: [.init(accountId: "me@example.com", gmailId: "g1")],
            threads: [.init(accountId: "me@example.com", threadId: "me@example.com:t-g1")])])
        XCTAssertEqual(try database.dbPool.read { db in try DeletedMessageResidue.pending(db) }, [])
    }

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [DeletedMessageResidue.Removal] = []
        func add(_ removal: DeletedMessageResidue.Removal) { lock.lock(); stored.append(removal); lock.unlock() }
        var removals: [DeletedMessageResidue.Removal] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    private func message(_ account: String, _ gmailId: String, thread: String) -> Message {
        Message(id: "\(account):\(gmailId)", accountId: account, gmailId: gmailId,
                threadId: "\(account):\(thread)", fromHeader: "a@example.com", toHeader: account,
                ccHeader: "", subject: "S", date: Date(), snippet: "", bodyText: "",
                bodyHTML: nil, messageIdHeader: "", referencesHeader: "", labelIds: "INBOX",
                isUnread: false, hasAttachment: true)
    }

    private func removal(_ queue: DatabaseQueue) throws -> DeletedMessageResidue.Removal {
        try queue.read { db in
            try DeletedMessageResidue.removal(db, for: try DeletedMessageResidue.pending(db))
        }
    }

    /// A draft autosave replaces the draft's row; the thread (with its new
    /// mail notification) is still there, and so is everything else in it.
    func testDraftSwapInALiveThreadRemovesNothingOfTheThread() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue)
        try queue.write { db in
            try insertAccount(db, "me@example.com")
            try message("me@example.com", "incoming", thread: "t1").insert(db)
            try message("me@example.com", "draft-1", thread: "t1").insert(db)
            // The autosave: the new draft row in, the old one out.
            try message("me@example.com", "draft-2", thread: "t1").insert(db)
            _ = try Message.deleteOne(db, key: "me@example.com:draft-1")
        }
        let result = try removal(queue)
        XCTAssertEqual(result.threads, [], "the thread's notification must stay")
        XCTAssertEqual(result.messages, [.init(accountId: "me@example.com", gmailId: "draft-1")],
                       "only the replaced draft's copies go")
    }

    /// One message of a multi-message thread: its copies go, the thread's
    /// notifications stay.
    func testOneMessageOfAThreadKeepsTheThreadsNotifications() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue)
        try queue.write { db in
            try insertAccount(db, "me@example.com")
            try message("me@example.com", "a", thread: "t1").insert(db)
            try message("me@example.com", "b", thread: "t1").insert(db)
            _ = try Message.deleteOne(db, key: "me@example.com:a")
        }
        let result = try removal(queue)
        XCTAssertEqual(result.messages, [.init(accountId: "me@example.com", gmailId: "a")])
        XCTAssertEqual(result.threads, [])
    }

    /// Pruned, then synced again before the drain: the message is back, and
    /// its attachment copy (perhaps open) must stay.
    func testMessageSyncedAgainBeforeTheDrainKeepsItsCopies() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue)
        try queue.write { db in
            try insertAccount(db, "me@example.com")
            try message("me@example.com", "g1", thread: "t1").insert(db)
            try SyncEngine.pruneMessages(db, accountId: "me@example.com", olderThan: nil)
            try message("me@example.com", "g1", thread: "t1").insert(db)
        }
        XCTAssertTrue(try removal(queue).isEmpty)
    }

    /// The removal of an account clears its queued ids (it deletes its
    /// copies wholesale); orphans of earlier removals go at launch.
    func testAccountRemovalAndLaunchSweepClearTheQueue() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue)
        try queue.write { db in
            try insertAccount(db, "gone@example.com")
            try insertAccount(db, "kept@example.com")
            try message("gone@example.com", "g1", thread: "t1").insert(db)
            try message("kept@example.com", "k1", thread: "t1").insert(db)
            _ = try Message.deleteOne(db, key: "kept@example.com:k1")
            try AccountLifecycle.purgeAccount(db, id: "gone@example.com")
            // A row an earlier build's removal left behind.
            try db.execute(sql: """
                INSERT INTO deletedMessage (accountId, gmailId, threadId)
                VALUES ('old@example.com', 'o1', 'old@example.com:t1')
                """)
            try AccountLifecycle.purgeOrphanRows(db)
        }
        let left = try queue.read { db in try DeletedMessageResidue.pending(db) }
        XCTAssertEqual(left.map(\.accountId), ["kept@example.com"])
    }

    /// The quit path drains during shutdown; a scrub firing then does not.
    func testOnlyTheQuitPathDrainsDuringShutdown() throws {
        let database = try AppDatabase(path: path, key: key, allowConversion: true,
                                       timing: .init(scrubDelay: 3_600))
        defer { database.close() }
        let seen = Seen()
        database.deletedMessageHandler = { seen.add($0) }
        try database.dbPool.write { db in
            try insertAccount(db, "me@example.com")
            try insertMessage(db, account: "me@example.com", gmailId: "g1", subject: "S")
        }
        try database.dbPool.write { db in _ = try Message.deleteOne(db, key: "me@example.com:g1") }
        database.beginShutdown()
        database.runScheduledScrub()
        XCTAssertEqual(seen.removals, [], "no drain while the pool shuts down")
        database.drainDeletedMessages(force: true)
        XCTAssertEqual(seen.removals.count, 1, "the quit path drains")
    }

    func testDeletedMessageCopiesAreRemovedOneByOne() throws {
        let root = dir.appendingPathComponent("attachments", isDirectory: true)
        let fm = FileManager.default
        for gmailId in ["gone", "kept"] {
            let folder = AttachmentCache.messageDirectory(
                root: root, accountId: "me@example.com", gmailMessageId: gmailId, attachmentRowId: 1)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("copy".utf8).write(to: folder.appendingPathComponent("file.pdf"))
        }
        XCTAssertTrue(AttachmentCache.removeMessage(accountId: "me@example.com",
                                                    gmailMessageId: "gone", root: root))
        let account = root.appendingPathComponent(AttachmentCache.accountFolderName("me@example.com"))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: account.path), ["kept"])

        // The launch sweep: everything not in the keep set goes.
        XCTAssertTrue(AttachmentCache.removeMessages(ofAccount: "me@example.com",
                                                     keeping: [], root: root))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: account.path), [])
    }

    func testCachedMessageFoldersListOnlyMessagesStillThere() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue)
        let folders = try queue.write { db -> [String: Set<String>] in
            try insertAccount(db, "me@example.com")
            try insertMessage(db, account: "me@example.com", gmailId: "g1", subject: "S")
            return try AttachmentCache.cachedMessageFolders(db, accounts: ["me@example.com"])
        }
        XCTAssertEqual(folders, ["me@example.com": ["g1"]])
    }

    /// The identifiers withdrawn for a deleted thread are the ones its
    /// notifications were posted under.
    func testThreadNotificationIdentifiersMatchThePostedOnes() {
        let item = NotificationContent.MailItem(accountId: "me@example.com",
                                                threadId: "me@example.com:t1",
                                                sender: "A", subject: "B")
        let posted = NotificationContent.newMail([item], detailAccounts: [], salt: "s").map(\.id)
            + NotificationContent.reminders([item], detailAccounts: ["me@example.com"], salt: "s").map(\.id)
        let withdrawn = NotificationContent.threadIdentifiers(
            accountId: "me@example.com", threadId: "me@example.com:t1", salt: "s")
        XCTAssertEqual(Set(withdrawn), Set(posted))
    }

    // MARK: Legacy HTTP cache

    func testLegacyHTTPCacheFilesAreDeletedAndTheCacheIsDiskless() throws {
        let caches = dir.appendingPathComponent("Caches", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: caches.appendingPathComponent("fsCachedData"),
                               withIntermediateDirectories: true)
        for name in ["Cache.db", "Cache.db-wal", "Cache.db-shm", "other.plist"] {
            try Data("x".utf8).write(to: caches.appendingPathComponent(name))
        }
        LegacyHTTPCache.removeFiles(in: caches)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: caches.path), ["other.plist"])
        XCTAssertEqual(LegacyHTTPCache.makeDiskless().diskCapacity, 0)
    }
}
