import XCTest
import GRDB

/// The persistent, encrypted remote-image cache (`RemoteImageCache`,
/// `RemoteImageStore`, `RemoteImageResolver`): the first allowed open
/// fetches each image once; later opens, after a relaunch too, make no
/// request; a blocked message makes none and shows nothing cached; the
/// prefetch and pre-render never touch the network; what is deleted takes
/// its images with it.
final class RemoteImageCacheTests: XCTestCase {
    private var dir: URL!
    private var path: String { dir.appendingPathComponent("mail.sqlite").path }
    private let me = "me@example.com"
    private let other = "other@example.com"
    private let a = "https://img.example.com/a.png"
    private let b = "https://img.example.com/b.png"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mishmail-remoteimage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Fixtures

    private func openPool() throws -> DatabasePool {
        let pool = try DatabasePool(path: path)
        try AppDatabase.migrator.migrate(pool)
        return pool
    }

    private func close(_ pool: DatabasePool) throws { try pool.close() }

    private func html(_ urls: [String]) -> String {
        "<p>News</p>" + urls.map { "<img src=\"\($0)\">" }.joined()
    }

    private func addAccount(_ db: Database, _ id: String) throws {
        if try !Account.exists(db, key: id) {
            try Account(id: id, displayName: id, historyId: nil,
                        lastSyncAt: nil, senderName: "").insert(db)
        }
    }

    @discardableResult
    private func addMessage(_ db: Database, account: String, gmailId: String,
                            thread: String = "t1", body: String,
                            labels: String = "INBOX", date: Date = Date()) throws -> Message {
        try addAccount(db, account)
        let id = "\(account):\(gmailId)"
        let message = Message(
            id: id, accountId: account, gmailId: gmailId, threadId: "\(account):\(thread)",
            fromHeader: "News <news@example.com>", toHeader: account, ccHeader: "",
            subject: "Subject", date: date, snippet: "", bodyText: "News",
            bodyHTML: body, messageIdHeader: "<\(gmailId)@example.com>",
            referencesHeader: "", labelIds: labels, isUnread: false, hasAttachment: false)
        _ = try SyncEngine.upsertPending(
            db, items: [.init(message: message, attachments: [], headersOnly: false)])
        try SyncEngine.deriveThreads(db, for: [message.threadId], accountId: account)
        return message
    }

    private func png(_ seed: UInt8) -> Data {
        // A real image so the sniff passes; the seed makes bytes differ.
        var data = RemoteImageFetchTests.image(width: 2 + Int(seed % 8), height: 2)
        data.append(contentsOf: [seed])
        return data
    }

