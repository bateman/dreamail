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
            .appendingPathComponent("dreamail-remoteimage-\(UUID().uuidString)", isDirectory: true)
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

    /// The pane's open, driven through its state (`RemoteImagePaneState`) as
    /// the view drives it: the placeholder asks (not mounted) → cache check
    /// → result recorded → the mounted body asks → mark used, or fetch for
    /// the next open. Returns the body shown now (`.cache`) or kept for the
    /// next open (`.fetched`).
    private enum Opened { case cache(RemoteInlinedBody), fetched(RemoteInlinedBody?), blocked }

    private func openThroughPane(_ message: Message, store: RemoteImageStore?, server: Server,
                                 allowed: Bool = true) async -> Opened {
        var pane = RemoteImagePaneState()
        let html = message.bodyHTML ?? ""
        let count = RemoteImageHTML.candidates(in: html).count
        func step(mounted: Bool, body: RemoteInlinedBody?) -> RemoteImagePaneState.Step {
            pane.step(id: message.id, allowRemoteImages: allowed, bodyMounted: mounted,
                      candidateCount: count, cidResolveInFlight: false, cidInlined: false,
                      remoteBody: body)
        }
        guard case .checkCache(let baseIsCID) = step(mounted: false, body: nil) else {
            return .blocked
        }
        let cached = await RemoteImageResolver.cachedBody(
            messageId: message.id, accountId: message.accountId, baseHTML: html,
            preInlineBytes: html.utf8.count, baseIsCIDInlined: baseIsCID, fontScale: 1.0,
            store: store)
        XCTAssertTrue(pane.checkFinished(message.id, complete: cached != nil))
        if let cached {
            XCTAssertEqual(step(mounted: true, body: cached), .markCachedUsed)
            return .cache(cached)
        }
        guard case .fetchForNextOpen(let base) = step(mounted: true, body: nil) else {
            return .blocked
        }
        return .fetched(await RemoteImageResolver.fetchForNextOpen(
            messageId: message.id, accountId: message.accountId, baseHTML: html,
            preInlineBytes: html.utf8.count, baseIsCIDInlined: base,
            fontScale: 1.0, store: store, transport: server.transport))
    }

    /// The body an open produced (shown now or kept for the next open).
    private func open(_ message: Message, store: RemoteImageStore?, server: Server,
                      allowed: Bool = true) async -> RemoteInlinedBody? {
        switch await openThroughPane(message, store: store, server: server, allowed: allowed) {
        case .cache(let body): return body
        case .fetched(let body): return body
        case .blocked: return nil
        }
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
        XCTAssertEqual(RemoteImageRendering.choice(allowRemoteImages: ask, remoteBody: cached),
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

    /// S1: a refusal (here a 404) is stored as a marker, so the message is
    /// complete: reopened, after a relaunch too, from the cache with no
    /// request; the refused image loads live from WebKit (allowed CSP).
    func testRefusedImagesAreRememberedAcrossRelaunchesAndTheMessageCompletes() async throws {
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
        XCTAssertEqual(sender.requests.sorted(), [a, b], "the refusal is not asked again")
        XCTAssertEqual(again.html, first.html)
        await store.flush()
        await store.shutDown()
        try close(pool)

        let relaunched = try openPool()
        let fresh = RemoteImageStore(db: relaunched)
        let opened = await openThroughPane(message, store: fresh, server: sender)
        guard case .cache(let body) = opened else { return XCTFail("complete: from the cache") }
        XCTAssertEqual(sender.requests.count, 2, "no request from the app after a relaunch")
        XCTAssertTrue(body.loadAllowsRemoteImages, "the refused image loads live")
        let refused = await fresh.refusedKeys(messageId: message.id, accountId: me)
        XCTAssertEqual(refused, [RemoteImageHTML.urlKey(b)])
        // No URL in the marker row, and it goes with the message.
        try await relaunched.write { db in _ = try Message.deleteOne(db, key: message.id) }
        let left = try await relaunched.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM remoteImage") ?? 0
        }
        XCTAssertEqual(left, 0)
        await fresh.shutDown()
        try close(relaunched)
    }

    /// S1: URLs never started because the message's byte cap was reached
    /// are refused too, so the message completes.
    func testImagesPastTheByteCapAreRefusedSoTheMessageCompletes() async throws {
        let pool = try openPool()
        let urls = (0..<4).map { "https://img.example.com/big\($0).png" }
        let message = try await pool.write { db in
            try self.addMessage(db, account: self.me, gmailId: "m1", body: self.html(urls))
        }
        // Each just under the per-image cap: two fill the message's cap.
        let big = RemoteImageFetchTests.image(width: 8, height: 8)
            + Data(repeating: 7, count: RemoteImageFetchPolicy.maxImageBytes - 4_096)
        let sender = Server { _ in big }
        let store = RemoteImageStore(db: pool, flushDelayNanoseconds: 1_000_000)
        _ = await open(message, store: store, server: sender)
        await store.flush()
        let keys = await store.storedKeys(messageId: message.id, accountId: me)
        XCTAssertEqual(keys.count, urls.count, "every candidate settled: stored or refused")
        let before = sender.requests.count
        let opened = await openThroughPane(message, store: store, server: sender)
        guard case .cache = opened else { return XCTFail("complete after the cap") }
        XCTAssertEqual(sender.requests.count, before)
        await store.shutDown()
        try close(pool)
    }

    func testServerErrorsAreNotRefusals() async throws {
        let pool = try openPool()
        let message = try await pool.write { db in
            try self.addMessage(db, account: self.me, gmailId: "m1", body: self.html([self.a]))
        }
        let transport = RemoteImageTransport(fetch: { request, _ in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil,
                                     headerFields: [:])!)
        }, resolve: { _ in [[93, 184, 216, 34]] })
        let store = RemoteImageStore(db: pool, flushDelayNanoseconds: 1_000_000)
        _ = await RemoteImageResolver.fetchForNextOpen(
            messageId: message.id, accountId: me, baseHTML: message.bodyHTML!, preInlineBytes: 0,
            baseIsCIDInlined: false, fontScale: 1, store: store, transport: transport)
        await store.flush()
        let refused = await store.refusedKeys(messageId: message.id, accountId: me)
        XCTAssertTrue(refused.isEmpty, "503 is retried on the next open")
        await store.shutDown()
        try close(pool)
    }

    /// Option A: an open whose images are not all cached renders exactly as
    /// without the cache (allowed CSP, live images); the app fetches the
    /// rest in the background and the next open shows the cached body.
    func testAnIncompleteCacheOpensAsWithoutTheCacheAndTheNextOpenUsesIt() async throws {
        let pool = try openPool()
        let one = try await pool.write { db in
            try self.addMessage(db, account: self.me, gmailId: "m1", body: self.html([self.a]))
        }
        let sender = server()
        let store = RemoteImageStore(db: pool, flushDelayNanoseconds: 1_000_000)
        _ = await open(one, store: store, server: sender)
        // The body now shows one cached image and one never fetched.
        var both = one
        both.bodyHTML = html([a, b])
        let incomplete = await RemoteImageResolver.cachedBody(
            messageId: one.id, accountId: me, baseHTML: both.bodyHTML!, preInlineBytes: 0,
            baseIsCIDInlined: false, fontScale: 1, store: store)
        XCTAssertNil(incomplete, "no partly cached body is ever shown")
        XCTAssertEqual(RemoteImageRendering.choice(allowRemoteImages: true, remoteBody: incomplete),
                       .base(allowRemoteImages: true), "first open: as without the cache")
        let nextResult = await open(both, store: store, server: sender)
        let next = try XCTUnwrap(nextResult, "the next open's body")
        XCTAssertEqual(sender.requests, [a, b], "only the missing image")
        XCTAssertFalse(next.loadAllowsRemoteImages)
        XCTAssertEqual(next.contentSuffix, ":rimg")
        let cachedResult = await RemoteImageResolver.cachedBody(
            messageId: one.id, accountId: me, baseHTML: both.bodyHTML!,
            preInlineBytes: both.bodyHTML!.utf8.count, baseIsCIDInlined: false, fontScale: 1,
            store: store)
        XCTAssertEqual(cachedResult?.html, next.html, "next open: from the cache")
        await store.shutDown()
        try close(pool)
    }

    // MARK: Prefetch and pre-render

    /// The warm path reads the cache only: under every policy no request;
    /// a body is built only when every cacheable image is cached.
    func testPrefetchAndPrerenderNeverRequestAndUseOnlyCompleteCachedBodies() async throws {
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

        // Not allowed (Ask, Spam): nothing is built.
        let none = await repository.warmCachedRemoteBodies(
            threadId: "\(me):t1", revision: revision, fontScale: 1, allowedMessageIds: [])
        XCTAssertTrue(none.isEmpty)
        // Allowed but incomplete: nothing either; the pre-render skips it.
        let incomplete = await repository.warmCachedRemoteBodies(
            threadId: "\(me):t1", revision: revision, fontScale: 1, allowedMessageIds: [message.id])
        XCTAssertTrue(incomplete.isEmpty)
        XCTAssertNil(RemoteImageRendering.prerender(opensWithRemoteImages: true, remoteBody: nil),
                     "an open that loads live images cannot claim a blocked paint")
        XCTAssertEqual(RemoteImageRendering.prerender(opensWithRemoteImages: false, remoteBody: nil),
                       .base(allowRemoteImages: false))
        XCTAssertEqual(sender.requests.count, before, "no request from the prefetch")

        // An open fetches the missing one; the next warm builds the body.
        var reopened = message
        reopened.bodyHTML = updated
        _ = await open(reopened, store: store, server: sender)
        XCTAssertEqual(sender.requests.count, before + 1, "only the missing image")
        await store.flush()
        let warmed = await repository.warmCachedRemoteBodies(
            threadId: "\(me):t1", revision: revision, fontScale: 1, allowedMessageIds: [message.id])
        let body = try XCTUnwrap(warmed[message.id])
        XCTAssertTrue(body.html.contains(dataURI(1)))
        XCTAssertTrue(body.html.contains(dataURI(2)))
        XCTAssertFalse(body.needsNetwork)
        XCTAssertEqual(sender.requests.count, before + 1, "the warm made no request")

        // Pre-render and open: the same document under the blocked CSP.
        XCTAssertEqual(RemoteImageRendering.prerender(opensWithRemoteImages: true, remoteBody: body),
                       .remote(body))
        XCTAssertEqual(RemoteImageRendering.choice(allowRemoteImages: true, remoteBody: body),
                       .remote(body))
        let candidate = HTMLBodyPrerenderSelection.candidate(messageId: message.id, remoteBody: body)
        XCTAssertEqual(candidate?.contentID, message.id + ":full:rimg")
        var live = body
        live.needsNetwork = true
        XCTAssertNil(RemoteImageRendering.prerender(opensWithRemoteImages: true, remoteBody: live))
        await store.shutDown()
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
        XCTAssertNotNil(warmed[message.id])
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
            XCTAssertEqual(written, 1, "SVG, oversized and over-the-cap images are skipped")
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
        XCTAssertEqual(RemoteImageFetchPolicy.maxImageBytes, 2 * 1_024 * 1_024)
        XCTAssertEqual(RemoteImageFetchPolicy.maxMessageBytes, 5 * 512 * 1_024)
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

    // MARK: The pane's gate

    private func body(cid: Bool, needsNetwork: Bool = false) -> RemoteInlinedBody {
        RemoteInlinedBody(html: "x", prep: .empty, needsNetwork: needsNetwork, baseIsCIDInlined: cid)
    }

    private func step(_ pane: inout RemoteImagePaneState, _ allowed: Bool = true,
                      mounted: Bool = true, count: Int = 2, cidInFlight: Bool = false,
                      cid: Bool = false, body: RemoteInlinedBody? = nil) -> RemoteImagePaneState.Step {
        pane.step(id: "m", allowRemoteImages: allowed, bodyMounted: mounted, candidateCount: count,
                  cidResolveInFlight: cidInFlight, cidInlined: cid, remoteBody: body)
    }

    func testPaneStepFollowsTheCardsDecision() {
        var pane = RemoteImagePaneState()
        XCTAssertEqual(step(&pane, false), .cancel, "blocked: nothing read, nothing fetched")
        XCTAssertEqual(step(&pane, count: 0), .nothing)
        XCTAssertEqual(step(&pane, mounted: false), .checkCache(baseIsCIDInlined: false),
                       "the placeholder starts the check")
        XCTAssertEqual(step(&pane), .nothing, "one check at a time")
        XCTAssertTrue(pane.checkFinished("m", complete: false))
        XCTAssertEqual(step(&pane, mounted: false), .nothing, "never a fetch from the placeholder")
        XCTAssertEqual(step(&pane), .fetchForNextOpen(baseIsCIDInlined: false))
        XCTAssertEqual(step(&pane), .nothing, "one fetch per base")

        var warm = RemoteImagePaneState()
        XCTAssertEqual(step(&warm, body: body(cid: false)), .markCachedUsed)
        XCTAssertEqual(step(&warm, body: body(cid: false)), .nothing, "marked once")
        // The card's choice: the body on screen, or a bounded wait, or live.
        XCTAssertEqual(RemoteImageRendering.choice(allowRemoteImages: true, remoteBody: nil,
                                                   awaitingCacheCheck: true), .awaitingCacheCheck)
        XCTAssertEqual(RemoteImageRendering.choice(allowRemoteImages: false, remoteBody: body(cid: false),
                                                   awaitingCacheCheck: true),
                       .base(allowRemoteImages: false), "a blocked card never waits nor uses the cache")
        XCTAssertFalse(RemoteImagePaneState.awaitsCacheCheck(
            check: nil, allowRemoteImages: false, candidateCount: 2, hasRemoteBody: false))
        XCTAssertTrue(RemoteImagePaneState.awaitsCacheCheck(
            check: .running, allowRemoteImages: true, candidateCount: 2, hasRemoteBody: false))
        XCTAssertFalse(RemoteImagePaneState.awaitsCacheCheck(
            check: .incomplete, allowRemoteImages: true, candidateCount: 2, hasRemoteBody: false))
    }

    /// R1: a cached body built before the `cid:` resolve keeps its content id
    /// (no reload); the rebuild for the `cid:` base gets a new one.
    func testCIDLandingAfterACachedOpenRebuildsUnderANewContentID() {
        var pane = RemoteImagePaneState()
        XCTAssertEqual(step(&pane, mounted: false), .checkCache(baseIsCIDInlined: false))
        XCTAssertTrue(pane.checkFinished("m", complete: true))
        let raw = body(cid: false)
        XCTAssertEqual(step(&pane, body: raw), .markCachedUsed)
        let shown = RemoteImageRendering.contentID(messageId: "m", authored: false,
                                                   cidInlined: false, remoteBody: raw)
        XCTAssertEqual(shown, "m:full:rimg")
        // The cid: resolve lands: the raw body stays, under the same id.
        XCTAssertEqual(RemoteImageRendering.choice(allowRemoteImages: true, remoteBody: raw), .remote(raw))
        XCTAssertEqual(RemoteImageRendering.contentID(messageId: "m", authored: false,
                                                      cidInlined: true, remoteBody: raw), shown)
        XCTAssertEqual(step(&pane, cid: true, body: raw), .rebuildFromCache(baseIsCIDInlined: true))
        XCTAssertEqual(step(&pane, cid: true, body: raw), .nothing, "one rebuild")
        let rebuilt = body(cid: true)
        XCTAssertEqual(RemoteImageRendering.contentID(messageId: "m", authored: false,
                                                      cidInlined: true, remoteBody: rebuilt),
                       "m:full:cid:rimg", "the rebuilt body loads")
        XCTAssertEqual(step(&pane, cid: true, body: rebuilt), .nothing, "already marked used")
        XCTAssertEqual(RemoteImageRendering.contentID(messageId: "m", authored: true,
                                                      cidInlined: true, remoteBody: nil),
                       "m:authored:cid", "without the cache: as before")
    }

    /// R2: the check's end starts nothing; only a mounted body fetches.
    func testTheCheckNeverStartsAFetchByItself() {
        // Oversized body behind its approval placeholder, collapsed card,
        // closed pane: no mounted body ever asks.
        var pane = RemoteImagePaneState()
        XCTAssertEqual(step(&pane, mounted: false), .checkCache(baseIsCIDInlined: false))
        XCTAssertTrue(pane.checkFinished("m", complete: false))
        XCTAssertEqual(step(&pane, mounted: false), .nothing)
        // Policy to Ask or Spam during the check: cancelled; the late result
        // is not taken.
        var flipped = RemoteImagePaneState()
        XCTAssertEqual(step(&flipped, mounted: false), .checkCache(baseIsCIDInlined: false))
        XCTAssertEqual(step(&flipped, false), .cancel)
        XCTAssertFalse(flipped.checkFinished("m", complete: true), "a cancelled check shows nothing")
        XCTAssertNil(flipped.checks["m"])
        // Past the deadline: paint as without the cache; the result only
        // waits for the next open.
        var slow = RemoteImagePaneState()
        XCTAssertEqual(step(&slow, mounted: false), .checkCache(baseIsCIDInlined: false))
        slow.checkTimedOut("m")
        XCTAssertFalse(RemoteImagePaneState.awaitsCacheCheck(
            check: slow.checks["m"], allowRemoteImages: true, candidateCount: 2, hasRemoteBody: false))
        XCTAssertFalse(slow.checkFinished("m", complete: true))
    }

    /// R3: the check only holds the first paint; a `cid:` resolve landing
    /// later never unmounts the live body, and the fetch waits for it.
    func testCIDLandingAfterAnIncompleteCheckKeepsTheLiveBody() {
        var pane = RemoteImagePaneState()
        XCTAssertEqual(step(&pane, mounted: false), .checkCache(baseIsCIDInlined: false))
        XCTAssertTrue(pane.checkFinished("m", complete: false))
        XCTAssertEqual(step(&pane, cidInFlight: true), .nothing, "waits for the cid: base")
        // The cid: resolve lands: no new check, no wait, then the fetch.
        XCTAssertFalse(RemoteImagePaneState.awaitsCacheCheck(
            check: pane.checks["m"], allowRemoteImages: true, candidateCount: 2, hasRemoteBody: false),
                       "the body is never replaced by the placeholder")
        XCTAssertTrue(pane.cidFinished("m"))
        XCTAssertEqual(step(&pane, cid: true), .fetchForNextOpen(baseIsCIDInlined: true))
        XCTAssertFalse(pane.cidFinished("m"))
        // The body leaves: everything for the message is reset.
        XCTAssertEqual(step(&pane, false), .cancel)
        XCTAssertNil(pane.checks["m"])
    }

    /// After a relaunch, a conversation the prefetch never warmed is opened
    /// directly: a complete cache is shown with no request.
    func testDirectOpenAfterRelaunchWithACompleteCacheMakesNoRequest() async throws {
        let pool = try openPool()
        let message = try await pool.write { db in
            try self.addMessage(db, account: self.me, gmailId: "m1", body: self.html([self.a, self.b]))
        }
        let sender = server()
        let first = RemoteImageStore(db: pool, flushDelayNanoseconds: 1_000_000)
        let opened = await openThroughPane(message, store: first, server: sender)
        guard case .fetched(let kept) = opened
        else { return XCTFail("the first open shows images live and fetches for next time") }
        XCTAssertNotNil(kept)
        XCTAssertEqual(sender.requests.count, 2)
        await first.flush()
        await first.shutDown()
        try close(pool)

        let relaunched = try openPool()
        let store = RemoteImageStore(db: relaunched)
        // No repository, no warm: the pane's own check on a cold payload.
        let direct = await openThroughPane(message, store: store, server: sender)
        guard case .cache(let body) = direct else { return XCTFail("expected the cached body") }
        XCTAssertEqual(sender.requests.count, 2, "zero requests on the direct open")
        XCTAssertFalse(body.loadAllowsRemoteImages, "blocked CSP: nothing needs the network")
        XCTAssertEqual(RemoteImageRendering.choice(allowRemoteImages: true, remoteBody: body),
                       .remote(body))
        await store.shutDown()
        try close(relaunched)
    }

    func testAnIncompleteCacheIsDecidedOnKeysWithoutReadingImages() async throws {
        let log = SQLLog()
        var config = Configuration()
        config.prepareDatabase { db in db.trace { event in log.add("\(event)") } }
        let pool = try DatabasePool(path: path, configuration: config)
        try AppDatabase.migrator.migrate(pool)
        let message = try await pool.write { db in
            try self.addMessage(db, account: self.me, gmailId: "m1", body: self.html([self.a, self.b]))
        }
        let store = RemoteImageStore(db: pool)
        _ = try await pool.write { db in
            try RemoteImageCache.store(db, .init(messageId: message.id, accountId: self.me, images: [
                .init(urlKey: RemoteImageHTML.urlKey(self.a), mimeType: "image/png", data: self.png(1)),
            ]), now: Date())
        }
        let keys = await store.storedKeys(messageId: message.id, accountId: me)
        XCTAssertEqual(keys, [RemoteImageHTML.urlKey(a)])
        log.reset()
        let body = await RemoteImageResolver.cachedBody(
            messageId: message.id, accountId: me, baseHTML: message.bodyHTML!, preInlineBytes: 0,
            baseIsCIDInlined: false, fontScale: 1, store: store)
        XCTAssertNil(body)
        let reads = log.lines.filter { $0.contains("FROM remoteImage") }
        XCTAssertFalse(reads.isEmpty, "the keys were read")
        XCTAssertFalse(reads.contains { $0.contains("data") }, "no image bytes read: \(reads)")
        await store.shutDown()
        try close(pool)
    }

    func testAnURLInFlightIsNotFetchedTwice() async throws {
        let pool = try openPool()
        let store = RemoteImageStore(db: pool)
        let first = await store.claim(messageId: "m", urls: [a, b])
        XCTAssertEqual(first, [a, b])
        let second = await store.claim(messageId: "m", urls: [a, b])
        XCTAssertEqual(second, [], "both in flight")
        let other = await store.claim(messageId: "n", urls: [a])
        XCTAssertEqual(other, [a], "per message")
        await store.release(messageId: "m", urls: [a])
        let again = await store.claim(messageId: "m", urls: [a, b])
        XCTAssertEqual(again, [a])
        await store.shutDown()
        try close(pool)
    }

    func testTransientFailuresAreRetriedAndRefusalsAreNot() async throws {
        let pool = try openPool()
        let message = try await pool.write { db in
            try self.addMessage(db, account: self.me, gmailId: "m1", body: self.html([self.a, self.b]))
        }
        let offline = a
        let transport = RemoteImageTransport(fetch: { request, _ in
            if request.url!.absoluteString == offline { throw URLError(.notConnectedToInternet) }
            return (Data("not an image".utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "image/png"])!)
        }, resolve: { _ in [[93, 184, 216, 34]] })
        let store = RemoteImageStore(db: pool, flushDelayNanoseconds: 1_000_000)
        _ = await RemoteImageResolver.fetchForNextOpen(
            messageId: message.id, accountId: me, baseHTML: message.bodyHTML!, preInlineBytes: 0,
            baseIsCIDInlined: false, fontScale: 1, store: store, transport: transport)
        let failed = await store.refusedKeys(messageId: message.id, accountId: me)
        XCTAssertEqual(failed, [RemoteImageHTML.urlKey(b)], "offline is not a refusal; not-an-image is")
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

final class SQLLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var lines: [String] { lock.withLock { log } }
    func add(_ line: String) { lock.withLock { log.append(line) } }
    func reset() { lock.withLock { log = [] } }
}
