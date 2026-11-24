import Foundation

/// The one HTTP session for Google's APIs: Gmail, the token endpoint and the
/// profile lookup. Nothing it fetches is written to disk.
///
/// `URLSession.shared` stores responses in the app's on-disk URL cache
/// (`Cache.db`, an SQLite file in Caches), and Gmail's responses — message
/// bodies, headers, attachments — are cacheable there (`Cache-Control:
/// private`). Clearing that cache later only unlinks its rows, so the mail
/// had to stay out of it in the first place. Nothing in the app relies on
/// the HTTP cache: sync asks for changes by history id, and the cache only
/// ever saved a revalidation round trip on a repeated identical GET.
enum GoogleHTTP {
    static let session = URLSession(configuration: configuration)

    static var configuration: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        // Ephemeral already keeps everything in memory; no cache at all
        // also keeps response bodies out of process memory after use.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Google's APIs authenticate with the bearer token, not cookies.
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        return config
    }
}
