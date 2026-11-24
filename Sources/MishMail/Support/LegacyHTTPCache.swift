import Foundation

/// The on-disk HTTP cache of `URLCache.shared`, where earlier builds let
/// Gmail responses land (`Cache.db`, an SQLite file, and `fsCachedData`
/// for large bodies, in the app's Caches folder). Google requests now go
/// through `GoogleHTTP.session`, which has no cache; this keeps the shared
/// cache off the disk too and deletes what earlier builds stored.
/// `removeAllCachedResponses` would only have deleted rows: the file keeps
/// its size and its freed pages.
enum LegacyHTTPCache {
    /// What `URLCache` keeps in its folder.
    static let fileNames = ["Cache.db", "Cache.db-wal", "Cache.db-shm", "fsCachedData"]

    /// A shared cache that never writes to disk.
    static func makeDiskless() -> URLCache {
        URLCache(memoryCapacity: 4 << 20, diskCapacity: 0, directory: nil)
    }

    /// Makes the shared cache diskless, then deletes the legacy files.
    /// Every launch, before the first request: a no-op once they are gone.
    static func retire(cachesDirectory: URL? = defaultDirectory) {
        URLCache.shared = makeDiskless()
        if let cachesDirectory { removeFiles(in: cachesDirectory) }
    }

    /// `~/Library/Caches/<bundle id>` (inside the container when sandboxed).
    static var defaultDirectory: URL? {
        guard let bundleId = Bundle.main.bundleIdentifier,
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        return caches.appendingPathComponent(bundleId, isDirectory: true)
    }

    /// Deletes the cache's files in `directory`, nothing else.
    static func removeFiles(in directory: URL) {
        for name in fileNames {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
