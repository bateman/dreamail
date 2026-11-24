import Foundation
import ImageIO

// MARK: - Rules

/// What the app's own remote-image fetcher accepts. The web view is never
/// asked to fetch what this refuses: such an image stays an `https:` URL in
/// the document and loads live, exactly as before the cache.
enum RemoteImageFetchPolicy {
    /// One image, enforced while the body streams and on `Content-Length`.
    static let maxImageBytes = 3 * 1_024 * 1_024
    /// All cached images of one message together.
    static let maxMessageBytes = 6 * 1_024 * 1_024
    /// Distinct image URLs fetched for one message; the rest load live.
    static let maxImagesPerMessage = 40
    /// Redirects followed, each to https on the default port and re-checked.
    static let maxRedirects = 3
    /// Requests in flight for one message.
    static let concurrency = 4
    static let requestTimeout: TimeInterval = 15
    static let resourceTimeout: TimeInterval = 30
    /// Largest side and pixel count accepted (decoding stays WebKit's).
    static let maxDimension = 16_384
    static let maxPixels = 50_000_000

    /// Sent with every request, whatever the image: no per-user detail.
    static let acceptHeader = "image/webp,image/png,image/jpeg,image/gif;q=0.9"
    /// WebKit's own frozen User-Agent shape, so the sender learns nothing the
    /// web view did not already send.
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)"

    /// Raster types stored, by ImageIO type identifier → stored MIME type.
    /// SVG is never fetched or stored (it stays live under the allowed CSP).
    static let acceptedTypes: [String: String] = [
        "public.jpeg": "image/jpeg",
        "public.png": "image/png",
        "com.compuserve.gif": "image/gif",
        "org.webmproject.webp": "image/webp",
    ]

    /// Response `Content-Type`s let through to the ImageIO check.
    static func acceptsResponseMIME(_ raw: String?) -> Bool {
        let mime = (raw ?? "").split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        if mime.isEmpty || mime == "application/octet-stream" || mime == "binary/octet-stream" {
            return true
        }
        return mime.hasPrefix("image/") && !mime.contains("svg")
    }

    /// https, a host name or public literal address, the default port, no
    /// user info. Names are checked again after DNS (`RemoteImageHostPolicy`).
    static func isAllowedRequestURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.port == nil || components.port == 443,
              components.user == nil, components.password == nil
        else { return false }
        return !RemoteImageHostPolicy.isRefusedHost(host)
    }

    static func request(for url: URL) -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                             timeoutInterval: requestTimeout)
        req.httpMethod = "GET"
        req.httpShouldHandleCookies = false
        req.setValue(acceptHeader, forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("en", forHTTPHeaderField: "Accept-Language")
        return req
    }

    /// The stored MIME type of `data`, or nil unless ImageIO reads it as one
    /// of the accepted raster types with sane dimensions. Reads the header
    /// only (no pixel decode). Call off the main thread.
    static func sniffedMIME(_ data: Data) -> String? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, opts),
              let type = CGImageSourceGetType(source) as String?,
              let mime = acceptedTypes[type],
              CGImageSourceGetCount(source) >= 1,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, opts) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= maxDimension, height <= maxDimension,
              width * height <= maxPixels
        else { return nil }
        return mime
    }
}

