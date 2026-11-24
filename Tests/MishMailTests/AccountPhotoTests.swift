import XCTest
import GRDB
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// The account's own Google profile photo: where it may be fetched from,
/// what is accepted, when it is fetched, and where it is kept.
final class AccountPhotoTests: XCTestCase {

    // MARK: - Helpers

    private let photoURL = "https://lh3.googleusercontent.com/a/ACg8ocLsynthetic=s96-c"

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        return q
    }

    private func insertAccount(_ q: DatabaseQueue, _ id: String) throws {
        try q.write { db in
            try Account(id: id, displayName: id, historyId: nil,
                        lastSyncAt: nil, senderName: "").insert(db)
        }
    }

    static func image(width: Int, height: Int, type: UTType = .png) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(
            out as CFMutableData, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private func pixelSize(_ data: Data) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    // MARK: - URL allowlist

    func testGoogleHTTPSPhotoURLIsAccepted() {
        for host in ["lh3", "lh4", "lh5", "lh6"] {
            let raw = "https://\(host).googleusercontent.com/a/ACg8oc=s96-c"
            XCTAssertEqual(AccountPhotoPolicy.validatedURL(raw)?.host, "\(host).googleusercontent.com")
        }
        XCTAssertNotNil(AccountPhotoPolicy.validatedURL("HTTPS://LH3.GOOGLEUSERCONTENT.COM/a/x"))
    }

    func testOtherHostsSchemesAndShapesAreRefused() {
        let refused = [
            nil, "", "not a url",
            "http://lh3.googleusercontent.com/a/x",          // cleartext
            "https://evil.example.com/a/x",                  // other host
            "https://lh3.googleusercontent.com.evil.test/a", // look-alike suffix
            "https://evil.test/lh3.googleusercontent.com/a", // host in path
            "https://googleusercontent.com/a/x",             // parent domain
            "https://xlh3.googleusercontent.com/a/x",
            "https://lh3.googleusercontent.com:8443/a/x",    // other port
            "https://user:pw@lh3.googleusercontent.com/a/x", // user info
            "https://www.gravatar.com/avatar/abc",
            "file:///etc/passwd",
            "data:image/png;base64,AAAA",
        ]
        for raw in refused {
            XCTAssertNil(AccountPhotoPolicy.validatedURL(raw), raw ?? "nil")
        }
    }

    func testLegacyDefaultSilhouetteCountsAsNoPhoto() throws {
        let info = try GoogleUserInfo.decode(Data(GoogleUserInfoFixture.legacySilhouette.utf8))
        XCTAssertNotNil(info.picture)
        XCTAssertNil(AccountPhotoPolicy.validatedURL(info.picture))
    }

    // MARK: - Parsing (fixture of the real response shape)

    func testUserInfoFixtureParsesPhotoURL() throws {
        let info = try GoogleUserInfo.decode(Data(GoogleUserInfoFixture.withPhoto.utf8))
        XCTAssertEqual(info.email, "ada@example.com")
        XCTAssertEqual(info.name, "Ada Lovelace")
        let url = try XCTUnwrap(AccountPhotoPolicy.validatedURL(info.picture))
        XCTAssertEqual(url.host, "lh3.googleusercontent.com")
        XCTAssertEqual(url.scheme, "https")
    }

    func testUserInfoWithoutPictureMeansNoPhoto() throws {
        let info = try GoogleUserInfo.decode(Data(GoogleUserInfoFixture.withoutPhoto.utf8))
        XCTAssertEqual(info.name, "Bob")
        XCTAssertNil(info.picture)
        XCTAssertNil(AccountPhotoPolicy.validatedURL(info.picture))
    }

    // MARK: - Fetch (mocked HTTP)

    func testRequestCarriesNoTokenAndNoCookies() async throws {
        let mock = MockPhotoTransport(body: Self.image(width: 96, height: 96))
        _ = try await AccountPhotoFetcher.fetch(URL(string: photoURL)!, transport: mock.transport)
        let req = try XCTUnwrap(mock.requests.first)
        XCTAssertEqual(mock.requests.count, 1)
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(req.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(req.httpShouldHandleCookies)
        XCTAssertEqual(req.httpMethod ?? "GET", "GET")
        XCTAssertNil(req.httpBody)
        XCTAssertEqual(req.url?.absoluteString, photoURL)
    }

    func testFetchDownscalesToTheLargestDrawnRetinaSize() async throws {
        let mock = MockPhotoTransport(body: Self.image(width: 400, height: 200, type: .jpeg),
                                      mime: "image/jpeg")
        let png = try await AccountPhotoFetcher.fetch(URL(string: photoURL)!, transport: mock.transport)
        let (w, h) = try XCTUnwrap(pixelSize(png))
        XCTAssertEqual(max(w, h), AccountPhotoPolicy.maxPixelSize)
        XCTAssertEqual(AccountPhotoPolicy.maxPixelSize, 56)
        // Stored as our own PNG re-encode.
        XCTAssertEqual(png.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
    }

    func testRedirectResponseIsRefused() async {
        let mock = MockPhotoTransport(body: Data(), status: 302,
                                      headers: ["Location": "https://evil.example.com/x.png"])
        await assertFetchFails(mock, .redirected)
    }

    func testResponseFromAnotherHostIsRefused() async {
        let mock = MockPhotoTransport(body: Self.image(width: 8, height: 8),
                                      responseURL: URL(string: "https://evil.example.com/x.png")!)
        await assertFetchFails(mock, .redirected)
        let other = MockPhotoTransport(body: Self.image(width: 8, height: 8),
                                       responseURL: URL(string: "https://lh4.googleusercontent.com/x")!)
        await assertFetchFails(other, .redirected)
    }

    func testNonAllowlistedURLIsNeverRequested() async {
        let mock = MockPhotoTransport(body: Self.image(width: 8, height: 8))
        do {
            _ = try await AccountPhotoFetcher.fetch(URL(string: "https://evil.example.com/a.png")!,
                                                    transport: mock.transport)
            XCTFail("fetched from a non-Google host")
        } catch {
            XCTAssertEqual(error as? AccountPhotoError, .notAllowedURL)
        }
        XCTAssertTrue(mock.requests.isEmpty)
    }

    func testLiveSessionFollowsNoRedirect() {
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: photoURL)!)
        let response = HTTPURLResponse(url: URL(string: photoURL)!, statusCode: 302,
                                       httpVersion: nil, headerFields: nil)!
        let exp = expectation(description: "redirect decision")
        AccountPhotoRedirectRefuser().urlSession(
            session, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://lh3.googleusercontent.com/other")!)
        ) { next in
            XCTAssertNil(next, "no redirect is followed, even to the same host")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
        session.invalidateAndCancel()
    }

    func testLiveSessionKeepsNothingOnDisk() {
        let config = AccountPhotoSession.session.configuration
        XCTAssertNil(config.urlCache)
        XCTAssertNil(config.httpCookieStorage)
        XCTAssertNil(config.urlCredentialStorage)
        XCTAssertFalse(config.httpShouldSetCookies)
        XCTAssertEqual(config.httpCookieAcceptPolicy, .never)
        XCTAssertEqual(config.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertTrue(AccountPhotoSession.session.delegate is AccountPhotoRedirectRefuser)
    }

    func testOversizedBodyIsRefused() async {
        var big = Self.image(width: 8, height: 8)
        big.append(Data(count: AccountPhotoPolicy.maxBytes))
        await assertFetchFails(MockPhotoTransport(body: big), .tooLarge)
        // A declared length over the cap is refused too.
        let declared = MockPhotoTransport(
            body: Self.image(width: 8, height: 8),
            headers: ["Content-Length": String(AccountPhotoPolicy.maxBytes + 1)])
        await assertFetchFails(declared, .tooLarge)
    }

    func testTransportIsAskedForNoMoreThanTheCap() async throws {
        let mock = MockPhotoTransport(body: Self.image(width: 8, height: 8))
        _ = try await AccountPhotoFetcher.fetch(URL(string: photoURL)!, transport: mock.transport)
        XCTAssertEqual(mock.maxBytesAsked, [AccountPhotoPolicy.maxBytes])
    }

    func testNonImageContentIsRefused() async {
        let png = Self.image(width: 8, height: 8)
        for mime in ["text/html", "application/octet-stream", "image/svg+xml", ""] {
            await assertFetchFails(MockPhotoTransport(body: png, mime: mime), .notAnImage)
        }
        // Image content type, but not an image.
        let html = Data("<html><script>alert(1)</script></html>".utf8)
        await assertFetchFails(MockPhotoTransport(body: html), .undecodable)
        // A decodable image of a type we do not accept.
        let tiff = Self.image(width: 8, height: 8, type: .tiff)
        await assertFetchFails(MockPhotoTransport(body: tiff, mime: "image/png"), .undecodable)
    }

    func testHugeCanvasIsRefused() async {
        let wide = Self.image(width: AccountPhotoPolicy.maxSourceDimension + 1, height: 1)
        await assertFetchFails(MockPhotoTransport(body: wide), .undecodable)
    }

    func testServerErrorIsRefused() async {
        await assertFetchFails(MockPhotoTransport(body: Data(), status: 404), .badStatus)
    }

    private func assertFetchFails(_ mock: MockPhotoTransport, _ expected: AccountPhotoError,
                                  file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await AccountPhotoFetcher.fetch(URL(string: photoURL)!, transport: mock.transport)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AccountPhotoError, expected, file: file, line: line)
        }
    }

    // MARK: - Refresh: interval, fallback, demo

    private func refresher(_ q: DatabaseQueue, _ mock: MockPhotoTransport,
                           demo: Bool = false, clock: PhotoTestClock = PhotoTestClock()) -> AccountPhotoRefresher {
        AccountPhotoRefresher(db: q, transport: mock.transport,
                              isDemo: { demo }, now: { clock.now })
    }

    private func stored(_ q: DatabaseQueue, _ id: String) throws -> AccountPhotoRecord? {
        try q.read { try AccountPhotoRecord.fetchOne($0, key: id) }
    }

    // Synchronous on purpose: inside an async test, `q.read` resolves to
    // GRDB's async overload, which an XCTAssert autoclosure cannot await.
    private func storedPhotos(_ q: DatabaseQueue) throws -> [String: Data] {
        try q.read { try AccountPhotoRefresher.loadAll($0) }
    }

    private func photoCount(_ q: DatabaseQueue) throws -> Int {
        try q.read { try AccountPhotoRecord.fetchCount($0) }
    }

    func testSignInStoresThePhotoWithTheAccount() async throws {
        let q = try makeDB()
        try insertAccount(q, "a@x.com")
        let mock = MockPhotoTransport(body: Self.image(width: 96, height: 96))
        let url = photoURL
        let outcome = await refresher(q, mock).refresh(accountId: "a@x.com", force: true) { url }
        XCTAssertEqual(outcome, .stored(hasPhoto: true))
        let row = try XCTUnwrap(stored(q, "a@x.com"))
        XCTAssertNotNil(row.imageData)
        XCTAssertEqual(try storedPhotos(q).keys.sorted(), ["a@x.com"])
    }

    func testRefreshIsAtMostOnceADayUnlessForced() async throws {
        let q = try makeDB()
        try insertAccount(q, "a@x.com")
        let mock = MockPhotoTransport(body: Self.image(width: 96, height: 96))
        let clock = PhotoTestClock()
        let r = refresher(q, mock, clock: clock)
        let asked = PhotoCounter()
        let url = photoURL
        let picture: @Sendable () async throws -> String? = { asked.bump(); return url }

        do {
            let outcome = await r.refresh(accountId: "a@x.com", force: false, pictureURL: picture)
            XCTAssertEqual(outcome, .stored(hasPhoto: true))
        }
        clock.advance(by: 60)
        do {
            let outcome = await r.refresh(accountId: "a@x.com", force: false, pictureURL: picture)
            XCTAssertEqual(outcome, .notDue)
        }
        clock.advance(by: AccountPhotoPolicy.refreshInterval - 120)
        do {
            let outcome = await r.refresh(accountId: "a@x.com", force: false, pictureURL: picture)
            XCTAssertEqual(outcome, .notDue)
        }
        XCTAssertEqual(mock.requests.count, 1)
        XCTAssertEqual(asked.value, 1, "userinfo is not asked when nothing is due")

        clock.advance(by: 61)
        do {
            let outcome = await r.refresh(accountId: "a@x.com", force: false, pictureURL: picture)
            XCTAssertEqual(outcome, .stored(hasPhoto: true))
        }
        XCTAssertEqual(mock.requests.count, 2)

        do {
            let outcome = await r.refresh(accountId: "a@x.com", force: true, pictureURL: picture)
            XCTAssertEqual(outcome, .stored(hasPhoto: true))
        }
        XCTAssertEqual(mock.requests.count, 3)
    }

    func testIntervalPolicy() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func rec(_ ago: TimeInterval, photo: Bool, failed: Bool) -> AccountPhotoRecord {
            AccountPhotoRecord(accountId: "a", imageData: photo ? Data([1]) : nil,
                               fetchedAt: now.addingTimeInterval(-ago), lastAttemptFailed: failed)
        }
        let day = AccountPhotoPolicy.refreshInterval
        let hour = AccountPhotoPolicy.failureRetryInterval
        XCTAssertTrue(AccountPhotoPolicy.isDue(nil, now: now))
        XCTAssertFalse(AccountPhotoPolicy.isDue(rec(3600, photo: true, failed: false), now: now))
        XCTAssertTrue(AccountPhotoPolicy.isDue(rec(day, photo: true, failed: false), now: now))
        XCTAssertFalse(AccountPhotoPolicy.isDue(rec(hour - 1, photo: false, failed: true), now: now))
        XCTAssertTrue(AccountPhotoPolicy.isDue(rec(hour, photo: false, failed: true), now: now),
                      "a failure with nothing to show retries within the hour")
        XCTAssertFalse(AccountPhotoPolicy.isDue(rec(2 * hour, photo: true, failed: true), now: now),
                       "a failure with a photo shown waits the full day")
        XCTAssertFalse(AccountPhotoPolicy.isDue(rec(2 * hour, photo: false, failed: false), now: now),
                       "\"no photo\" is an answer, not a failure")
        XCTAssertTrue(AccountPhotoPolicy.isDue(rec(-3600, photo: true, failed: false), now: now),
                      "a clock set back does not freeze the photo")
    }

    func testFailureFallsBackAndKeepsWhatWasStored() async throws {
        let q = try makeDB()
        try insertAccount(q, "a@x.com")
        let clock = PhotoTestClock()
        let url = photoURL

        // No photo yet, and the fetch fails: nothing to show (initial disc).
        let failing = MockPhotoTransport(body: Data("nope".utf8), mime: "text/html")
        do {
            let outcome = await refresher(q, failing, clock: clock)
                .refresh(accountId: "a@x.com", force: true) { url }
            XCTAssertEqual(outcome, .failed)
        }
        XCTAssertNil(try stored(q, "a@x.com")?.imageData)
        XCTAssertTrue(try storedPhotos(q).isEmpty)
        // The failed attempt still counts for the interval.
        do {
            let outcome = await refresher(q, failing, clock: clock)
                .refresh(accountId: "a@x.com", force: false) { url }
            XCTAssertEqual(outcome, .notDue)
        }

        // A good photo, then a failing refresh: the photo stays.
        let good = MockPhotoTransport(body: Self.image(width: 96, height: 96))
        _ = await refresher(q, good, clock: clock).refresh(accountId: "a@x.com", force: true) { url }
        let photo = try XCTUnwrap(stored(q, "a@x.com")?.imageData)
        let thrower = MockPhotoTransport(error: URLError(.notConnectedToInternet))
        do {
            let outcome = await refresher(q, thrower, clock: clock)
                .refresh(accountId: "a@x.com", force: true) { url }
            XCTAssertEqual(outcome, .failed)
        }
        XCTAssertEqual(try stored(q, "a@x.com")?.imageData, photo)

        // userinfo itself failing is silent too.
        do {
            let outcome = await refresher(q, good, clock: clock)
                .refresh(accountId: "a@x.com", force: true) { throw URLError(.timedOut) }
            XCTAssertEqual(outcome, .failed)
        }
        XCTAssertEqual(try stored(q, "a@x.com")?.imageData, photo)
    }

    func testNoPhotoAnswerClearsTheStoredPhoto() async throws {
        let q = try makeDB()
        try insertAccount(q, "a@x.com")
        let good = MockPhotoTransport(body: Self.image(width: 96, height: 96))
        let url = photoURL
        _ = await refresher(q, good).refresh(accountId: "a@x.com", force: true) { url }
        XCTAssertNotNil(try stored(q, "a@x.com")?.imageData)
        do {
            let outcome = await refresher(q, good).refresh(accountId: "a@x.com", force: true) { nil }
            XCTAssertEqual(outcome, .stored(hasPhoto: false))
        }
        XCTAssertNil(try stored(q, "a@x.com")?.imageData)
        // A URL off the allowlist is "no photo", never a request.
        let before = good.requests.count
        do {
            let outcome = await refresher(q, good).refresh(accountId: "a@x.com", force: true) {
                "https://evil.example.com/me.png"
            }
            XCTAssertEqual(outcome, .stored(hasPhoto: false))
        }
        XCTAssertEqual(good.requests.count, before)
    }

    func testDemoModeMakesNoRequest() async throws {
        let q = try makeDB()
        try insertAccount(q, DemoSeed.account)
        let mock = MockPhotoTransport(body: Self.image(width: 96, height: 96))
        let asked = PhotoCounter()
        let url = photoURL
        let outcome = await refresher(q, mock, demo: true)
            .refresh(accountId: DemoSeed.account, force: true) { asked.bump(); return url }
        XCTAssertEqual(outcome, .skippedDemo)
        XCTAssertTrue(mock.requests.isEmpty)
        XCTAssertEqual(asked.value, 0)
        XCTAssertNil(try stored(q, DemoSeed.account))
    }

    // MARK: - Storage and deletion

    func testRemovedAccountLeavesNoPhoto() async throws {
        let q = try makeDB()
        try insertAccount(q, "a@x.com")
        try insertAccount(q, "b@x.com")
        let mock = MockPhotoTransport(body: Self.image(width: 96, height: 96))
        let url = photoURL
        for id in ["a@x.com", "b@x.com"] {
            _ = await refresher(q, mock).refresh(accountId: id, force: true) { url }
        }
        try await q.write { db in try AccountLifecycle.purgeAccount(db, id: "a@x.com") }
        XCTAssertNil(try stored(q, "a@x.com"))
        XCTAssertNotNil(try stored(q, "b@x.com")?.imageData)
        // The foreign key alone also takes it.
        try await q.write { db in
            try db.execute(sql: "DELETE FROM account WHERE id = 'b@x.com'")
        }
        XCTAssertEqual(try photoCount(q), 0)
    }

    func testAccountRemovedDuringFetchIsNotRecreated() async throws {
        let q = try makeDB()
        try insertAccount(q, "a@x.com")
        let mock = MockPhotoTransport(body: Self.image(width: 96, height: 96))
        let url = photoURL
        let outcome = await refresher(q, mock).refresh(accountId: "a@x.com", force: true) {
            try await q.write { db in try AccountLifecycle.purgeAccount(db, id: "a@x.com") }
            return url
        }
        XCTAssertEqual(outcome, .accountGone)
        XCTAssertEqual(try photoCount(q), 0)
    }

    // MARK: - Failure keeps the stored image (R4)

    func testFailureNeverRewritesTheImageFromAnEarlierRead() async throws {
        let q = try makeDB()
        try insertAccount(q, "a@x.com")
        let url = photoURL
        let good = MockPhotoTransport(body: Self.image(width: 96, height: 96))
        _ = await refresher(q, good).refresh(accountId: "a@x.com", force: true) { url }
        let newer = Data([0x89, 0x50, 0x4E, 0x47, 0x01])
        let failing = MockPhotoTransport(error: URLError(.networkConnectionLost))
        let outcome = await refresher(q, failing).refresh(accountId: "a@x.com", force: true) {
            // Another writer stores a newer photo after the refresher read
            // the row and before its fetch fails.
            try await q.write { db in
                try db.execute(sql: "UPDATE accountPhoto SET imageData = ? WHERE accountId = ?",
                               arguments: [newer, "a@x.com"])
            }
            return url
        }
        XCTAssertEqual(outcome, .failed)
        let row = try XCTUnwrap(stored(q, "a@x.com"))
        XCTAssertEqual(row.imageData, newer, "the failure only records the attempt")
        XCTAssertTrue(row.lastAttemptFailed)
    }

    func testFailureWithNoPhotoRetriesAfterAnHour() async throws {
        let q = try makeDB()
        try insertAccount(q, "a@x.com")
        let clock = PhotoTestClock()
        let url = photoURL
        let failing = MockPhotoTransport(error: URLError(.notConnectedToInternet))
        let r = refresher(q, failing, clock: clock)
        let first = await r.refreshScheduling(accountId: "a@x.com", force: false) { url }
        XCTAssertEqual(first.outcome, .failed)
        XCTAssertEqual(first.nextDue, clock.now.addingTimeInterval(AccountPhotoPolicy.failureRetryInterval))
        clock.advance(by: 30 * 60)
        do {
            let outcome = await r.refresh(accountId: "a@x.com", force: false) { url }
            XCTAssertEqual(outcome, .notDue)
        }
        clock.advance(by: 31 * 60)
        do {
            let outcome = await r.refresh(accountId: "a@x.com", force: false) { url }
            XCTAssertEqual(outcome, .failed)
        }
        XCTAssertEqual(failing.requests.count, 2)

        // Once a photo is stored, a failure waits the full day.
        let good = MockPhotoTransport(body: Self.image(width: 96, height: 96))
        _ = await refresher(q, good, clock: clock).refresh(accountId: "a@x.com", force: true) { url }
        let afterFailure = await r.refreshScheduling(accountId: "a@x.com", force: true) { url }
        XCTAssertEqual(afterFailure.nextDue, clock.now.addingTimeInterval(AccountPhotoPolicy.refreshInterval))
        clock.advance(by: 2 * 60 * 60)
        do {
            let outcome = await r.refresh(accountId: "a@x.com", force: false) { url }
            XCTAssertEqual(outcome, .notDue)
        }
    }

    func testSuccessReportsTheNextDayAsDue() async throws {
        let q = try makeDB()
        try insertAccount(q, "a@x.com")
        let clock = PhotoTestClock()
        let url = photoURL
        let good = MockPhotoTransport(body: Self.image(width: 96, height: 96))
        let result = await refresher(q, good, clock: clock)
            .refreshScheduling(accountId: "a@x.com", force: true) { url }
        XCTAssertEqual(result.outcome, .stored(hasPhoto: true))
        XCTAssertEqual(result.nextDue, clock.now.addingTimeInterval(AccountPhotoPolicy.refreshInterval))
        let demo = await refresher(q, good, demo: true)
            .refreshScheduling(accountId: "a@x.com", force: true) { url }
        XCTAssertEqual(demo, AccountPhotoRefresher.Result(outcome: .skippedDemo, nextDue: nil))
    }

    func testCancelledRefreshWritesNothing() async throws {
        let q = try makeDB()
        try insertAccount(q, "a@x.com")
        let good = MockPhotoTransport(body: Self.image(width: 96, height: 96))
        let r = refresher(q, good)
        let url = photoURL
        let gate = PhotoCounter()
        let task = Task {
            await r.refresh(accountId: "a@x.com", force: true) {
                gate.bump()
                while !Task.isCancelled { await Task.yield() }
                return url
            }
        }
        while gate.value == 0 { await Task.yield() }
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertNil(try stored(q, "a@x.com"))
    }

    // MARK: - Clean re-encode (R3)

    func testReencodeDropsColorProfileAndMetadata() throws {
        // A Display P3 JPEG with EXIF and GPS metadata.
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: p3,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(colorSpace: p3, components: [1, 0, 0, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        let source = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(
            source as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil))
        let meta: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "secret comment"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "secret artist"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 41.1, kCGImagePropertyGPSLatitudeRef: "N"],
        ]
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), meta as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        // The fixture really is Display P3. (Whether ImageIO keeps the
        // metadata dictionaries in the JPEG varies; the output checks below
        // hold either way.)
        let inImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(
            CGImageSourceCreateWithData(source as CFData, nil)!, 0, nil))
        XCTAssertEqual(inImage.colorSpace?.name, CGColorSpace.displayP3, "fixture is Display P3")

        let out = try XCTUnwrap(AccountPhotoPolicy.normalizedImage(from: source as Data))
        XCTAssertLessThanOrEqual(out.count, AccountPhotoPolicy.maxStoredBytes)
        let outSource = try XCTUnwrap(CGImageSourceCreateWithData(out as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(outSource) as String?, UTType.png.identifier)
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(outSource, 0, nil)
            as? [CFString: Any])
        // ImageIO reports pixel dimensions under {Exif} for any PNG; what
        // must not survive is the source's own metadata.
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        XCTAssertNil(exif[kCGImagePropertyExifUserComment], "\(exif)")
        XCTAssertNil(props[kCGImagePropertyGPSDictionary], "GPS survived")
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        XCTAssertNil(tiff[kCGImagePropertyTIFFArtist], "\(tiff)")
        let profile = props[kCGImagePropertyProfileName] as? String ?? ""
        XCTAssertFalse(profile.localizedCaseInsensitiveContains("P3"), profile)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(outSource, 0, nil))
        XCTAssertNotEqual(image.colorSpace?.name, CGColorSpace.displayP3, "\(String(describing: image.colorSpace))")
        XCTAssertEqual(image.bitsPerComponent, 8)
        XCTAssertEqual(max(image.width, image.height), AccountPhotoPolicy.maxPixelSize,
                       "\(image.width)x\(image.height)")
        XCTAssertFalse(String(decoding: out, as: UTF8.self).contains("secret"))
    }

    func testMultiFrameImageIsRefused() throws {
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(
            out as CFMutableData, UTType.png.identifier as CFString, 2, nil))
        for _ in 0..<2 {
            let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(
                CGImageSourceCreateWithData(Self.image(width: 8, height: 8) as CFData, nil)!, 0, nil))
            CGImageDestinationAddImage(dest, frame, nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let src = try XCTUnwrap(CGImageSourceCreateWithData(out as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(src), 2, "fixture is an animated PNG")
        XCTAssertNil(AccountPhotoPolicy.normalizedImage(from: out as Data))
    }

    // MARK: - URL hardening (S1)

    func testPercentEncodedOrMalformedHostsAreRefused() {
        for raw in ["https://lh3%2Egoogleusercontent.com/a/x",
                    "https://lh3.googleusercontent%2Ecom/a/x",
                    "https://%6Ch3.googleusercontent.com/a/x",
                    "https://lh3.googleusercontent.com./a/x"] {
            XCTAssertNil(AccountPhotoPolicy.validatedURL(raw), raw)
        }
    }

    func testFetchValidatesTheURLItself() async {
        let mock = MockPhotoTransport(body: Self.image(width: 8, height: 8))
        for raw in ["http://lh3.googleusercontent.com/a", "https://lh3.googleusercontent.com:444/a",
                    "https://u@lh3.googleusercontent.com/a", "https://evil.example.com/a"] {
            do {
                _ = try await AccountPhotoFetcher.fetch(URL(string: raw)!, transport: mock.transport)
                XCTFail("fetched \(raw)")
            } catch {
                XCTAssertEqual(error as? AccountPhotoError, .notAllowedURL, raw)
            }
        }
        XCTAssertTrue(mock.requests.isEmpty)
    }

    // MARK: - The real transport, over a stub URLProtocol (R2)

    private func liveFetch(_ raw: String) async throws -> Data {
        let config = AccountPhotoSession.configuration
        config.protocolClasses = [PhotoStubProtocol.self]
        let session = AccountPhotoSession.makeSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        return try await AccountPhotoFetcher.fetch(
            URL(string: raw)!, transport: .streaming(session: session))
    }

    private let otherPhotoURL = "https://lh3.googleusercontent.com/a/other=s96-c"

    func testLiveTransportFetchesWithoutTokenOrCookies() async throws {
        PhotoStubProtocol.state.reset([
            photoURL: .init(status: 200, headers: ["Content-Type": "image/png"],
                            body: Self.image(width: 96, height: 96)),
        ])
        let png = try await liveFetch(photoURL)
        XCTAssertNotNil(pixelSize(png))
        let seen = PhotoStubProtocol.state.requests
        XCTAssertEqual(seen.map { $0.url?.absoluteString }, [photoURL])
        XCTAssertNil(seen.first?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(seen.first?.value(forHTTPHeaderField: "Cookie"))
    }

    func testLiveTransportFollowsNoRedirect() async throws {
        let image = Self.image(width: 96, height: 96)
        for target in ["https://evil.example.com/me.png", otherPhotoURL] {
            PhotoStubProtocol.state.reset([
                photoURL: .init(status: 302, headers: ["Location": target, "Content-Type": "image/png"],
                                body: Data(), redirectTo: URL(string: target)),
                target: .init(status: 200, headers: ["Content-Type": "image/png"], body: image),
            ])
            do {
                _ = try await liveFetch(photoURL)
                XCTFail("redirect to \(target) was followed and accepted")
            } catch {
                // Refused (as a 3xx) or failed: either way nothing accepted.
            }
            XCTAssertEqual(PhotoStubProtocol.state.requests.map { $0.url?.absoluteString }, [photoURL],
                           "no second request for \(target)")
        }
    }

    func testLiveTransportStopsAtTheCapWithoutContentLength() async {
        var body = Self.image(width: 8, height: 8)
        body.append(Data(count: AccountPhotoPolicy.maxBytes))
        PhotoStubProtocol.state.reset([
            photoURL: .init(status: 200, headers: ["Content-Type": "image/png"], body: body, chunked: true),
        ])
        do {
            _ = try await liveFetch(photoURL)
            XCTFail("oversized body accepted")
        } catch {
            XCTAssertEqual(error as? AccountPhotoError, .tooLarge)
        }
    }

    func testLiveTransportRefusesADeclaredLengthOverTheCap() async {
        PhotoStubProtocol.state.reset([
            photoURL: .init(status: 200,
                            headers: ["Content-Type": "image/png",
                                      "Content-Length": String(AccountPhotoPolicy.maxBytes + 1)],
                            body: Self.image(width: 8, height: 8)),
        ])
        do {
            _ = try await liveFetch(photoURL)
            XCTFail("declared oversized body accepted")
        } catch {
            XCTAssertEqual(error as? AccountPhotoError, .tooLarge)
        }
    }

    func testLiveTransportRefusesNon200() async {
        PhotoStubProtocol.state.reset([
            photoURL: .init(status: 500, headers: ["Content-Type": "image/png"],
                            body: Self.image(width: 8, height: 8)),
        ])
        do {
            _ = try await liveFetch(photoURL)
            XCTFail("500 accepted")
        } catch {
            XCTAssertEqual(error as? AccountPhotoError, .badStatus)
        }
    }

    /// The photo path writes nowhere but the database, and logs nothing.
    func testPhotoCodeHasNoFileWritesOrLogging() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for rel in ["Sources/MishMail/Support/AccountPhoto.swift",
                    "Sources/MishMail/Gmail/GoogleUserInfo.swift",
                    "Sources/MishMail/UI/AccountAvatarView.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
            for banned in ["NSLog(", "print(", "os_log", "Logger(", "DiagnosticLog",
                           "FileManager", ".write(to:", "cachesDirectory", "URLCache(",
                           "URLSession.shared"] {
                XCTAssertFalse(text.contains(banned), "\(banned) in \(rel)")
            }
        }
    }
}

