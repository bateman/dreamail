import XCTest
import GRDB

/// The persistent, encrypted inline-image cache (`InlineImageCache`,
/// `InlineImageStore`, `CIDPartResolver`): a conversation whose `cid:`
/// images were resolved once opens with them, after a relaunch too, with no
/// attachment request; and what is deleted takes its images with it.
final class InlineImageCacheTests: XCTestCase {
    private var dir: URL!
    private var path: String { dir.appendingPathComponent("mail.sqlite").path }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dreamail-inlineimage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Fixtures

    private let me = "me@example.com"
    private let other = "other@example.com"

    private func openPool() throws -> DatabasePool {
        let pool = try DatabasePool(path: path)
        try AppDatabase.migrator.migrate(pool)
        return pool
    }

    private func png(_ seed: UInt8, count: Int = 64) -> Data {
        Data([0x89, 0x50, 0x4E, 0x47] + (0..<count).map { UInt8(truncatingIfNeeded: Int($0) &+ Int(seed)) })
    }

    private func html(_ cids: [String]) -> String {
        "<p>Hello</p>" + cids.map { "<img src=\"cid:\($0)\">" }.joined()
    }

    private func addAccount(_ db: Database, _ id: String) throws {
        if try !Account.exists(db, key: id) {
            try Account(id: id, displayName: id, historyId: nil,
                        lastSyncAt: nil, senderName: "").insert(db)
        }
    }

    /// One message with `cids` inline image parts; returns the attachment
    /// rows as stored (with ids).
    @discardableResult
    private func addMessage(_ db: Database, account: String, gmailId: String,
                            thread: String = "t1", cids: [String],
                            body: String? = nil, date: Date = Date(),
                            mime: String = "image/png") throws -> [AttachmentRow] {
        try addAccount(db, account)
        let id = "\(account):\(gmailId)"
        let message = Message(
            id: id, accountId: account, gmailId: gmailId, threadId: "\(account):\(thread)",
            fromHeader: "A <a@example.com>", toHeader: account, ccHeader: "",
            subject: "Subject", date: date, snippet: "", bodyText: "Hello",
            bodyHTML: body ?? html(cids), messageIdHeader: "<\(gmailId)@example.com>",
            referencesHeader: "", labelIds: "INBOX", isUnread: false, hasAttachment: false)
        let attachments = cids.enumerated().map { index, cid in
            AttachmentRow(id: nil, messageId: id, gmailAttachmentId: "att-\(gmailId)-\(index)",
                          filename: "\(cid).png", mimeType: mime, size: 64, contentId: cid)
        }
        _ = try SyncEngine.upsertPending(
            db, items: [.init(message: message, attachments: attachments, headersOnly: false)])
        try SyncEngine.deriveThreads(db, for: [message.threadId], accountId: account)
        return try AttachmentRow.filter(Column("messageId") == id).order(Column("id")).fetchAll(db)
    }

    private func message(_ db: Database, _ id: String) throws -> Message {
        var message = try XCTUnwrap(Message.fetchOne(db, key: id))
        let body = try MessageBody.fetchOne(db, key: id)
        message.bodyHTML = body?.bodyHTML
        message.bodyText = body?.bodyText ?? ""
        return message
    }

