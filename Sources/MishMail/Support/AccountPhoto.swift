import Foundation
import GRDB
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

// MARK: - Storage

/// The signed-in account's own Google profile photo, downscaled and
/// re-encoded as PNG, kept with the account in the encrypted database. Goes
/// with the account row (foreign key cascade, and `purgeAccount` deletes it
/// explicitly). Never written anywhere else: no file, no HTTP cache.
struct AccountPhotoRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "accountPhoto"
    var accountId: String
    /// Nil when the account has no photo (or Google's default silhouette):
    /// the initial disc stays.
    var imageData: Data?
    /// Last refresh attempt that finished, successful or not. Drives the
    /// once-a-day interval, so a photo host that keeps failing is not asked
    /// again on every sync.
    var fetchedAt: Date
}

// MARK: - Policy

enum AccountPhotoPolicy {
    /// Google's profile-photo hosts. Exact names: no suffix match, so a
    /// look-alike such as `lh3.googleusercontent.com.example` is refused.
    static let allowedHosts: Set<String> = [
        "lh3.googleusercontent.com",
        "lh4.googleusercontent.com",
        "lh5.googleusercontent.com",
        "lh6.googleusercontent.com",
    ]

    /// Largest point size an account avatar is drawn at (sidebar header).
    static let maxPointSize: CGFloat = 28
    /// Retina pixels for `maxPointSize`.
    static var maxPixelSize: Int { Int(maxPointSize * 2) }

    /// The image response is refused past this many bytes.
    static let maxBytes = 1_000_000
    /// A decoded image larger than this on either side is refused before
    /// it is downscaled (a small PNG can declare a huge canvas).
    static let maxSourceDimension = 4096

    static let refreshInterval: TimeInterval = 24 * 60 * 60

    static let acceptedMIMETypes: Set<String> = ["image/jpeg", "image/png", "image/webp"]
    static let acceptedImageTypes: Set<String> = [
        UTType.jpeg.identifier, UTType.png.identifier, UTType.webP.identifier,
    ]

    /// The URL to fetch, or nil when there is nothing to fetch from a host
    /// we trust: https only, an allowlisted host, the default port, no user
    /// info. Anything else counts as "no photo".
    static func validatedURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty,
              let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              allowedHosts.contains(host),
              components.port == nil || components.port == 443,
              components.user == nil, components.password == nil,
              let url = components.url
        else { return nil }
        guard !isDefaultSilhouette(url) else { return nil }
        return url
    }

    /// Legacy Google+ default silhouette, recognisable by its fixed path.
    /// Newer "no photo" avatars (a generated letter) are not distinguishable
    /// by URL and are shown as Google returns them.
    static func isDefaultSilhouette(_ url: URL) -> Bool {
        url.path.contains("/AAAAAAAAAAI/AAAAAAAAAAA/")
    }

    static func isAllowedResponseURL(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return false }
        return allowedHosts.contains(host)
    }

    /// Due when never fetched, when the last attempt is a day old, or when
    /// the clock went backwards past it.
    static func isDue(lastFetchedAt: Date?, now: Date) -> Bool {
        guard let last = lastFetchedAt else { return true }
        let age = now.timeIntervalSince(last)
        return age >= refreshInterval || age < 0
    }

    /// The request for the image host: no token, no cookies, no cache.
    static func imageRequest(for url: URL) -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                             timeoutInterval: 20)
        req.httpShouldHandleCookies = false
        req.setValue("image/jpeg, image/png, image/webp", forHTTPHeaderField: "Accept")
        return req
    }

    /// Decode defensively and downscale to `maxPixelSize`; returns PNG data.
    /// Nil for anything that is not a single sane JPEG/PNG/WebP image.
    static func normalizedImage(from data: Data) -> Data? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, opts),
              let type = CGImageSourceGetType(source) as String?,
              acceptedImageTypes.contains(type),
              CGImageSourceGetCount(source) >= 1,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              width <= maxSourceDimension, height <= maxSourceDimension
        else { return nil }
        let thumbOpts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts) else {
            return nil
        }
        // Re-encode: what is stored is our own PNG, with no metadata from
        // the original file.
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

// MARK: - Fetching

enum AccountPhotoError: Error, Equatable {
    case notAllowedURL
    case badStatus
    case redirected
    case notAnImage
    case tooLarge
    case undecodable
}

/// The network under `AccountPhotoFetcher`; tests replace it.
struct AccountPhotoTransport: Sendable {
    /// Fetch at most `maxBytes + 1` bytes of the body.
    var fetch: @Sendable (_ request: URLRequest, _ maxBytes: Int) async throws -> (Data, URLResponse)