/// Which hosts the fetcher refuses: names that mean this machine or the
/// local network, and literal addresses that are not public. A name is also
/// resolved before the request and refused if any address is not public
/// (`resolve`); the connection resolves again, so a DNS answer that changes
/// in between (rebinding) is not caught: that residual is the web view's
/// already.
enum RemoteImageHostPolicy {
    static func isRefusedHost(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return true }
        if let address = literalAddress(host) { return !isPublic(address) }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local")
            || host.hasSuffix(".internal") || host.hasSuffix(".home.arpa") {
            return true
        }
        // A single label goes through the resolver's search domains.
        return !host.contains(".")
    }

    /// 4 or 16 bytes when `host` is a literal address in any form the system
    /// resolver accepts (`127.1`, `0x7f000001`, `2130706433`, `::1`…).
    static func literalAddress(_ host: String) -> [UInt8]? {
        if host.contains(":") {
            var addr = in6_addr()
            guard inet_pton(AF_INET6, host, &addr) == 1 else { return nil }
            return withUnsafeBytes(of: &addr) { Array($0) }
        }
        guard host.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == "x" }) else { return nil }
        var addr = in_addr()
        guard inet_aton(host, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

    /// Public unicast only: not loopback, private, link-local, shared
    /// (CGNAT), unique-local, multicast, unspecified or reserved.
    static func isPublic(_ bytes: [UInt8]) -> Bool {
        if bytes.count == 4 { return isPublicV4(bytes) }
        guard bytes.count == 16 else { return false }
        // IPv4-mapped / -compatible / NAT64 well-known: judge the IPv4 part.
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return isPublicV4(Array(bytes[12..<16]))
        }
        if bytes[0..<12].allSatisfy({ $0 == 0 }) { return false }  // ::, ::1, compat
        if bytes[0] == 0x00, bytes[1] == 0x64, bytes[2] == 0xFF, bytes[3] == 0x9B {
            return isPublicV4(Array(bytes[12..<16]))
        }
        if bytes[0] == 0xFF { return false }                       // multicast
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return false }  // fe80::/10
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0xC0 { return false }  // fec0::/10
        if bytes[0] & 0xFE == 0xFC { return false }                // fc00::/7
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0D, bytes[3] == 0xB8 {
            return false                                            // documentation
        }
        return true
    }

    private static func isPublicV4(_ b: [UInt8]) -> Bool {
        switch b[0] {
        case 0, 10, 127: return false
        case 100 where b[1] & 0xC0 == 64: return false             // 100.64/10
        case 169 where b[1] == 254: return false
        case 172 where b[1] & 0xF0 == 16: return false
        case 192 where b[1] == 168: return false
        case 192 where b[1] == 0 && (b[2] == 0 || b[2] == 2): return false
        case 198 where b[1] & 0xFE == 18: return false             // 198.18/15
        case 198 where b[1] == 51 && b[2] == 100: return false
        case 203 where b[1] == 0 && b[2] == 113: return false
        case 224...255: return false
        default: return true
        }
    }

    /// Every address `host` resolves to (system resolver), or nil when it
    /// does not resolve. Blocks a background thread for the lookup.
    static func resolveLive(_ host: String) async -> [[UInt8]]? {
        await Task.detached(priority: .utility) { () -> [[UInt8]]? in
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, "443", &hints, &result) == 0, let first = result else {
                return nil
            }
            defer { freeaddrinfo(first) }
            var out: [[UInt8]] = []
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            while let info = cursor {
                if let sa = info.pointee.ai_addr {
                    if info.pointee.ai_family == AF_INET {
                        sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                            var addr = sin.pointee.sin_addr
                            out.append(withUnsafeBytes(of: &addr) { Array($0) })
                        }
                    } else if info.pointee.ai_family == AF_INET6 {
                        sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                            var addr = sin6.pointee.sin6_addr
                            out.append(withUnsafeBytes(of: &addr) { Array($0) })
                        }
                    }
                }
                cursor = info.pointee.ai_next
            }
            return out
        }.value
    }

    /// Literal checks, then (for a name) every resolved address public.
    static func hostIsReachable(_ host: String,
                                resolve: @Sendable (String) async -> [[UInt8]]?) async -> Bool {
        guard !isRefusedHost(host) else { return false }
        var bare = host.lowercased()
        if bare.hasPrefix("["), bare.hasSuffix("]") { bare = String(bare.dropFirst().dropLast()) }
        if literalAddress(bare) != nil { return true }
        guard let addresses = await resolve(bare), !addresses.isEmpty else { return false }
        return addresses.allSatisfy(isPublic)
    }
}

// MARK: - Transport

enum RemoteImageFetchError: Error, Equatable {
    case notAllowedURL
    case privateAddress
    case badStatus
    case redirected
    case notAnImage
    case tooLarge
}

/// The network under `RemoteImageFetcher`; tests drive the real streaming
/// transport through a stub `URLProtocol`, or replace it outright.
struct RemoteImageTransport: Sendable {
    /// Fetch at most `maxBytes + 1` bytes of the body; a declared larger
    /// body is not read. Redirects are the transport's to police.
    var fetch: @Sendable (_ request: URLRequest, _ maxBytes: Int) async throws -> (Data, URLResponse)
    /// DNS for the private-address check.
    var resolve: @Sendable (String) async -> [[UInt8]]?

    static let live = streaming(session: RemoteImageSession.session,
                                resolve: RemoteImageHostPolicy.resolveLive)

    static func streaming(session: URLSession,
                          resolve: @escaping @Sendable (String) async -> [[UInt8]]?)
        -> RemoteImageTransport {
        RemoteImageTransport(fetch: { request, maxBytes in
            let guardian = RemoteImageRedirectGuard(resolve: resolve)
            let (bytes, response) = try await session.bytes(for: request, delegate: guardian)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                bytes.task.cancel()
                return (Data(), response)
            }
            if response.expectedContentLength > Int64(maxBytes) {
                bytes.task.cancel()
                return (Data(), response)
            }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes {
                    bytes.task.cancel()
                    break
                }
            }
            return (data, response)
        }, resolve: resolve)
    }
}

/// Ephemeral: no cache, no cookies, no credentials, no proxy-auth prompts.
enum RemoteImageSession {
    static let session = makeSession(configuration: configuration())

    static func makeSession(configuration: URLSessionConfiguration) -> URLSession {
        URLSession(configuration: configuration, delegate: RemoteImageSessionDelegate(),
                   delegateQueue: nil)
    }

    static func configuration(
        requestTimeout: TimeInterval = RemoteImageFetchPolicy.requestTimeout,
        resourceTimeout: TimeInterval = RemoteImageFetchPolicy.resourceTimeout
    ) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.httpMaximumConnectionsPerHost = RemoteImageFetchPolicy.concurrency
        return config
    }
}

