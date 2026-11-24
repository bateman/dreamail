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
    /// Nil when Google gave no usable photo: the initial disc stays.
    var imageData: Data?
    /// Last refresh attempt that finished, successful or not. Drives the
    /// refresh interval, so a photo host that keeps failing is not asked
    /// again on every sync.
    var fetchedAt: Date
    /// The last attempt failed (network, refused response). With no image
    /// stored, the next attempt comes sooner (`failureRetryInterval`).
    var lastAttemptFailed: Bool = false
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
    /// The stored PNG is refused past this size (a 56 px sRGB PNG is a few
    /// kilobytes).
    static let maxStoredBytes = 64 * 1024

    static let refreshInterval: TimeInterval = 24 * 60 * 60
    /// Retry sooner after a failure when there is no photo to show yet.
    static let failureRetryInterval: TimeInterval = 60 * 60

    static let acceptedMIMETypes: Set<String> = ["image/jpeg", "image/png", "image/webp"]
    static let acceptedImageTypes: Set<String> = [
        UTType.jpeg.identifier, UTType.png.identifier, UTType.webP.identifier,
    ]

    /// The URL to fetch, or nil when there is nothing to fetch from a host
    /// we trust. Anything else counts as "no photo".
    static func validatedURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty, let url = URL(string: raw),
              isAllowedRequestURL(url), !isDefaultSilhouette(url) else { return nil }
        return url
    }

    /// https only, an allowlisted host spelled plainly (no percent escapes),
    /// the default port, no user info.
    static func isAllowedRequestURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let encodedHost = components.percentEncodedHost, !encodedHost.contains("%"),
              allowedHosts.contains(encodedHost.lowercased()),
              components.port == nil || components.port == 443,
              components.user == nil, components.password == nil
        else { return false }
        return true
    }

    /// Legacy Google+ default silhouette, recognisable by its fixed path.
    /// Accounts without a photo now usually get a generated letter image,
    /// which cannot be told apart by URL and is shown as Google returns it.
    static func isDefaultSilhouette(_ url: URL) -> Bool {
        url.path.contains("/AAAAAAAAAAI/AAAAAAAAAAA/")
    }

    /// When the next refresh is due after `record`.
    static func nextDue(after record: AccountPhotoRecord?) -> Date? {
        guard let record else { return nil }
        let wait = record.lastAttemptFailed && record.imageData == nil
            ? failureRetryInterval : refreshInterval
        return record.fetchedAt.addingTimeInterval(wait)
    }

    /// Due when never fetched, when the interval has passed, or when the
    /// clock went backwards past the last attempt.
    static func isDue(_ record: AccountPhotoRecord?, now: Date) -> Bool {
        guard let record, let due = nextDue(after: record) else { return true }
        return now >= due || now < record.fetchedAt
    }

    /// The request for the image host: no token, no cookies, no cache.
    static func imageRequest(for url: URL) -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                             timeoutInterval: 20)
        req.httpShouldHandleCookies = false
        req.setValue("image/jpeg, image/png, image/webp", forHTTPHeaderField: "Accept")
        return req
    }

    /// Decode defensively, downscale to `maxPixelSize`, and redraw into a
    /// fresh 8-bit sRGB bitmap so no source color profile or metadata
    /// survives. Returns PNG data, or nil for anything that is not exactly
    /// one sane JPEG/PNG/WebP frame.
    static func normalizedImage(from data: Data) -> Data? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, opts),
              let type = CGImageSourceGetType(source) as String?,
              acceptedImageTypes.contains(type),
              CGImageSourceGetCount(source) == 1,
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
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts),
              thumb.width > 0, thumb.height > 0,
              thumb.width <= maxPixelSize, thumb.height <= maxPixelSize,
              let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: thumb.width, height: thumb.height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: thumb.width, height: thumb.height))
        guard let clean = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, clean, nil)
        guard CGImageDestinationFinalize(dest), out.length <= maxStoredBytes else { return nil }
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
    /// Fetch at most `maxBytes + 1` bytes of the body. A body declared
    /// larger than that is not read at all (empty data comes back, and the
    /// fetcher refuses the declared length).
    var fetch: @Sendable (_ request: URLRequest, _ maxBytes: Int) async throws -> (Data, URLResponse)

    static let live = streaming(session: AccountPhotoSession.session)

    static func streaming(session: URLSession) -> AccountPhotoTransport {
        AccountPhotoTransport { request, maxBytes in
            // The refuser as the per-task delegate too, so no redirect is
            // followed whatever the session's own delegate is.
            let (bytes, response) = try await session.bytes(
                for: request, delegate: AccountPhotoSession.delegate)
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
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
        }
    }
}