// MARK: - Test doubles

final class MockPhotoTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var caps: [Int] = []
    let body: Data
    let status: Int
    let headers: [String: String]
    let responseURL: URL?
    let error: Error?

    init(body: Data = Data(), status: Int = 200, mime: String = "image/png",
         headers: [String: String] = [:], responseURL: URL? = nil, error: Error? = nil) {
        self.body = body
        self.status = status
        var h = headers
        if !mime.isEmpty { h["Content-Type"] = mime }
        self.headers = h
        self.responseURL = responseURL
        self.error = error
    }

    convenience init(error: Error) {
        self.init(body: Data(), error: error)
    }

    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    var maxBytesAsked: [Int] { lock.lock(); defer { lock.unlock() }; return caps }

    var transport: AccountPhotoTransport {
        AccountPhotoTransport { [self] request, maxBytes in
            lock.withLock { recorded.append(request); caps.append(maxBytes) }
            if let error { throw error }
            let response = HTTPURLResponse(url: responseURL ?? request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: headers)!
            return (body, response)
        }
    }
}

/// Serves canned replies inside a URLSession built with `protocolClasses`,
/// and records every request that reaches it.
final class PhotoStubProtocol: URLProtocol {
    struct Reply {
        var status: Int
        var headers: [String: String]
        var body: Data
        var redirectTo: URL? = nil
        var chunked = false
    }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [String: Reply] = [:]
        private var seen: [URLRequest] = []
        func reset(_ replies: [String: Reply]) {
            lock.withLock { self.replies = replies; seen = [] }
        }
        func take(_ request: URLRequest) -> Reply? {
            lock.withLock {
                seen.append(request)
                return replies[request.url?.absoluteString ?? ""]
            }
        }
        var requests: [URLRequest] { lock.withLock { seen } }
    }

    static let state = State()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let reply = Self.state.take(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        if let target = reply.redirectTo {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target),
                                redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if reply.chunked {
            var offset = 0
            while offset < reply.body.count {
                let end = min(offset + 64 * 1024, reply.body.count)
                client?.urlProtocol(self, didLoad: reply.body.subdata(in: offset..<end))
                offset = end
            }
        } else if !reply.body.isEmpty {
            client?.urlProtocol(self, didLoad: reply.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class PhotoTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(by seconds: TimeInterval) {
        lock.lock(); current += seconds; lock.unlock()
    }
}

final class PhotoCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func bump() { lock.lock(); n += 1; lock.unlock() }
}