    static let live = AccountPhotoTransport { request, maxBytes in
        let (bytes, response) = try await AccountPhotoSession.session.bytes(for: request)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            return (Data(), response)
        }
        if response.expectedContentLength > Int64(maxBytes) {
            return (Data(count: maxBytes + 1), response)
        }
        var data = Data()
        data.reserveCapacity(min(Int(max(response.expectedContentLength, 0)), maxBytes + 1))
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes { break }
        }
        return (data, response)
    }
}

/// A session of its own for the image host: ephemeral, no cache, no
/// cookies, no credentials, and no redirects followed.
enum AccountPhotoSession {
    static let delegate = AccountPhotoRedirectRefuser()
    static let session = URLSession(configuration: configuration, delegate: delegate,
                                    delegateQueue: nil)

    static var configuration: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        return config
    }
}

/// Refuses every redirect: the 3xx itself comes back as the response and the
/// fetcher rejects it. Google serves the photo directly from the URL it
/// gives, so a redirect is never needed.
final class AccountPhotoRedirectRefuser: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum AccountPhotoFetcher {
    /// Downloads and normalizes the photo at `url` (already validated with
    /// `AccountPhotoPolicy.validatedURL`). Returns PNG data.
    static func fetch(_ url: URL, transport: AccountPhotoTransport) async throws -> Data {
        guard AccountPhotoPolicy.isAllowedResponseURL(url) else {
            throw AccountPhotoError.notAllowedURL
        }
        let (data, response) = try await transport.fetch(
            AccountPhotoPolicy.imageRequest(for: url), AccountPhotoPolicy.maxBytes)
        guard let http = response as? HTTPURLResponse else { throw AccountPhotoError.badStatus }
        if (300..<400).contains(http.statusCode) { throw AccountPhotoError.redirected }
        guard http.statusCode == 200 else { throw AccountPhotoError.badStatus }
        // The response must come from where we asked (no redirect followed).
        guard AccountPhotoPolicy.isAllowedResponseURL(http.url ?? url),
              (http.url ?? url).host?.lowercased() == url.host?.lowercased() else {
            throw AccountPhotoError.redirected
        }
        if http.expectedContentLength > Int64(AccountPhotoPolicy.maxBytes)
            || data.count > AccountPhotoPolicy.maxBytes {
            throw AccountPhotoError.tooLarge
        }
        let mime = (http.mimeType ?? "").lowercased()
        guard AccountPhotoPolicy.acceptedMIMETypes.contains(mime) else {
            throw AccountPhotoError.notAnImage
        }
        guard let png = AccountPhotoPolicy.normalizedImage(from: data) else {
            throw AccountPhotoError.undecodable
        }
        return png
    }
}

// MARK: - Refresh

/// Decides when to fetch, fetches, and stores. Failures are silent: the
/// stored photo (or the initial disc) stays. Nothing here logs.
struct AccountPhotoRefresher: Sendable {
    var db: any DatabaseWriter
    var transport: AccountPhotoTransport = .live
    var isDemo: @Sendable () -> Bool
    var now: @Sendable () -> Date = { Date() }

    enum Outcome: Equatable {
        case skippedDemo
        case notDue
        case stored(hasPhoto: Bool)
        case failed
        case accountGone
    }

    /// `pictureURL` is asked only when a fetch is due; it is the `picture`
    /// of Google's userinfo response for this account.
    @discardableResult
    func refresh(accountId: String, force: Bool,
                 pictureURL: @Sendable () async throws -> String?) async -> Outcome {
        guard !isDemo() else { return .skippedDemo }
        let last = try? await db.read { db in
            try AccountPhotoRecord.fetchOne(db, key: accountId)
        }
        if !force, !AccountPhotoPolicy.isDue(lastFetchedAt: last?.fetchedAt, now: now()) {
            return .notDue
        }
        var image: Data?
        var failed = false
        do {
            if let url = AccountPhotoPolicy.validatedURL(try await pictureURL()) {
                image = try await AccountPhotoFetcher.fetch(url, transport: transport)
            }
        } catch {
            failed = true
        }
        // A failure keeps the photo already stored; only a clear answer
        // ("no photo", or a new photo) replaces it.
        let record = AccountPhotoRecord(
            accountId: accountId,
            imageData: failed ? last?.imageData : image,
            fetchedAt: now())
        do {
            try await db.write { db in
                try AccountLifecycle.requireLiveAccount(db, id: accountId)
                try record.save(db)
            }
        } catch {
            return .accountGone
        }
        return failed ? .failed : .stored(hasPhoto: image != nil)
    }

    /// Stored photos by account id.
    static func loadAll(_ db: Database) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for row in try AccountPhotoRecord.fetchAll(db) {
            if let data = row.imageData { out[row.accountId] = data }
        }
        return out
    }
}