/// A session of its own for the image host: ephemeral, no cache, no
/// cookies, no credentials, and no redirects followed.
enum AccountPhotoSession {
    static let delegate = AccountPhotoRedirectRefuser()
    static let session = makeSession(configuration: configuration)

    static func makeSession(configuration: URLSessionConfiguration) -> URLSession {
        URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

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
    /// Downloads and normalizes the photo at `url`. Returns PNG data.
    static func fetch(_ url: URL, transport: AccountPhotoTransport) async throws -> Data {
        // Checked here too, not only by the caller.
        guard AccountPhotoPolicy.isAllowedRequestURL(url) else {
            throw AccountPhotoError.notAllowedURL
        }
        let (data, response) = try await transport.fetch(
            AccountPhotoPolicy.imageRequest(for: url), AccountPhotoPolicy.maxBytes)
        guard let http = response as? HTTPURLResponse else { throw AccountPhotoError.badStatus }
        if (300..<400).contains(http.statusCode) { throw AccountPhotoError.redirected }
        guard http.statusCode == 200 else { throw AccountPhotoError.badStatus }
        // The response must come from where we asked (no redirect followed).
        let answered = http.url ?? url
        guard AccountPhotoPolicy.isAllowedRequestURL(answered),
              answered.host?.lowercased() == url.host?.lowercased() else {
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

/// One running refresh, so the app can cancel it (quit, account removal)
/// and tell it from a later one.
struct AccountPhotoRefreshHandle {
    let id: UUID
    let task: Task<Void, Never>
}

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
        case cancelled
    }

    struct Result: Equatable {
        var outcome: Outcome
        /// When the caller should next ask; nil when it need not ask again
        /// (demo, removed account).
        var nextDue: Date?
    }

    /// `pictureURL` is asked only when a fetch is due; it is the `picture`
    /// of Google's userinfo response for this account.
    @discardableResult
    func refresh(accountId: String, force: Bool,
                 pictureURL: @Sendable () async throws -> String?) async -> Outcome {
        await refreshScheduling(accountId: accountId, force: force, pictureURL: pictureURL).outcome
    }

    func refreshScheduling(accountId: String, force: Bool,
                           pictureURL: @Sendable () async throws -> String?) async -> Result {
        guard !isDemo() else { return Result(outcome: .skippedDemo, nextDue: nil) }
        let last = try? await db.read { db in
            try AccountPhotoRecord.fetchOne(db, key: accountId)
        }
        if !force, !AccountPhotoPolicy.isDue(last, now: now()) {
            return Result(outcome: .notDue, nextDue: AccountPhotoPolicy.nextDue(after: last))
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
        // Quit or account removal cancels the task: write nothing then.
        guard !Task.isCancelled else { return Result(outcome: .cancelled, nextDue: nil) }
        let stamp = now()
        let record = AccountPhotoRecord(accountId: accountId, imageData: image,
                                        fetchedAt: stamp, lastAttemptFailed: failed)
        do {
            try await db.write { db in
                try AccountLifecycle.requireLiveAccount(db, id: accountId)
                if failed {
                    // Only the attempt is recorded: the stored image is never
                    // rewritten from what was read before the fetch.
                    try db.execute(
                        sql: """
                            UPDATE accountPhoto SET fetchedAt = ?, lastAttemptFailed = 1
                            WHERE accountId = ?
                            """,
                        arguments: [stamp, accountId])
                    if db.changesCount == 0 {
                        try record.insert(db, onConflict: .ignore)
                    }
                } else {
                    try record.save(db)
                }
            }
        } catch {
            return Result(outcome: .accountGone, nextDue: nil)
        }
        let after = try? await db.read { db in
            try AccountPhotoRecord.fetchOne(db, key: accountId)
        }
        return Result(outcome: failed ? .failed : .stored(hasPhoto: image != nil),
                      nextDue: AccountPhotoPolicy.nextDue(after: after ?? record))
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