    /// The sender's server: counts requests per URL.
    final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        private let body: @Sendable (String) -> Data?
        init(body: @escaping @Sendable (String) -> Data?) { self.body = body }
        var requests: [String] { lock.withLock { log } }
        var transport: RemoteImageTransport {
            RemoteImageTransport(fetch: { [self] request, _ in
                let url = request.url!.absoluteString
                lock.withLock { log.append(url) }
                guard let data = body(url) else {
                    return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404,
                                                    httpVersion: nil, headerFields: [:])!)
                }
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                              headerFields: ["Content-Type": "image/png"])!)
            }, resolve: { _ in [[93, 184, 216, 34]] })
        }
    }

    private func server() -> Server {
        let seeds: [String: UInt8] = [a: 1, b: 2]
        return Server { [self] url in png(seeds[url] ?? 9) }
    }

    /// The pane's open: the card's decision, then the resolve.
    private func open(_ message: Message, store: RemoteImageStore?, server: Server,
                      allowed: Bool = true, base: String? = nil) async -> RemoteInlinedBody? {
        let html = base ?? message.bodyHTML ?? ""
        return await MailStore.resolveRemoteImages(
            messageId: message.id, accountId: message.accountId, baseHTML: html,
            preInlineBytes: html.utf8.count, baseIsCIDInlined: false, allowed: allowed,
            fontScale: 1.0, store: store, transport: server.transport, onPartial: { _ in })
    }

    private func rowCount(_ pool: DatabasePool, messageId: String? = nil) throws -> Int {
        try pool.read { db in
            if let messageId {
                return try Int.fetchOne(db, sql: "SELECT count(*) FROM remoteImage WHERE messageId = ?",
                                        arguments: [messageId]) ?? 0
            }
            return try Int.fetchOne(db, sql: "SELECT count(*) FROM remoteImage") ?? 0
        }
    }

    private func dataURI(_ seed: UInt8) -> String {
        CIDImageInliner.dataURI(mimeType: "image/png", data: png(seed))
    }

    // MARK: Open, reopen, relaunch

    func testFirstOpenFetchesOnceThenReopenAndRelaunchMakeNoRequest() async throws {
        let pool = try openPool()
        let message = try await pool.write { db in
            try self.addMessage(db, account: self.me, gmailId: "m1", body: self.html([self.a, self.b, self.a]))
        }
        let sender = server()
        let store = RemoteImageStore(db: pool, flushDelayNanoseconds: 1_000_000)
        let firstResult = await open(message, store: store, server: sender)
        let first = try XCTUnwrap(firstResult)
        XCTAssertEqual(sender.requests.sorted(), [a, b], "each image once")
        XCTAssertEqual(first.phase, .final)
        XCTAssertFalse(first.needsNetwork)
        XCTAssertFalse(first.loadAllowsRemoteImages, "nothing left to fetch: blocked CSP")
        XCTAssertTrue(first.html.contains(dataURI(1)))
        XCTAssertTrue(first.html.contains(dataURI(2)))
        XCTAssertFalse(first.html.contains("https://img."))
        XCTAssertNotNil(first.prep.documents?.fullBlocked)

        // Reopen before the write landed: the queued images answer.
        let secondResult = await open(message, store: store, server: sender)
        let second = try XCTUnwrap(secondResult)
        XCTAssertEqual(sender.requests.count, 2, "no request on reopen")
        XCTAssertEqual(second.html, first.html)
        await store.flush()
        XCTAssertEqual(try rowCount(pool), 2)
        await store.shutDown()
        try close(pool)

        // Relaunch: a new pool and store on the same database.
        let relaunched = try openPool()
        let fresh = RemoteImageStore(db: relaunched)
        let thirdResult = await open(message, store: fresh, server: sender)
        let third = try XCTUnwrap(thirdResult)
        XCTAssertEqual(sender.requests.count, 2, "no request after relaunch")
        XCTAssertEqual(third.html, first.html)
        XCTAssertEqual(third.phase, .final)
        await fresh.shutDown()
        try close(relaunched)
    }

    func testBlockedMessagesMakeNoRequestAndShowNothingCachedUntilAClick() async throws {
        let pool = try openPool()
        let (inbox, spam) = try await pool.write { db in
            (try self.addMessage(db, account: self.me, gmailId: "m1", body: self.html([self.a])),
             try self.addMessage(db, account: self.me, gmailId: "m2", thread: "t2",
                                 body: self.html([self.a]), labels: "SPAM"))
        }
        let sender = server()
        let store = RemoteImageStore(db: pool, flushDelayNanoseconds: 1_000_000)
        // Cache the inbox message's image under Always.
        _ = await open(inbox, store: store, server: sender)
        await store.flush()
        XCTAssertEqual(sender.requests.count, 1)

        // Ask each time, no click: no request, no cached body, and the card
        // paints the stored body with remote images blocked.
        let ask = RemoteImagePolicy.autoLoads(message: inbox, threadInSpam: false, policy: .ask,
                                              vipEmails: [])
        XCTAssertFalse(ask)
        let askBody = await open(inbox, store: store, server: sender, allowed: ask)
        XCTAssertNil(askBody)
        let cachedResult = await RemoteImageResolver.cachedBody(
            messageId: inbox.id, accountId: me, baseHTML: inbox.bodyHTML!, preInlineBytes: 0,
            baseIsCIDInlined: false, fontScale: 1, store: store)
        let cached = try XCTUnwrap(cachedResult)
        XCTAssertEqual(RemoteImageRendering.choice(allowRemoteImages: ask, remoteBody: cached,
                                                   cidInlined: false, remoteCandidateCount: 1),
                       .base(allowRemoteImages: false), "the cache never overrides the decision")

        // Spam under Always: the same.
        let spamAllowed = RemoteImagePolicy.autoLoads(message: spam, threadInSpam: false,
                                                      policy: .always, vipEmails: [])
        XCTAssertFalse(spamAllowed)
        let spamBody = await open(spam, store: store, server: sender, allowed: spamAllowed)
        XCTAssertNil(spamBody)
        XCTAssertEqual(sender.requests.count, 1, "nothing requested for blocked messages")

        // A click allows: the inbox message shows from the cache (no
        // request); the Spam message fetches its own copy.
        let click = RemoteImagePolicy.autoLoads(message: inbox, threadInSpam: false, policy: .ask,
                                                vipEmails: [], messageOptIn: true)
        let clickedResult = await open(inbox, store: store, server: sender, allowed: click)
        let clicked = try XCTUnwrap(clickedResult)
        XCTAssertTrue(clicked.html.contains(dataURI(1)))
        XCTAssertEqual(sender.requests.count, 1)
        let spamClick = RemoteImagePolicy.autoLoads(message: spam, threadInSpam: true, policy: .always,
                                                    vipEmails: [], messageOptIn: true,
                                                    threadOptIn: true)
        XCTAssertTrue(spamClick)
        _ = await open(spam, store: store, server: sender, allowed: spamClick)
        XCTAssertEqual(sender.requests.count, 2, "per message: no sharing across messages")
        // The conversation opt-in does not reach Spam.
        XCTAssertFalse(RemoteImagePolicy.autoLoads(message: spam, threadInSpam: true, policy: .always,
                                                   vipEmails: [], threadOptIn: true))
        await store.shutDown()
        try close(pool)
    }

    func testFailedImagesStayLiveAndAreNotRetriedInTheSameRun() async throws {
        let pool = try openPool()
        let message = try await pool.write { db in
            try self.addMessage(db, account: self.me, gmailId: "m1", body: self.html([self.a, self.b]))
        }
        let sender = Server { [self] url in url == a ? png(1) : nil }
        let store = RemoteImageStore(db: pool, flushDelayNanoseconds: 1_000_000)
        let firstResult = await open(message, store: store, server: sender)
        let first = try XCTUnwrap(firstResult)
        XCTAssertTrue(first.html.contains(dataURI(1)))
        XCTAssertTrue(first.html.contains(b), "the failed image stays an https URL")
        XCTAssertTrue(first.needsNetwork)
        XCTAssertTrue(first.loadAllowsRemoteImages, "so it loads live, as before")
        let againResult = await open(message, store: store, server: sender)
        let again = try XCTUnwrap(againResult)
        XCTAssertEqual(sender.requests.sorted(), [a, b], "the failure is not asked again this run")
        XCTAssertEqual(again.html, first.html)
        await store.shutDown()
        try close(pool)
    }

    func testOnPartialGetsTheCachedImagesBeforeTheFetch() async throws {
        let pool = try openPool()
        let one = try await pool.write { db in
            try self.addMessage(db, account: self.me, gmailId: "m1", body: self.html([self.a]))
        }
        let sender = server()
        let store = RemoteImageStore(db: pool, flushDelayNanoseconds: 1_000_000)
        _ = await open(one, store: store, server: sender)
        // The sender adds an image: the body now has one cached, one new.
        let both = html([a, b])
        let partials = PartialLog()
        let final = await MailStore.resolveRemoteImages(
            messageId: one.id, accountId: me, baseHTML: both, preInlineBytes: both.utf8.count,
            baseIsCIDInlined: false, allowed: true, fontScale: 1, store: store,
            transport: sender.transport, onPartial: { partials.add($0) })
        let partial = try XCTUnwrap(partials.bodies.first)
        XCTAssertEqual(partial.phase, .partial)
        XCTAssertFalse(partial.loadAllowsRemoteImages, "a partial body is shown blocked")
        XCTAssertTrue(partial.html.contains(dataURI(1)))
        XCTAssertTrue(partial.html.contains(b))
        XCTAssertEqual(partial.contentSuffix, ":rimg-p1")
        XCTAssertEqual(final?.phase, .final)
        XCTAssertEqual(final?.contentSuffix, ":rimg")
        XCTAssertEqual(sender.requests, [a, b])
        await store.shutDown()
        try close(pool)
    }

    // MARK: Prefetch and pre-render

    /// The warm path reads the cache only: under every policy no request,
    /// cached images inlined, uncached ones still remote (blocked CSP).
    func testPrefetchAndPrerenderNeverRequestAndInlineOnlyCachedImages() async throws {
        let pool = try openPool()
        let message = try await pool.write { db in
            try self.addMessage(db, account: self.me, gmailId: "m1", body: self.html([self.a]))
        }
        let sender = server()
        let store = RemoteImageStore(db: pool, flushDelayNanoseconds: 1_000_000)
        _ = await open(message, store: store, server: sender)
        await store.flush()
        // The body later shows a second, never-fetched image.
        let updated = html([a, b])
        try await pool.write { db in
            try db.execute(sql: "UPDATE message_body SET bodyHTML = ? WHERE messageId = ?",
                           arguments: [updated, message.id])
        }
        let before = sender.requests.count

        let repository = ThreadDetailRepository(db: pool, remoteImages: store)
        let revision = ThreadContentRevisions().revision(of: "\(me):t1")
        let cold = await repository.payload(threadId: "\(me):t1", suppressingDrafts: [],
                                            revision: revision)
        XCTAssertTrue(cold.payload.remoteInlineByMessageId.isEmpty, "payload() stays text only")
        XCTAssertEqual(cold.payload.bodyPrepByMessageId[message.id]?.remoteImageCount, 2)

        // Not allowed (Ask, Spam): nothing is built.
        let none = await repository.warmCachedRemoteBodies(
            threadId: "\(me):t1", revision: revision, fontScale: 1, allowedMessageIds: [])
        XCTAssertTrue(none.isEmpty)

        let warmed = await repository.warmCachedRemoteBodies(
            threadId: "\(me):t1", revision: revision, fontScale: 1, allowedMessageIds: [message.id])
        let body = try XCTUnwrap(warmed[message.id])
        XCTAssertEqual(body.phase, .partial)
        XCTAssertTrue(body.html.contains(dataURI(1)), "cached image inlined")
        XCTAssertTrue(body.html.contains(b), "uncached image left as is")
        XCTAssertEqual(sender.requests.count, before, "no request from the prefetch")

        // What the pre-render paints: the cached body, blocked, for a
        // neighbour whose open loads images; the plain blocked body
        // otherwise; nothing that needs the network.
        XCTAssertEqual(RemoteImageRendering.prerender(opensWithRemoteImages: true, remoteBody: body,
                                                      cidInlined: false, remoteCandidateCount: 2),
                       .remote(body))
        XCTAssertEqual(RemoteImageRendering.prerender(opensWithRemoteImages: false, remoteBody: body,
                                                      cidInlined: false, remoteCandidateCount: 2),
                       .base(allowRemoteImages: false))
        XCTAssertEqual(RemoteImageRendering.prerender(opensWithRemoteImages: true, remoteBody: nil,
                                                      cidInlined: false, remoteCandidateCount: 2),
                       .baseBlockedWhileResolving)
        XCTAssertNil(RemoteImageRendering.prerender(opensWithRemoteImages: true, remoteBody: nil,
                                                    cidInlined: false, remoteCandidateCount: 0),
                     "an open that loads live images cannot claim a blocked paint")
        var live = body
        live.phase = .final
        live.needsNetwork = true
        XCTAssertNil(RemoteImageRendering.prerender(opensWithRemoteImages: true, remoteBody: live,
                                                    cidInlined: false, remoteCandidateCount: 2))
        // A body built on another base is not used.
        XCTAssertEqual(RemoteImageRendering.choice(allowRemoteImages: true, remoteBody: body,
                                                   cidInlined: true, remoteCandidateCount: 2),
                       .baseBlockedWhileResolving)

        // The open claims the same document, then completes the missing one.
        let card = RemoteImageRendering.choice(allowRemoteImages: true, remoteBody: body,
                                               cidInlined: false, remoteCandidateCount: 2)
        XCTAssertEqual(card, .remote(body))
        let candidate = HTMLBodyPrerenderSelection.candidate(
            messageId: message.id, bodyHTML: body.html, remoteSuffix: body.contentSuffix)
        XCTAssertEqual(candidate?.contentID, message.id + ":full:rimg-p1")
        var reopened = message
        reopened.bodyHTML = updated
        let finalResult = await open(reopened, store: store, server: sender)
        let final = try XCTUnwrap(finalResult)
        XCTAssertEqual(sender.requests.count, before + 1, "only the missing image")
        XCTAssertEqual(final.phase, .final)

        let writes = await store.writeTransactionCount
        await store.shutDown()
        XCTAssertGreaterThan(writes, 0)
        try close(pool)
    }

    func testPrefetchDoesNotMarkImagesUsed() async throws {
        let pool = try openPool()
        let message = try await pool.write { db in
            try self.addMessage(db, account: self.me, gmailId: "m1", body: self.html([self.a]))
        }
        let store = RemoteImageStore(db: pool, flushDelayNanoseconds: 1_000_000)
        _ = await open(message, store: store, server: server())
        await store.flush()
        let stamp = try await pool.read { db in
            try Double.fetchAll(db, sql: "SELECT lastUsedAt FROM remoteImage")
        }
        let repository = ThreadDetailRepository(db: pool, remoteImages: store)
        let revision = ThreadContentRevisions().revision(of: "\(me):t1")
        _ = await repository.payload(threadId: "\(me):t1", suppressingDrafts: [], revision: revision)
        let warmed = await repository.warmCachedRemoteBodies(
            threadId: "\(me):t1", revision: revision, fontScale: 1, allowedMessageIds: [message.id])
        XCTAssertEqual(warmed[message.id]?.phase, .final)
        await store.flush()
        let after = try await pool.read { db in
            try Double.fetchAll(db, sql: "SELECT lastUsedAt FROM remoteImage")
        }
        XCTAssertEqual(after, stamp)
        await store.shutDown()
        try close(pool)
    }

    // MARK: Storage

    func testSameURLInTwoMessagesAndTwoAccountsIsStoredApart() async throws {
        let pool = try openPool()
        let (m1, m2, m3) = try await pool.write { db in
            (try self.addMessage(db, account: self.me, gmailId: "m1", body: self.html([self.a])),
             try self.addMessage(db, account: self.me, gmailId: "m2", thread: "t2", body: self.html([self.a])),
             try self.addMessage(db, account: self.other, gmailId: "m1", body: self.html([self.a])))
        }
        let sender = server()
        let store = RemoteImageStore(db: pool, flushDelayNanoseconds: 1_000_000)
        _ = await open(m1, store: store, server: sender)
        await store.flush()
        XCTAssertEqual(sender.requests.count, 1)
        // Another message (same account) and another account: their own fetch.
        _ = await open(m2, store: store, server: sender)
        _ = await open(m3, store: store, server: sender)
        XCTAssertEqual(sender.requests.count, 3)
        await store.flush()
        XCTAssertEqual(try rowCount(pool), 3)
        // A lookup under the wrong account finds nothing.
        let wrong = await store.cachedImages(messageId: m1.id, accountId: other,
                                             urlKeys: [RemoteImageHTML.urlKey(a)])
        XCTAssertTrue(wrong.isEmpty)
        // No URL is stored, only its digest.
        let stored = try await pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT messageId || accountId || urlKey || mimeType FROM remoteImage
                """)
        }
        for text in stored { XCTAssertFalse(text.contains("img.example.com")) }
        await store.shutDown()
        try close(pool)
    }

    func testDeletingTheMessageOrAccountDeletesItsImages() async throws {
        let pool = try openPool()
        let (m1, m2, m3) = try await pool.write { db in
            (try self.addMessage(db, account: self.me, gmailId: "m1", body: self.html([self.a])),
             try self.addMessage(db, account: self.me, gmailId: "m2", thread: "t2", body: self.html([self.b])),
             try self.addMessage(db, account: self.other, gmailId: "m1", body: self.html([self.a])))
        }
        let store = RemoteImageStore(db: pool, flushDelayNanoseconds: 1_000_000)
        for message in [m1, m2, m3] { _ = await open(message, store: store, server: server()) }
        await store.flush()
        XCTAssertEqual(try rowCount(pool), 3)
        try await pool.write { db in _ = try Message.deleteOne(db, key: m1.id) }
        XCTAssertEqual(try rowCount(pool, messageId: m1.id), 0)
        XCTAssertEqual(try rowCount(pool), 2)
        try await pool.write { db in try AccountLifecycle.purgeAccount(db, id: self.other) }
        XCTAssertEqual(try rowCount(pool, messageId: m3.id), 0)
        XCTAssertEqual(try rowCount(pool, messageId: m2.id), 1, "the other account's stay")
        await store.shutDown()
        try close(pool)
    }

    func testAQueuedResultForADeletedMessageIsNotWritten() async throws {
        let pool = try openPool()
        let message = try await pool.write { db in
            try self.addMessage(db, account: self.me, gmailId: "m1", body: self.html([self.a]))
        }
        let store = RemoteImageStore(db: pool, flushDelayNanoseconds: 60_000_000_000)
        _ = await open(message, store: store, server: server())
        try await pool.write { db in _ = try Message.deleteOne(db, key: message.id) }
        await store.flush()
        XCTAssertEqual(try rowCount(pool), 0)
        await store.shutDown()
        try close(pool)
    }

    func testLaunchSweepDeletesOrphans() throws {
        let pool = try openPool()
        try pool.write { db in
            try self.addMessage(db, account: self.me, gmailId: "m1", body: self.html([self.a]))
            try RemoteImageCache.store(db, .init(messageId: "\(self.me):m1", accountId: self.me, images: [
                .init(urlKey: RemoteImageHTML.urlKey(self.a), mimeType: "image/png", data: self.png(1)),
            ]), now: Date())
        }
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "DELETE FROM message WHERE id = ?", arguments: ["\(self.me):m1"])
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        XCTAssertEqual(try rowCount(pool), 1, "fixture: the orphan is there")
        try pool.write { db in try AccountLifecycle.purgeOrphanRows(db) }
        XCTAssertEqual(try rowCount(pool), 0)
        try close(pool)
    }

    func testStoreRefusesNonRasterTypesAndKeepsTheMessageCap() throws {
        let pool = try openPool()
        try pool.write { db in
            try self.addMessage(db, account: self.me, gmailId: "m1", body: "<p>x</p>")
            let big = Data(repeating: 1, count: RemoteImageFetchPolicy.maxImageBytes)
            let written = try RemoteImageCache.store(db, .init(messageId: "\(self.me):m1", accountId: self.me, images: [
                .init(urlKey: "k-svg", mimeType: "image/svg+xml", data: Data("<svg/>".utf8)),
                .init(urlKey: "k1", mimeType: "image/png", data: big),
                .init(urlKey: "k2", mimeType: "image/png", data: big),
                .init(urlKey: "k3", mimeType: "image/png", data: big),
                .init(urlKey: "k-too-big", mimeType: "image/png",
                      data: Data(count: RemoteImageFetchPolicy.maxImageBytes + 1)),
            ]), now: Date())
            XCTAssertEqual(written, 2, "SVG, oversized and over-the-cap images are skipped")
            XCTAssertLessThanOrEqual(try RemoteImageCache.messageBytes(db, messageId: "\(self.me):m1"),
                                     RemoteImageFetchPolicy.maxMessageBytes)
            // Another account's message id is refused outright.
            XCTAssertEqual(try RemoteImageCache.store(db, .init(messageId: "\(self.me):m1", accountId: self.other, images: [
                .init(urlKey: "k9", mimeType: "image/png", data: self.png(1)),
            ]), now: Date()), 0)
        }
        try close(pool)
    }

    func testEvictionRemovesLeastRecentlyUsedMessagesWithinTheBudget() throws {
        let pool = try openPool()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        try pool.write { db in
            for i in 0..<4 {
                try self.addMessage(db, account: self.me, gmailId: "m\(i)", thread: "t\(i)", body: "<p>x</p>")
                try RemoteImageCache.store(db, .init(messageId: "\(self.me):m\(i)", accountId: self.me, images: [
                    .init(urlKey: "k\(i)", mimeType: "image/png", data: Data(repeating: UInt8(i), count: 1_000)),
                ]), now: base.addingTimeInterval(Double(i) * 10))
            }
            // m0 used most recently.
            try RemoteImageCache.touch(db, messageIds: ["\(self.me):m0"], now: base.addingTimeInterval(2 * 86_400))
            let evicted = try RemoteImageCache.evict(db, budget: 2_000)
            XCTAssertEqual(evicted, ["\(self.me):m1", "\(self.me):m2"])
            XCTAssertEqual(try RemoteImageCache.totalBytes(db), 2_000)
        }
        try close(pool)
    }

    func testBudgetsAndCaps() {
        XCTAssertEqual(RemoteImageCache.totalBudgetBytes, 200 * 1_024 * 1_024)
        XCTAssertEqual(InlineImageCache.totalBudgetBytes, 200 * 1_024 * 1_024, "separate budgets")
        XCTAssertEqual(RemoteImageFetchPolicy.maxImageBytes, 3 * 1_024 * 1_024)
        XCTAssertEqual(RemoteImageFetchPolicy.maxMessageBytes, 6 * 1_024 * 1_024)
        XCTAssertEqual(RemoteImageFetchPolicy.maxImagesPerMessage, 40)
        XCTAssertEqual(RemoteImageFetchPolicy.maxRedirects, 3)
    }

    func testOnlyTheFirstFortyImagesOfAMessageAreFetched() async throws {
        let pool = try openPool()
        let urls = (0..<45).map { "https://img.example.com/\($0).png" }
        let message = try await pool.write { db in
            try self.addMessage(db, account: self.me, gmailId: "m1", body: self.html(urls))
        }
        let sender = server()
        let bodyResult = await open(message, store: nil, server: sender)
        let body = try XCTUnwrap(bodyResult)
        XCTAssertEqual(sender.requests.count, RemoteImageFetchPolicy.maxImagesPerMessage)
        XCTAssertTrue(body.needsNetwork, "the rest load live")
        try close(pool)
    }

    // MARK: Quit

    func testQuitDuringAWriteLeavesNoPartialMessageAndAHealthyDatabase() async throws {
        let pool = try openPool()
        let count = 30
        let urls = (0..<3).map { "https://img.example.com/q\($0).png" }
        let messages = try await pool.write { db in
            try (0..<count).map { i in
                try self.addMessage(db, account: self.me, gmailId: "m\(i)",
                                    thread: "t\(i)", body: self.html(urls))
            }
        }
        let store = RemoteImageStore(db: pool, flushDelayNanoseconds: 60_000_000_000)
        let sender = Server { _ in RemoteImageFetchTests.image(width: 200, height: 200) }
        for message in messages { _ = await open(message, store: store, server: sender) }
        let writing = Task { await store.flush() }
        for _ in 0..<2_000 {
            if await store.batchesStarted > 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        await store.shutDown()
        let started = await store.batchesStarted
        let finished = await store.batchesFinished
        XCTAssertEqual(started, 1)
        XCTAssertEqual(finished, started, "shutDown returned only after the running write ended")
        await writing.value
        await store.remember(.init(messageId: messages[0].id, accountId: me, images: [
            .init(urlKey: "late", mimeType: "image/png", data: png(1)),
        ]))
        let queued = await store.queuedMessageCount
        XCTAssertEqual(queued, 0, "nothing queued after shutdown")
        try await pool.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA integrity_check"), "ok")
            let perMessage = try Int.fetchAll(db, sql: "SELECT count(*) FROM remoteImage GROUP BY messageId")
            XCTAssertTrue(perMessage.allSatisfy { $0 == 3 }, "all of a message or none: \(perMessage)")
        }
        try close(pool)
    }

    func testClearAllEmptiesTheCache() async throws {
        let pool = try openPool()
        let message = try await pool.write { db in
            try self.addMessage(db, account: self.me, gmailId: "m1", body: self.html([self.a]))
        }
        let store = RemoteImageStore(db: pool, flushDelayNanoseconds: 1_000_000)
        _ = await open(message, store: store, server: server())
        await store.flush()
        await store.clearAll()
        XCTAssertEqual(try rowCount(pool), 0)
        await store.shutDown()
        try close(pool)
    }

    // MARK: Migration

    func testV55AddsTheCacheTableToAV54Database() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q, upTo: "v54")
        try q.write { db in
            XCTAssertFalse(try db.tableExists("remoteImage"))
            XCTAssertTrue(try db.tableExists("inlineImage"))
            try db.execute(sql: "INSERT INTO account (id, displayName, senderName) VALUES ('a@x.com', 'A', '')")
        }
        try AppDatabase.migrator.migrate(q)
        try q.read { db in
            XCTAssertTrue(try db.tableExists("remoteImage"))
            XCTAssertEqual(Set(try db.columns(in: "remoteImage").map(\.name)),
                           ["messageId", "accountId", "urlKey", "mimeType", "byteCount",
                            "lastUsedAt", "data"])
            let keys = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(remoteImage)")
            let cascades = Set(keys.filter { ($0["on_delete"] as String) == "CASCADE" }
                .map { $0["table"] as String })
            XCTAssertEqual(cascades, ["message", "account"])
            XCTAssertEqual(try db.primaryKey("remoteImage").columns, ["messageId", "accountId", "urlKey"])
            let indexes = try db.indexes(on: "remoteImage").map(\.columns)
            XCTAssertTrue(indexes.contains(["messageId", "lastUsedAt", "byteCount"]), "\(indexes)")
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT id FROM account"), ["a@x.com"])
        }
    }
}

final class PartialLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [RemoteInlinedBody] = []
    var bodies: [RemoteInlinedBody] { lock.withLock { log } }
    func add(_ body: RemoteInlinedBody) { lock.withLock { log.append(body) } }
}