/// Session delegate: refuses every redirect and every credential challenge
/// (the per-task guard decides redirects; this is the fallback).
final class RemoteImageSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition,
                                                  URLCredential?) -> Void) {
        RemoteImageRedirectGuard.answer(challenge, completionHandler)
    }
}

/// Per-request delegate: follows at most `maxRedirects` redirects, each
/// only when the new URL passes the same rules (https, default port, no
/// user info, a public host after DNS). The new request is rebuilt from
/// scratch, so no header of the old one (or a Referer) carries over.
final class RemoteImageRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let resolve: @Sendable (String) async -> [[UInt8]]?
    private let lock = NSLock()
    private var hops = 0

    init(resolve: @escaping @Sendable (String) async -> [[UInt8]]?) {
        self.resolve = resolve
    }

    /// Redirects followed so far.
    var redirectCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return hops
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        hops += 1
        let count = hops
        lock.unlock()
        guard count <= RemoteImageFetchPolicy.maxRedirects, let url = request.url,
              RemoteImageFetchPolicy.isAllowedRequestURL(url), let host = url.host else {
            completionHandler(nil)
            return
        }
        let resolve = resolve
        let handler = UncheckedHandler(completionHandler)
        Task.detached {
            let ok = await RemoteImageHostPolicy.hostIsReachable(host, resolve: resolve)
            handler.call(ok ? RemoteImageFetchPolicy.request(for: url) : nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition,
                                                  URLCredential?) -> Void) {
        Self.answer(challenge, completionHandler)
    }

    /// Server trust is checked by the system as usual; anything asking for a
    /// credential (HTTP auth, client certificates) is refused.
    static func answer(_ challenge: URLAuthenticationChallenge,
                       _ completionHandler: (URLSession.AuthChallengeDisposition,
                                             URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    private final class UncheckedHandler: @unchecked Sendable {
        let body: (URLRequest?) -> Void
        init(_ body: @escaping (URLRequest?) -> Void) { self.body = body }
        func call(_ request: URLRequest?) { body(request) }
    }
}

// MARK: - Fetcher

/// One image fetched and checked.
struct FetchedRemoteImage: Equatable, Sendable {
    var url: String
    /// Sniffed by ImageIO, never the server's label.
    var mimeType: String
    var data: Data
}

enum RemoteImageFetcher {
    /// Downloads one image and checks it. Never logs. Call off the main
    /// actor (the ImageIO header read happens here).
    static func fetch(_ urlString: String,
                      transport: RemoteImageTransport) async throws -> FetchedRemoteImage {
        guard let url = URL(string: urlString),
              RemoteImageFetchPolicy.isAllowedRequestURL(url),
              let host = url.host else {
            throw RemoteImageFetchError.notAllowedURL
        }
        guard await RemoteImageHostPolicy.hostIsReachable(host, resolve: transport.resolve) else {
            throw RemoteImageFetchError.privateAddress
        }
        let (data, response) = try await transport.fetch(
            RemoteImageFetchPolicy.request(for: url), RemoteImageFetchPolicy.maxImageBytes)
        guard let http = response as? HTTPURLResponse else { throw RemoteImageFetchError.badStatus }
        if (300..<400).contains(http.statusCode) { throw RemoteImageFetchError.redirected }
        guard http.statusCode == 200 else { throw RemoteImageFetchError.badStatus }
        // Where the bytes came from must pass the rules too (a redirect the
        // guard let through was re-checked; this is belt and braces).
        if let answered = http.url {
            guard RemoteImageFetchPolicy.isAllowedRequestURL(answered) else {
                throw RemoteImageFetchError.redirected
            }
        }
        if http.expectedContentLength > Int64(RemoteImageFetchPolicy.maxImageBytes)
            || data.count > RemoteImageFetchPolicy.maxImageBytes {
            throw RemoteImageFetchError.tooLarge
        }
        guard RemoteImageFetchPolicy.acceptsResponseMIME(http.mimeType),
              let mime = RemoteImageFetchPolicy.sniffedMIME(data) else {
            throw RemoteImageFetchError.notAnImage
        }
        return FetchedRemoteImage(url: urlString, mimeType: mime, data: data)
    }

    /// Fetches `urls` with at most `RemoteImageFetchPolicy.concurrency` in
    /// flight. Returns the successes by URL; failures are simply absent.
    /// Stops starting new requests when the task is cancelled.
    static func fetchAll(_ urls: [String],
                         transport: RemoteImageTransport) async -> [String: FetchedRemoteImage] {
        await withTaskGroup(of: FetchedRemoteImage?.self,
                            returning: [String: FetchedRemoteImage].self) { group in
            var out: [String: FetchedRemoteImage] = [:]
            var next = 0
            while next < urls.count, next < RemoteImageFetchPolicy.concurrency {
                let url = urls[next]
                group.addTask { try? await fetch(url, transport: transport) }
                next += 1
            }
            while let result = await group.next() {
                if let image = result { out[image.url] = image }
                if next < urls.count, !Task.isCancelled {
                    let url = urls[next]
                    group.addTask { try? await fetch(url, transport: transport) }
                    next += 1
                }
            }
            return out
        }
    }
}
