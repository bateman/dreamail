import XCTest
import ImageIO
import UniformTypeIdentifiers

/// The app's own remote-image client (`RemoteImageFetcher` over
/// `RemoteImageTransport.streaming`), driven through the real URLSession
/// with a stub `URLProtocol`: no real network.
final class RemoteImageFetchTests: XCTestCase {
    private let url = "https://img.example.com/a.png"

    override func setUp() {
        super.setUp()
        RemoteStubProtocol.state.reset([:])
    }

    /// Public addresses for every name, except names starting "lan."
    static let publicResolver: @Sendable (String) async -> [[UInt8]]? = { host in
        if host.hasPrefix("lan.") { return [[192, 168, 1, 20]] }
        if host.hasPrefix("nxdomain.") { return nil }
        return [[93, 184, 216, 34]]
    }

    private func makeSession(timeout: TimeInterval = 5) -> URLSession {
        let config = RemoteImageSession.configuration(requestTimeout: timeout,
                                                      resourceTimeout: timeout)
        config.protocolClasses = [RemoteStubProtocol.self]
        return RemoteImageSession.makeSession(configuration: config)
    }

    private func fetch(_ raw: String, timeout: TimeInterval = 5) async throws -> FetchedRemoteImage {
        let session = makeSession(timeout: timeout)
        defer { session.finishTasksAndInvalidate() }
        return try await RemoteImageFetcher.fetch(
            raw, transport: .streaming(session: session, resolve: Self.publicResolver))
    }

    static func image(_ type: UTType = .png, width: Int = 4, height: Int = 4) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out as CFMutableData,
                                                    type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    /// A refused redirect leaves the stub's 3xx unanswered: a short timeout
    /// ends those requests.
    private func fails(_ raw: String, timeout: TimeInterval = 1) async -> Bool {
        do {
            _ = try await fetch(raw, timeout: timeout)
            return false
        } catch {
            return true
        }
    }

    // MARK: Happy path and headers