    private func byCID(_ rows: [AttachmentRow]) -> [String: AttachmentRow] {
        Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            row.contentId.map { (CIDImageInliner.normalize($0), row) }
        })
    }

    /// Counts the attachment requests a resolve makes.
    final class Fetcher: @unchecked Sendable {
        private let lock = NSLock()
        private var served: [String] = []
        private let failing: Set<String>
        private let bytes: @Sendable (AttachmentRow) -> Data
        init(failing: Set<String> = [], bytes: @escaping @Sendable (AttachmentRow) -> Data) {
            self.failing = failing
            self.bytes = bytes
        }
        var requests: [String] { lock.withLock { served } }
        func fetch(_ row: AttachmentRow) throws -> Data {
            lock.withLock { served.append(row.gmailAttachmentId) }
            if failing.contains(row.gmailAttachmentId) { throw URLError(.timedOut) }
            return bytes(row)
        }
    }

    /// The app's own resolve path (`MailStore.inlineCIDImages` calls the
    /// same function), with `fetcher` standing in for Gmail.
    private func resolve(_ store: InlineImageStore, message: Message,
                         attachments: [AttachmentRow], fetcher: Fetcher)
        async -> CIDPartResolver.Outcome {
        let body = message.bodyHTML ?? ""
        return await CIDPartResolver.resolveUsingCache(
            messageId: message.id, accountId: message.accountId, bodyHTML: body,
            references: CIDImageInliner.referencedIDs(in: body),
            attachmentsByCID: byCID(attachments), didRefetch: false, store: store
        ) { try fetcher.fetch($0) }
    }

    private func lookup(_ message: Message, account: String? = nil) -> InlineImageCache.Lookup {
        InlineImageCache.Lookup(messageId: message.id, accountId: account ?? message.accountId,
                                bodyHTML: message.bodyHTML ?? "")
    }

    private func lastUsed(_ pool: DatabasePool, _ messageId: String) throws -> [Double] {
        try pool.read { db in
            try Double.fetchAll(db, sql: "SELECT lastUsedAt FROM inlineImage WHERE messageId = ?",
                                arguments: [messageId])
        }
    }

    /// Synchronous on purpose: callable from the async tests.
    private func close(_ pool: DatabasePool) throws {
        try pool.close()
    }

    private func rowCount(_ pool: DatabasePool, messageId: String? = nil) throws -> Int {
        try pool.read { db in
            if let messageId {
                return try Int.fetchOne(db, sql: "SELECT count(*) FROM inlineImage WHERE messageId = ?",
                                        arguments: [messageId]) ?? 0
            }
            return try Int.fetchOne(db, sql: "SELECT count(*) FROM inlineImage") ?? 0
        }
    }

    /// Resolve and store `gmailId`'s images through a fresh store.
    private func cache(_ pool: DatabasePool, account: String? = nil, gmailId: String,
                       seed: UInt8 = 1) async throws {
        let account = account ?? me
        let (msg, rows) = try await pool.read { db in
            (try self.message(db, "\(account):\(gmailId)"),
             try AttachmentRow.filter(Column("messageId") == "\(account):\(gmailId)").fetchAll(db))
        }
        let store = InlineImageStore(db: pool, flushDelayNanoseconds: 1_000_000)
        _ = await resolve(store, message: msg, attachments: rows,
                          fetcher: Fetcher { _ in self.png(seed) })
        await store.flush()
        await store.shutDown()
    }

    // MARK: Relaunch

    /// Resolve once, quit, open the same database again: the payload of the
    /// first open already carries the images, and resolving makes no
    /// attachment request.
    func testImagesResolvedBeforeARelaunchOpenWithNoAttachmentRequest() async throws {
        let pool = try openPool()
        let rows = try await pool.write { db in
            try self.addMessage(db, account: self.me, gmailId: "m1", cids: ["logo", "sig"])
        }
        let first = InlineImageStore(db: pool, flushDelayNanoseconds: 1_000_000)
        let firstMessage = try await pool.read { db in try self.message(db, "\(self.me):m1") }
        let firstFetcher = Fetcher { row in self.png(row.contentId == "logo" ? 1 : 2) }
        let outcome = await resolve(first, message: firstMessage, attachments: rows,
                                    fetcher: firstFetcher)
        XCTAssertEqual(firstFetcher.requests.count, 2, "the first open downloads both parts")
        XCTAssertEqual(outcome.parts.count, 2)
        await first.flush()
        await first.shutDown()
        try close(pool)

        // Relaunch: a new pool, a new store, a new repository. What the
        // neighbour prefetch does: the text payload, then the cached images.
        let relaunched = try openPool()
        let store = InlineImageStore(db: relaunched)
        let repository = ThreadDetailRepository(db: relaunched, inlineImages: store)
        let revision = ThreadContentRevisions().revision(of: "\(me):t1")
        let cold = await repository.payload(
            threadId: "\(me):t1", suppressingDrafts: [], revision: revision)
        XCTAssertFalse(cold.cacheHit)
        XCTAssertTrue(cold.payload.cidInlineByMessageId.isEmpty, "payload() stays text only")
        let warmed = await repository.warmCachedCIDBodies(
            threadId: "\(me):t1", revision: revision, fontScale: 1.0)
        XCTAssertEqual(Set(warmed.keys), ["\(me):m1"])
        let load = await repository.payload(
            threadId: "\(me):t1", suppressingDrafts: [], revision: revision)
        XCTAssertTrue(load.cacheHit)
        let body = try XCTUnwrap(load.payload.cidInlineByMessageId["\(me):m1"],
                                 "the warmed payload carries the inlined body")
        XCTAssertFalse(CIDImageInliner.containsCIDReferences(body.html))
        XCTAssertTrue(body.html.contains(CIDImageInliner.dataURI(mimeType: "image/png", data: png(1))))
        XCTAssertTrue(body.html.contains(CIDImageInliner.dataURI(mimeType: "image/png", data: png(2))))
        XCTAssertNotNil(body.prep.documents?.fullBlocked, "documents built off the main actor")
        let seed = CIDInlineSeed.seed(from: load.payload, fontScale: 1.0)
        XCTAssertEqual(seed.resolvedIds, ["\(me):m1"], "the pane never asks Gmail")

        // The pane's own resolve (e.g. after a font-scale change) hits the
        // cache too.
        let fetcher = Fetcher { _ in XCTFail("no attachment request"); return Data() }
        let message = try await relaunched.read { db in try self.message(db, "\(self.me):m1") }
        let again = await resolve(store, message: message, attachments: rows, fetcher: fetcher)
        XCTAssertEqual(fetcher.requests, [])
        XCTAssertEqual(again.fetchedCount, 0)
        XCTAssertEqual(again.parts.count, 2)
        await store.flush()
        let writes = await store.writeTransactionCount
        XCTAssertEqual(writes, 0, "a hit used within the day writes nothing")
        await store.shutDown()
    }

    /// A cold `payload()` reads no image and changes nothing in the cache.
    func testAColdPayloadDoesNoImageWork() async throws {
        let pool = try openPool()
        _ = try await pool.write { db in try self.addMessage(db, account: self.me, gmailId: "m1", cids: ["logo"]) }
        try await cache(pool, gmailId: "m1")
        let before = try lastUsed(pool, "\(me):m1")
        let store = InlineImageStore(db: pool, flushDelayNanoseconds: 1_000_000)
        let load = await ThreadDetailRepository(db: pool, inlineImages: store).payload(
            threadId: "\(me):t1", suppressingDrafts: [],
            revision: ThreadContentRevisions().revision(of: "\(me):t1"))
        XCTAssertTrue(load.payload.cidInlineByMessageId.isEmpty)
        await store.flush()
        let writes = await store.writeTransactionCount
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(try lastUsed(pool, "\(me):m1"), before)
        await store.shutDown()
    }

    /// The prefetch path (`warmCachedCIDBodies`) never marks images as used;
    /// a shown message is marked at most once a day.
    func testPrefetchDoesNotTouchAndRepeatedOpensWithinADayDoNotWrite() async throws {
        let pool = try openPool()
        _ = try await pool.write { db in try self.addMessage(db, account: self.me, gmailId: "m1", cids: ["logo"]) }
        try await cache(pool, gmailId: "m1")
        let stored = try lastUsed(pool, "\(me):m1")

        let store = InlineImageStore(db: pool, flushDelayNanoseconds: 1_000_000)
        let repository = ThreadDetailRepository(db: pool, inlineImages: store)
        let revision = ThreadContentRevisions().revision(of: "\(me):t1")
        _ = await repository.payload(threadId: "\(me):t1", suppressingDrafts: [], revision: revision)
        let warmed = await repository.warmCachedCIDBodies(
            threadId: "\(me):t1", revision: revision, fontScale: 1.0)
        XCTAssertFalse(warmed.isEmpty)
        // Shown three times within the day.
        for _ in 0..<3 {
            await store.noteUsed(["\(me):m1"])
            await store.flush()
        }
        let writes = await store.writeTransactionCount
        XCTAssertEqual(writes, 0, "no write: the mark is younger than a day")
        XCTAssertEqual(try lastUsed(pool, "\(me):m1"), stored)
        await store.shutDown()

        // Two days later the first open writes once, the next ones nothing.
        let later = Date().addingTimeInterval(2 * 86_400)
        let next = InlineImageStore(db: pool, flushDelayNanoseconds: 1_000_000, now: { later })
        for _ in 0..<3 {
            await next.noteUsed(["\(me):m1"])
            await next.flush()
        }
        let laterWrites = await next.writeTransactionCount
        XCTAssertEqual(laterWrites, 1)
        XCTAssertEqual(try lastUsed(pool, "\(me):m1"), [later.timeIntervalSinceReferenceDate])
        await next.shutDown()
    }

    func testRepositoryWithoutTheStoreReadsNoImages() async throws {
        let pool = try openPool()
        _ = try await pool.write { db in try self.addMessage(db, account: self.me, gmailId: "m1", cids: ["logo"]) }
        try await cache(pool, gmailId: "m1")
        let load = await ThreadDetailRepository(db: pool).payload(
            threadId: "\(me):t1", suppressingDrafts: [],
            revision: ThreadContentRevisions().revision(of: "\(me):t1"))
        XCTAssertTrue(load.payload.cidInlineByMessageId.isEmpty)
    }

    // MARK: Complete results only

    func testAPartialResultIsNotStoredAndTheFailedPartIsRetried() async throws {
        let pool = try openPool()
        let rows = try await pool.write { db in
            try self.addMessage(db, account: self.me, gmailId: "m1", cids: ["a", "b"])
        }
        let message = try await pool.read { db in try self.message(db, "\(self.me):m1") }
        let store = InlineImageStore(db: pool, flushDelayNanoseconds: 1_000_000)
        let failing = Fetcher(failing: ["att-m1-1"]) { _ in self.png(1) }
        let partial = await resolve(store, message: message, attachments: rows, fetcher: failing)
        XCTAssertEqual(partial.parts.count, 1)
        await store.flush()
        XCTAssertEqual(try rowCount(pool), 0, "a partial result is not stored")

        let retry = Fetcher { _ in self.png(1) }
        _ = await resolve(store, message: message, attachments: rows, fetcher: retry)
        XCTAssertEqual(retry.requests.count, 2, "nothing was kept: both parts are asked again")
        await store.flush()
        XCTAssertEqual(try rowCount(pool), 2)
        await store.shutDown()
    }

    func testPolicyRefusesIncompleteRefetchedEmptyOversizedOrUnsavedResults() {
        func part(_ cid: String, bytes: Int = 10, id: Int64 = 1) -> InlineImageCache.Part {
            .init(attachmentId: id, contentId: cid, mimeType: "image/png",
                  data: Data(repeating: 1, count: bytes))
        }
        func ok(_ refs: Set<String>, _ parts: [String: InlineImageCache.Part],
                refetch: Bool = false, storable: Bool = true) -> Bool {
            InlineImageCachePolicy.shouldStore(
                references: refs,
                outcome: .init(parts: parts, fetchedCount: parts.count, allStorable: storable),
                didRefetch: refetch)
        }
        XCTAssertTrue(ok(["a"], ["a": part("a")]))
        XCTAssertFalse(ok(["a", "b"], ["a": part("a")]), "incomplete")
        XCTAssertFalse(ok(["a"], ["a": part("a")], refetch: true), "re-fetched")
        XCTAssertFalse(ok(["a"], ["a": part("a", bytes: 0)]), "empty")
        XCTAssertFalse(ok(["a"], ["a": part("a", id: CIDPartResolver.unsavedAttachmentId)]),
                       "no attachment row")
        XCTAssertFalse(ok(["a"], ["a": part("a")], storable: false), "SVG or relabelled type")
        let half = InlineImageCache.perMessageBytes / 2
        XCTAssertTrue(ok(["a", "b"], ["a": part("a", bytes: half), "b": part("b", bytes: half, id: 2)]),
                      "exactly the cap")
        XCTAssertFalse(ok(["a", "b"], ["a": part("a", bytes: half), "b": part("b", bytes: half + 1, id: 2)]),
                       "over the per-message cap")
    }

    func testOnlyRasterImageTypesAreStoredAndTheTypeIsSanitized() async throws {
        XCTAssertTrue(InlineImageCache.isStorableMIME("image/png"))
        XCTAssertTrue(InlineImageCache.isStorableMIME("IMAGE/GIF; name=x.gif"))
        XCTAssertFalse(InlineImageCache.isStorableMIME("image/svg+xml"))
        XCTAssertFalse(InlineImageCache.isStorableMIME("text/html"))
        XCTAssertFalse(InlineImageCache.isStorableMIME("image/x<script>"))

        let pool = try openPool()
        try await pool.write { db in
            try self.addMessage(db, account: self.me, gmailId: "svg", thread: "s", cids: ["logo"],
                                mime: "image/svg+xml")
            try self.addMessage(db, account: self.me, gmailId: "gif", thread: "g", cids: ["logo"],
                                mime: "IMAGE/GIF; name=logo.gif")
        }
        try await cache(pool, gmailId: "svg")
        try await cache(pool, gmailId: "gif")
        XCTAssertEqual(try rowCount(pool, messageId: "\(me):svg"), 0, "SVG is never stored")
        try await pool.read { db in
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT DISTINCT mimeType FROM inlineImage"),
                           ["image/gif"])
        }
        // A forged write of the SVG part, relabelled or not, is refused by
        // the store itself.
        try await pool.write { db in
            let msg = try self.message(db, "\(self.me):svg")
            let attachmentId = try XCTUnwrap(try Int64.fetchOne(
                db, sql: "SELECT id FROM attachment WHERE messageId = ?", arguments: [msg.id]))
            for mime in ["image/jpeg", "image/svg+xml"] {
                XCTAssertFalse(try InlineImageCache.store(db, .init(
                    messageId: msg.id, accountId: self.me,
                    bodyDigest: InlineImageCache.bodyDigest(msg.bodyHTML!),
                    parts: [.init(attachmentId: attachmentId, contentId: "logo",
                                  mimeType: mime, data: self.png(1))]), now: Date()), mime)
            }
        }
        XCTAssertEqual(try rowCount(pool, messageId: "\(me):svg"), 0)
    }

    func testStoreRefusesAMessageOverThePerMessageCap() throws {
        let pool = try openPool()
        try pool.write { db in
            let rows = try self.addMessage(db, account: self.me, gmailId: "m1", cids: ["a"])
            let body = try XCTUnwrap(try MessageBody.fetchOne(db, key: "\(self.me):m1")?.bodyHTML)
            let big = InlineImageCache.Pending(
                messageId: "\(self.me):m1", accountId: self.me,
                bodyDigest: InlineImageCache.bodyDigest(body),
                parts: [.init(attachmentId: rows[0].id!, contentId: "a", mimeType: "image/png",
                              data: Data(repeating: 7, count: InlineImageCache.perMessageBytes + 1))])
            XCTAssertFalse(try InlineImageCache.store(db, big, now: Date()))
        }
        XCTAssertEqual(try rowCount(pool), 0)
    }

    // MARK: Isolation

    /// Content-IDs are the sender's choice: the same one in two messages, of
    /// one account or two, never serves the other message's bytes.
    func testSameContentIdInTwoMessagesAndAccountsStaysApart() async throws {
        let pool = try openPool()
        try await pool.write { db in
            try self.addMessage(db, account: self.me, gmailId: "m1", cids: ["logo"])
            try self.addMessage(db, account: self.me, gmailId: "m2", thread: "t2", cids: ["logo"])
            try self.addMessage(db, account: self.other, gmailId: "m1", cids: ["logo"])
        }
        try await cache(pool, gmailId: "m1", seed: 1)
        try await pool.read { db in
            let m2 = try self.message(db, "\(self.me):m2")
            XCTAssertTrue(try InlineImageCache.parts(db, self.lookup(m2)).isEmpty)
            let theirs = try self.message(db, "\(self.other):m1")
            XCTAssertTrue(try InlineImageCache.parts(db, self.lookup(theirs)).isEmpty)
            // Asking for m1's rows under another account finds nothing.
            let mine = try self.message(db, "\(self.me):m1")
            XCTAssertTrue(try InlineImageCache.parts(db, self.lookup(mine, account: self.other)).isEmpty)
        }
        try await cache(pool, gmailId: "m2", seed: 2)
        try await cache(pool, account: other, gmailId: "m1", seed: 3)
        try await pool.read { db in
            for (account, gmailId, seed) in [(self.me, "m1", UInt8(1)), (self.me, "m2", 2), (self.other, "m1", 3)] {
                let msg = try self.message(db, "\(account):\(gmailId)")
                let parts = try InlineImageCache.parts(db, self.lookup(msg))
                XCTAssertEqual(parts["logo"]?.data, self.png(seed), "\(account) \(gmailId)")
            }
        }
    }

    /// A row stored for one attachment row is not served for another, and a
    /// write naming an attachment of another message is refused.
    func testStoreRefusesAPartOfAnotherMessage() throws {
        let pool = try openPool()
        try pool.write { db in
            try self.addMessage(db, account: self.me, gmailId: "m1", cids: ["logo"])
            let theirs = try self.addMessage(db, account: self.me, gmailId: "m2", thread: "t2", cids: ["logo"])
            let body = try XCTUnwrap(try MessageBody.fetchOne(db, key: "\(self.me):m1")?.bodyHTML)
            let forged = InlineImageCache.Pending(
                messageId: "\(self.me):m1", accountId: self.me,
                bodyDigest: InlineImageCache.bodyDigest(body),
                parts: [.init(attachmentId: theirs[0].id!, contentId: "logo",
                              mimeType: "image/png", data: self.png(9))])
            XCTAssertFalse(try InlineImageCache.store(db, forged, now: Date()))
        }
        XCTAssertEqual(try rowCount(pool), 0)
    }

    // MARK: Deletion

    func testDeletingTheMessageDeletesItsImages() async throws {
        let pool = try openPool()
        try await pool.write { db in
            try self.addMessage(db, account: self.me, gmailId: "m1", cids: ["logo"])
            try self.addMessage(db, account: self.me, gmailId: "m2", cids: ["logo"])
        }
        try await cache(pool, gmailId: "m1")
        try await cache(pool, gmailId: "m2")
        try await pool.write { db in
            _ = try SyncEngine.deleteLocalMessage(db, messageId: "\(self.me):m1",
                                                  threadId: "\(self.me):t1", accountId: self.me)
        }
        XCTAssertEqual(try rowCount(pool, messageId: "\(me):m1"), 0)
        XCTAssertEqual(try rowCount(pool, messageId: "\(me):m2"), 1, "the rest of the thread keeps its")
    }

    func testDeletingTheThreadDeletesItsImages() async throws {
        let pool = try openPool()
        try await pool.write { db in
            try self.addMessage(db, account: self.me, gmailId: "m1", cids: ["logo"])
            try self.addMessage(db, account: self.me, gmailId: "m2", cids: ["logo"])
            try self.addMessage(db, account: self.me, gmailId: "k1", thread: "kept", cids: ["logo"])
        }
        for id in ["m1", "m2", "k1"] { try await cache(pool, gmailId: id) }
        try await pool.write { db in
            for id in ["m1", "m2"] {
                _ = try SyncEngine.deleteLocalMessage(db, messageId: "\(self.me):\(id)",
                                                      threadId: "\(self.me):t1", accountId: self.me)
            }
            XCTAssertNil(try MailThread.fetchOne(db, key: "\(self.me):t1"))
        }
        XCTAssertEqual(try rowCount(pool), 1)
        XCTAssertEqual(try rowCount(pool, messageId: "\(me):k1"), 1)
    }

    /// The sync engine's delete path (Gmail-side deletions).
    func testSyncDeleteRemovesItsImages() async throws {
        let pool = try openPool()
        try await pool.write { db in
            try self.addMessage(db, account: self.me, gmailId: "m1", cids: ["logo"])
            try self.addMessage(db, account: self.me, gmailId: "k1", thread: "kept", cids: ["logo"])
        }
        try await cache(pool, gmailId: "m1")
        try await cache(pool, gmailId: "k1")
        _ = try await pool.write { db in
            try SyncEngine.deleteMessages(db, localIds: ["\(self.me):m1"])
        }
        XCTAssertEqual(try rowCount(pool, messageId: "\(me):m1"), 0)
        XCTAssertEqual(try rowCount(pool, messageId: "\(me):k1"), 1)
    }

    func testPruningOldMailDeletesItsImages() async throws {
        let pool = try openPool()
        try await pool.write { db in
            try self.addMessage(db, account: self.me, gmailId: "old", thread: "old", cids: ["logo"],
                                date: Date().addingTimeInterval(-200 * 86_400))
            try self.addMessage(db, account: self.me, gmailId: "new", cids: ["logo"])
        }
        try await cache(pool, gmailId: "old")
        try await cache(pool, gmailId: "new")
        try await pool.write { db in
            try SyncEngine.pruneMessages(db, accountId: self.me,
                                         olderThan: Date().addingTimeInterval(-90 * 86_400))
        }
        XCTAssertEqual(try rowCount(pool, messageId: "\(me):old"), 0)
        XCTAssertEqual(try rowCount(pool, messageId: "\(me):new"), 1)
    }

    func testRemovingTheAccountDeletesOnlyItsImages() async throws {
        let pool = try openPool()
        try await pool.write { db in
            try self.addMessage(db, account: self.me, gmailId: "m1", cids: ["logo"])
            try self.addMessage(db, account: self.other, gmailId: "m1", cids: ["logo"])
        }
        try await cache(pool, gmailId: "m1")
        try await cache(pool, account: other, gmailId: "m1")
        try await pool.write { db in try AccountLifecycle.purgeAccount(db, id: self.me) }
        try await pool.read { db in
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT accountId FROM inlineImage"),
                           [self.other])
        }
    }

    func testNewContentForTheMessageDeletesItsImages() async throws {
        let pool = try openPool()
        _ = try await pool.write { db in try self.addMessage(db, account: self.me, gmailId: "m1", cids: ["logo"]) }
        try await cache(pool, gmailId: "m1")
        XCTAssertEqual(try rowCount(pool), 1)
        // A full re-fetch (new revision) rewrites the body and attachment rows.
        _ = try await pool.write { db in
            try self.addMessage(db, account: self.me, gmailId: "m1", cids: ["logo"],
                                body: "<p>Edited</p><img src=\"cid:logo\">")
        }
        XCTAssertEqual(try rowCount(pool), 0)
    }

    /// Defence in depth: a body changed under the rows (no re-fetch path
    /// does this) is a miss, never stale images.
    func testABodyThatChangedUnderTheRowsIsAMiss() async throws {
        let pool = try openPool()
        _ = try await pool.write { db in try self.addMessage(db, account: self.me, gmailId: "m1", cids: ["logo"]) }
        try await cache(pool, gmailId: "m1")
        try await pool.write { db in
            try db.execute(sql: "UPDATE message_body SET bodyHTML = ? WHERE messageId = ?",
                           arguments: ["<img src=\"cid:logo\"> changed", "\(self.me):m1"])
        }
        try await pool.read { db in
            let msg = try self.message(db, "\(self.me):m1")
            XCTAssertTrue(try InlineImageCache.completeParts(db, [self.lookup(msg)]).isEmpty)
        }
    }

    /// A result queued for a message that is deleted before the write lands
    /// is not written (no row comes back after the delete).
    func testAQueuedResultForADeletedMessageIsNotWritten() async throws {
        let pool = try openPool()
        let rows = try await pool.write { db in
            try self.addMessage(db, account: self.me, gmailId: "m1", cids: ["logo"])
        }
        let message = try await pool.read { db in try self.message(db, "\(self.me):m1") }
        let store = InlineImageStore(db: pool, flushDelayNanoseconds: 60_000_000_000)
        _ = await resolve(store, message: message, attachments: rows, fetcher: Fetcher { _ in self.png(1) })
        try await pool.write { db in try AccountLifecycle.purgeAccount(db, id: self.me) }
        await store.flush()
        XCTAssertEqual(try rowCount(pool), 0)
        await store.shutDown()
    }

    func testLaunchSweepDeletesOrphans() throws {
        let pool = try openPool()
        try pool.write { db in
            let rows = try self.addMessage(db, account: self.me, gmailId: "m1", cids: ["logo"])
            let body = try XCTUnwrap(try MessageBody.fetchOne(db, key: "\(self.me):m1")?.bodyHTML)
            XCTAssertTrue(try InlineImageCache.store(db, .init(
                messageId: "\(self.me):m1", accountId: self.me,
                bodyDigest: InlineImageCache.bodyDigest(body),
                parts: [.init(attachmentId: rows[0].id!, contentId: "logo",
                              mimeType: "image/png", data: self.png(1))]), now: Date()))
        }
        // Rows left behind by a write with foreign keys off.
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "DELETE FROM account")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        XCTAssertEqual(try rowCount(pool), 1, "fixture: an orphaned row")
        try pool.writeWithoutTransaction { db in
            try db.inTransaction {
                try AccountLifecycle.purgeOrphanRows(db)
                return .commit
            }
        }
        XCTAssertEqual(try rowCount(pool), 0)
    }

    // MARK: Budget and LRU

    func testEvictionRemovesLeastRecentlyUsedMessagesWithinTheBudget() async throws {
        let pool = try openPool()
        try await pool.write { db in
            for id in ["a", "b", "c"] {
                try self.addMessage(db, account: self.me, gmailId: id, thread: id, cids: ["x", "y"])
            }
        }
        var clock = Date(timeIntervalSinceReferenceDate: 1_000)
        func store(at time: Date, budget: Int) -> InlineImageStore {
            InlineImageStore(db: pool, budget: budget, flushDelayNanoseconds: 1_000_000,
                             now: { time })
        }
        // Each message: two parts of 68 bytes.
        let day: TimeInterval = 86_400
        for id in ["a", "b", "c"] {
            clock += 2 * day
            let s = store(at: clock, budget: 10_000)
            let (msg, rows) = try await pool.read { db in
                (try self.message(db, "\(self.me):\(id)"),
                 try AttachmentRow.filter(Column("messageId") == "\(self.me):\(id)").fetchAll(db))
            }
            _ = await resolve(s, message: msg, attachments: rows, fetcher: Fetcher { _ in self.png(1) })
            await s.flush()
            await s.shutDown()
        }
        let stored = try await pool.read { db in try InlineImageCache.totalBytes(db) }
        XCTAssertEqual(stored, 3 * 2 * 68)

        // "a" is shown again two days later: "b" is now the least recently
        // used, and the write that marks "a" also enforces the budget.
        clock += 2 * day
        let touch = store(at: clock, budget: 2 * 2 * 68)
        await touch.noteUsed(["\(me):a"])
        await touch.flush()
        await touch.shutDown()
        try await pool.read { db in
            XCTAssertEqual(try InlineImageCache.totalBytes(db), 2 * 2 * 68, "within the budget")
            XCTAssertEqual(try String.fetchAll(db, sql: """
                SELECT DISTINCT messageId FROM inlineImage ORDER BY messageId
                """), ["\(self.me):a", "\(self.me):c"], "the least recently used whole message goes")
        }
    }

    func testDefaultBudgetAndCap() {
        XCTAssertEqual(InlineImageCache.totalBudgetBytes, 200 * 1_024 * 1_024)
        // Base64 of the per-message cap fits the in-memory 4 MiB body cap.
        XCTAssertLessThanOrEqual(InlineImageCache.perMessageBytes * 4 / 3,
                                 CIDInlineCachePolicy.maximumBytes)
    }

    // MARK: Quit

    /// Quit while writes are queued and while one runs: nothing partial,
    /// nothing corrupt, nothing written after the shutdown, and the pool
    /// closes.
    func testQuitDuringAWriteLeavesNoPartialMessageAndAHealthyDatabase() async throws {
        let pool = try openPool()
        let count = 40
        try await pool.write { db in
            for i in 0..<count {
                try self.addMessage(db, account: self.me, gmailId: "m\(i)", thread: "t\(i)",
                                    cids: ["a", "b", "c"])
            }
        }
        let store = InlineImageStore(db: pool, flushDelayNanoseconds: 60_000_000_000)
        for i in 0..<count {
            let (msg, rows) = try await pool.read { db in
                (try self.message(db, "\(self.me):m\(i)"),
                 try AttachmentRow.filter(Column("messageId") == "\(self.me):m\(i)").fetchAll(db))
            }
            _ = await resolve(store, message: msg, attachments: rows,
                              fetcher: Fetcher { _ in Data(repeating: 0xAB, count: 64 * 1_024) })
        }
        let writing = Task { await store.flush() }
        // Quit once the batch is running.
        for _ in 0..<2_000 {
            if await store.batchesStarted > 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        await store.shutDown()
        let started = await store.batchesStarted
        let finished = await store.batchesFinished
        let stillWriting = await store.isWriting
        XCTAssertEqual(started, 1)
        XCTAssertEqual(finished, started, "shutDown returned only after the running write ended")
        XCTAssertFalse(stillWriting)
        await writing.value

        // Queued after the shutdown: refused.
        let (late, lateRows) = try await pool.read { db in
            (try self.message(db, "\(self.me):m0"),
             try AttachmentRow.filter(Column("messageId") == "\(self.me):m0").fetchAll(db))
        }
        await store.remember(InlineImageCache.Pending(
            messageId: late.id, accountId: me,
            bodyDigest: InlineImageCache.bodyDigest(late.bodyHTML!),
            parts: lateRows.map {
                InlineImageCache.Part(attachmentId: $0.id!, contentId: $0.contentId!,
                                      mimeType: "image/png", data: self.png(5))
            }))
        let queued = await store.queuedMessageCount
        XCTAssertEqual(queued, 0)

        try await pool.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA integrity_check"), "ok")
            let perMessage = try Int.fetchAll(db, sql: """
                SELECT count(*) FROM inlineImage GROUP BY messageId
                """)
            XCTAssertTrue(perMessage.allSatisfy { $0 == 3 }, "all of a message or none: \(perMessage)")
            XCTAssertLessThanOrEqual(perMessage.count, count)
        }
        try close(pool)
    }

    func testShutdownBeforeTheTimerFiresWritesNothing() async throws {
        let pool = try openPool()
        let rows = try await pool.write { db in
            try self.addMessage(db, account: self.me, gmailId: "m1", cids: ["logo"])
        }
        let message = try await pool.read { db in try self.message(db, "\(self.me):m1") }
        let store = InlineImageStore(db: pool, flushDelayNanoseconds: 60_000_000_000)
        _ = await resolve(store, message: message, attachments: rows, fetcher: Fetcher { _ in self.png(1) })
        await store.shutDown()
        XCTAssertEqual(try rowCount(pool), 0)
        try close(pool)
    }

    // MARK: Migration

    func testV54AddsTheCacheTableToAV53Database() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q, upTo: "v53")
        try q.write { db in
            XCTAssertFalse(try db.tableExists("inlineImage"))
            try db.execute(sql: "INSERT INTO account (id, displayName, senderName) VALUES ('a@x.com', 'A', '')")
        }
        try AppDatabase.migrator.migrate(q)
        try q.read { db in
            XCTAssertTrue(try db.tableExists("inlineImage"))
            XCTAssertEqual(Set(try db.columns(in: "inlineImage").map(\.name)),
                           ["attachmentId", "messageId", "accountId", "bodyDigest", "contentId",
                            "mimeType", "byteCount", "data", "lastUsedAt"])
            let keys = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(inlineImage)")
            let cascades = Set(keys.filter { ($0["on_delete"] as String) == "CASCADE" }
                .map { $0["table"] as String })
            XCTAssertEqual(cascades, ["attachment", "message", "account"])
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT id FROM account"), ["a@x.com"])
            let indexes = try db.indexes(on: "inlineImage").map(\.columns)
            XCTAssertTrue(indexes.contains(["messageId", "lastUsedAt", "byteCount"]), "\(indexes)")
            XCTAssertFalse(indexes.contains(["messageId"]), "covered by the composite index")
            XCTAssertFalse(indexes.contains(["lastUsedAt"]), "covered by the composite index")
        }
    }

    // MARK: Cost

    /// Not a gate: prints what a warm open pays for reading and rebuilding a
    /// message with three 300 KB images from the cache, for the PR report.
    func testReportsTheCostOfAWarmOpenFromTheCache() async throws {
        let pool = try openPool()
        _ = try await pool.write { db in
            try self.addMessage(db, account: self.me, gmailId: "m1", cids: ["a", "b", "c"])
        }
        let (msg, rows) = try await pool.read { db in
            (try self.message(db, "\(self.me):m1"),
             try AttachmentRow.filter(Column("messageId") == "\(self.me):m1").fetchAll(db))
        }
        let store = InlineImageStore(db: pool, flushDelayNanoseconds: 1_000_000)
        _ = await resolve(store, message: msg, attachments: rows,
                          fetcher: Fetcher { _ in Data(repeating: 0x5A, count: 300 * 1_024) })
        await store.flush()
        var text: [Double] = []
        var images: [Double] = []
        for _ in 0..<5 {
            let repository = ThreadDetailRepository(db: pool, inlineImages: store)
            let revision = ThreadContentRevisions().revision(of: "\(me):t1")
            let start = Date()
            _ = await repository.payload(threadId: "\(me):t1", suppressingDrafts: [],
                                         revision: revision)
            let mid = Date()
            let warmed = await repository.warmCachedCIDBodies(
                threadId: "\(me):t1", revision: revision, fontScale: 1.0)
            images.append(Date().timeIntervalSince(mid) * 1_000)
            text.append(mid.timeIntervalSince(start) * 1_000)
            XCTAssertNotNil(warmed["\(me):m1"])
        }
        await store.shutDown()
        text.sort()
        images.sort()
        func fmt(_ v: [Double]) -> String { v.map { String(format: "%.1f", $0) }.joined(separator: " ") }
        print("INLINE_IMAGE_CACHE text payload median \(String(format: "%.1f", text[2])) ms [\(fmt(text))]; cached images (3 x 300 KB) median \(String(format: "%.1f", images[2])) ms [\(fmt(images))]")
    }
}