    func testFetchesARasterImageWithFixedHeadersAndNoCookiesRefererOrCredentials() async throws {
        let png = Self.image()
        RemoteStubProtocol.state.reset([url: .init(status: 200, headers: ["Content-Type": "image/png"],
                                                   body: png)])
        let cookie = HTTPCookie(properties: [
            .domain: "img.example.com", .path: "/", .name: "track", .value: "1", .secure: "TRUE",
        ])!
        HTTPCookieStorage.shared.setCookie(cookie)
        defer { HTTPCookieStorage.shared.deleteCookie(cookie) }

        let image = try await fetch(url)
        XCTAssertEqual(image.data, png)
        XCTAssertEqual(image.mimeType, "image/png")
        let seen = RemoteStubProtocol.state.requests
        XCTAssertEqual(seen.count, 1)
        let request = try XCTUnwrap(seen.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), RemoteImageFetchPolicy.acceptHeader)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), RemoteImageFetchPolicy.userAgent)
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testSetCookieInTheResponseIsNotKept() async throws {
        RemoteStubProtocol.state.reset([
            url: .init(status: 200, headers: ["Content-Type": "image/png",
                                              "Set-Cookie": "id=42; Secure; Path=/"],
                       body: Self.image()),
        ])
        _ = try await fetch(url)
        _ = try await fetch(url)
        let second = RemoteStubProtocol.state.requests.last
        XCTAssertNil(second?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(HTTPCookieStorage.shared.cookies(for: URL(string: url)!)?.first { $0.name == "id" })
    }

    func testAllFourRasterTypesAreAcceptedAndTheMIMEComesFromTheBytes() async throws {
        let cases: [(UTType, String)] = [(.png, "image/png"), (.jpeg, "image/jpeg"),
                                         (.gif, "image/gif")]
        for (type, mime) in cases {
            // The server mislabels everything as JPEG: the stored type is sniffed.
            RemoteStubProtocol.state.reset([url: .init(status: 200,
                                                       headers: ["Content-Type": "image/jpeg"],
                                                       body: Self.image(type))])
            let image = try await fetch(url)
            XCTAssertEqual(image.mimeType, mime)
        }
        XCTAssertEqual(RemoteImageFetchPolicy.acceptedTypes["org.webmproject.webp"], "image/webp")
    }

    // MARK: URL rules

    func testHTTPAndOddURLsAreRefusedWithoutARequest() async {
        for raw in ["http://img.example.com/a.png", "https://img.example.com:8443/a.png",
                    "https://user:pw@img.example.com/a.png", "ftp://img.example.com/a.png",
                    "https://localhost/a.png", "https://printer.local/a.png",
                    "https://intranet/a.png", "https://127.0.0.1/a.png", "https://127.1/a.png",
                    "https://2130706433/a.png", "https://0x7f000001/a.png", "https://10.0.0.8/a.png",
                    "https://192.168.1.1/a.png", "https://172.20.0.1/a.png",
                    "https://169.254.169.254/latest", "https://100.64.0.1/a.png",
                    "https://[::1]/a.png", "https://[fe80::1]/a.png", "https://[fd00::1]/a.png",
                    "https://[::ffff:192.168.0.1]/a.png", "https://0.0.0.0/a.png"] {
            let failed = await fails(raw)
            XCTAssertTrue(failed, raw)
        }
        XCTAssertEqual(RemoteStubProtocol.state.requests.count, 0, "nothing was requested")
    }

    func testANameResolvingToAPrivateAddressIsRefused() async {
        RemoteStubProtocol.state.reset([
            "https://lan.example.com/a.png": .init(status: 200, headers: ["Content-Type": "image/png"],
                                                   body: Self.image()),
        ])
        do {
            _ = try await fetch("https://lan.example.com/a.png")
            XCTFail("private target accepted")
        } catch {
            XCTAssertEqual(error as? RemoteImageFetchError, .privateAddress)
        }
        let unresolvable = await fails("https://nxdomain.example.com/a.png")
        XCTAssertTrue(unresolvable)
        XCTAssertEqual(RemoteStubProtocol.state.requests.count, 0)
    }

    func testPublicLiteralAddressesPass() {
        XCTAssertFalse(RemoteImageHostPolicy.isRefusedHost("93.184.216.34"))
        XCTAssertFalse(RemoteImageHostPolicy.isRefusedHost("[2606:2800:220:1::1]"))
        XCTAssertTrue(RemoteImageHostPolicy.isRefusedHost("[2001:db8::1]"))
        XCTAssertTrue(RemoteImageHostPolicy.isRefusedHost("[::ffff:7f00:1]"))
        XCTAssertFalse(RemoteImageHostPolicy.isRefusedHost("cdn.example.com"))
    }

    // MARK: Redirects

    func testRedirectsToHTTPSAreFollowedUpToTheLimit() async throws {
        let png = Self.image()
        let hop1 = "https://img2.example.com/b.png"
        let hop2 = "https://img3.example.com/c.png"
        RemoteStubProtocol.state.reset([
            url: .init(status: 302, headers: ["Location": hop1], body: Data(), redirectTo: URL(string: hop1)),
            hop1: .init(status: 301, headers: ["Location": hop2], body: Data(), redirectTo: URL(string: hop2)),
            hop2: .init(status: 200, headers: ["Content-Type": "image/png"], body: png),
        ])
        let image = try await fetch(url)
        XCTAssertEqual(image.data, png)
        let seen = RemoteStubProtocol.state.requests
        XCTAssertEqual(seen.map { $0.url?.absoluteString }, [url, hop1, hop2])
        // Each hop is a fresh request: the same fixed headers, no Referer.
        for request in seen {
            XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), RemoteImageFetchPolicy.acceptHeader)
        }
    }

    func testRedirectChainLongerThanTheLimitIsRefused() async {
        var replies: [String: RemoteStubProtocol.Reply] = [:]
        let hops = (0...RemoteImageFetchPolicy.maxRedirects + 1).map { "https://h\($0).example.com/x.png" }
        for (index, hop) in hops.enumerated() {
            if index + 1 < hops.count {
                replies[hop] = .init(status: 302, headers: ["Location": hops[index + 1]], body: Data(),
                                     redirectTo: URL(string: hops[index + 1]))
            } else {
                replies[hop] = .init(status: 200, headers: ["Content-Type": "image/png"], body: Self.image())
            }
        }
        RemoteStubProtocol.state.reset(replies)
        let failed = await fails(hops[0])
        XCTAssertTrue(failed)
        XCTAssertEqual(RemoteStubProtocol.state.requests.count, RemoteImageFetchPolicy.maxRedirects + 1)
    }

    func testRedirectToHTTPOrAPrivateHostIsRefused() async {
        for target in ["http://img.example.com/a.png", "https://127.0.0.1/a.png",
                       "https://lan.example.com/a.png", "https://img.example.com:444/a.png"] {
            RemoteStubProtocol.state.reset([
                url: .init(status: 302, headers: ["Location": target], body: Data(),
                           redirectTo: URL(string: target)),
                target: .init(status: 200, headers: ["Content-Type": "image/png"], body: Self.image()),
            ])
            let failed = await fails(url)
            XCTAssertTrue(failed, target)
            XCTAssertEqual(RemoteStubProtocol.state.requests.map { $0.url?.absoluteString }, [url],
                           "no request to \(target)")
        }
    }

    // MARK: Size and type

    func testDeclaredLengthOverTheCapIsRefused() async {
        RemoteStubProtocol.state.reset([
            url: .init(status: 200, headers: ["Content-Type": "image/png",
                                              "Content-Length": String(RemoteImageFetchPolicy.maxImageBytes + 1)],
                       body: Self.image()),
        ])
        do {
            _ = try await fetch(url)
            XCTFail("declared oversized body accepted")
        } catch {
            XCTAssertEqual(error as? RemoteImageFetchError, .tooLarge)
        }
    }

    func testStreamedBodyOverTheCapIsRefused() async {
        var body = Self.image()
        body.append(Data(count: RemoteImageFetchPolicy.maxImageBytes))
        RemoteStubProtocol.state.reset([
            url: .init(status: 200, headers: ["Content-Type": "image/png"], body: body, chunked: true),
        ])
        do {
            _ = try await fetch(url)
            XCTFail("streamed oversized body accepted")
        } catch {
            XCTAssertEqual(error as? RemoteImageFetchError, .tooLarge)
        }
    }

    func testTheTransportReadsNoMoreThanTheCapPlusOne() async throws {
        var body = Data(count: RemoteImageFetchPolicy.maxImageBytes * 2)
        body[0] = 1
        RemoteStubProtocol.state.reset([
            url: .init(status: 200, headers: ["Content-Type": "image/png"], body: body, chunked: true),
        ])
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        let transport = RemoteImageTransport.streaming(session: session, resolve: Self.publicResolver)
        let (data, _) = try await transport.fetch(RemoteImageFetchPolicy.request(for: URL(string: url)!),
                                                  RemoteImageFetchPolicy.maxImageBytes)
        XCTAssertEqual(data.count, RemoteImageFetchPolicy.maxImageBytes + 1)
    }

    func testNonImagesAndSVGAreRefused() async {
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"><script>alert(1)</script></svg>".utf8)
        let cases: [(String, Data)] = [
            ("image/svg+xml", svg),
            ("image/png", svg),                      // mislabelled SVG: ImageIO refuses
            ("text/html", Self.image()),             // a PNG served as HTML
            ("image/png", Data("not an image".utf8)),
            ("application/octet-stream", Data("GIF89a-but-not-really".utf8)),
        ]
        for (mime, body) in cases {
            RemoteStubProtocol.state.reset([url: .init(status: 200, headers: ["Content-Type": mime],
                                                       body: body)])
            do {
                _ = try await fetch(url)
                XCTFail("accepted \(mime)")
            } catch {
                XCTAssertEqual(error as? RemoteImageFetchError, .notAnImage, mime)
            }
        }
    }

    func testHugeCanvasIsRefused() {
        // A header claiming more pixels than WebKit should be asked to decode.
        XCTAssertNil(RemoteImageFetchPolicy.sniffedMIME(Self.image(width: 16_385, height: 1)))
        XCTAssertEqual(RemoteImageFetchPolicy.sniffedMIME(Self.image()), "image/png")
    }

    func testNon200IsRefused() async {
        for status in [204, 304, 404, 500] {
            RemoteStubProtocol.state.reset([url: .init(status: status,
                                                       headers: ["Content-Type": "image/png"],
                                                       body: Self.image())])
            let failed = await fails(url)
            XCTAssertTrue(failed, "\(status)")
        }
    }

    func testAServerThatNeverAnswersTimesOut() async {
        RemoteStubProtocol.state.reset([url: .init(status: 200, headers: [:], body: Data(), hang: true)])
        let started = Date()
        do {
            _ = try await fetch(url, timeout: 0.5)
            XCTFail("a hung request returned")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        }
    }

    func testFetchAllRespectsTheConcurrencyLimit() async {
        let urls = (0..<10).map { "https://img.example.com/\($0).png" }
        let png = Self.image()
        let probe = ConcurrencyProbe()
        let transport = RemoteImageTransport(fetch: { request, _ in
            probe.enter()
            try await Task.sleep(nanoseconds: 20_000_000)
            probe.leave()
            return (png, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                         headerFields: ["Content-Type": "image/png"])!)
        }, resolve: Self.publicResolver)
        let out = await RemoteImageFetcher.fetchAll(urls, transport: transport)
        XCTAssertEqual(out.images.count, 10)
        XCTAssertLessThanOrEqual(probe.peak, RemoteImageFetchPolicy.concurrency)
        XCTAssertGreaterThan(probe.peak, 1)
    }

    func testFetchAllStopsStartingOnceTheByteBudgetIsReached() async {
        let urls = (0..<20).map { "https://img.example.com/\($0).png" }
        let png = Self.image(width: 64, height: 64)
        let counter = ConcurrencyProbe()
        let transport = RemoteImageTransport(fetch: { request, _ in
            counter.enter()
            return (png, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                         headerFields: ["Content-Type": "image/png"])!)
        }, resolve: Self.publicResolver)
        let out = await RemoteImageFetcher.fetchAll(urls, byteBudget: png.count * 2,
                                                    transport: transport)
        XCTAssertLessThan(counter.started, 20, "no download past the budget")
        XCTAssertLessThanOrEqual(out.images.count, 2 + RemoteImageFetchPolicy.concurrency)
    }

    func testOnlyTheFourRasterSignaturesReachImageIO() {
        XCTAssertEqual(RemoteImageFetchPolicy.magicType(Self.image(.png)), "public.png")
        XCTAssertEqual(RemoteImageFetchPolicy.magicType(Self.image(.jpeg)), "public.jpeg")
        XCTAssertEqual(RemoteImageFetchPolicy.magicType(Self.image(.gif)), "com.compuserve.gif")
        XCTAssertEqual(RemoteImageFetchPolicy.magicType(Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 ".utf8)),
                       "org.webmproject.webp")
        for other in [Self.image(.tiff), Self.image(.bmp), Data("<svg/>".utf8), Data(),
                      Data([0xFF, 0xD8]), Data("RIFF0000WAVE".utf8)] {
            XCTAssertNil(RemoteImageFetchPolicy.magicType(other))
            XCTAssertNil(RemoteImageFetchPolicy.sniffedMIME(other))
        }
        // A PNG signature in front of something else: ImageIO must agree.
        var fake = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        fake.append(Self.image(.jpeg))
        XCTAssertNil(RemoteImageFetchPolicy.sniffedMIME(fake))
    }

    func testAppWideGateLimitsRequestsInFlight() async {
        let gate = RemoteImageFetchGate(limit: 2)
        await gate.acquire()
        await gate.acquire()
        let third = Task { await gate.acquire() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let peak = await gate.peak
        XCTAssertEqual(peak, 2)
        await gate.release()
        await third.value
        let after = await gate.peak
        XCTAssertEqual(after, 2, "the third ran only after a release")
    }

    func testOfflineAndUnresolvedAreNotRefusals() {
        XCTAssertFalse(RemoteImageFetcher.isRefusal(URLError(.notConnectedToInternet)))
        XCTAssertFalse(RemoteImageFetcher.isRefusal(URLError(.timedOut)))
        XCTAssertFalse(RemoteImageFetcher.isRefusal(RemoteImageFetchError.unresolved))
        XCTAssertFalse(RemoteImageFetcher.isRefusal(CancellationError()))
        XCTAssertTrue(RemoteImageFetcher.isRefusal(RemoteImageFetchError.notAnImage))
        XCTAssertTrue(RemoteImageFetcher.isRefusal(RemoteImageFetchError.privateAddress))
    }

    /// The fetcher, the cache and the rewriter write nothing but the
    /// database and log nothing (no URL, host or message id can leak).
    func testRemoteImageCodeHasNoFileWritesOrLogging() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in ["Sources/DreaMail/Support/RemoteImageFetch.swift",
                     "Sources/DreaMail/Support/RemoteImageHTML.swift",
                     "Sources/DreaMail/Support/RemoteImageResolver.swift",
                     "Sources/DreaMail/Store/RemoteImageCache.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            for forbidden in ["NSLog", "os_log", "Logger(", "print(", "DiagnosticLog", "PerfMetrics",
                              ".write(to:", "FileManager", "createFile"] {
                XCTAssertFalse(source.contains(forbidden), "\(forbidden) in \(path)")
            }
        }
    }
}

final class ConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var maximum = 0
    private var count = 0
    var peak: Int { lock.withLock { maximum } }
    var started: Int { lock.withLock { count } }
    func enter() { lock.withLock { current += 1; count += 1; maximum = max(maximum, current) } }
    func leave() { lock.withLock { current -= 1 } }
}

/// Stub for the remote-image transport tests: replies by URL, can redirect
/// (and then stops, so the session decides whether to follow), stream in
/// chunks, or never answer.
final class RemoteStubProtocol: URLProtocol {
    struct Reply {
        var status: Int
        var headers: [String: String]
        var body: Data
        var redirectTo: URL? = nil
        var chunked = false
        var hang = false
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
        if reply.hang { return }
        let response = HTTPURLResponse(url: url, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        if let target = reply.redirectTo {
            // The session follows (a new load starts) or refuses; a refused
            // one is left to the request timeout.
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target),
                                redirectResponse: response)
            return
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
