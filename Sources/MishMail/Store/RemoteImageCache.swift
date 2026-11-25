import Foundation
import GRDB

/// Remote (https) images of messages whose remote images the user allowed,
/// kept in the encrypted database so a later open, after a relaunch too,
/// shows them with no request to the sender.
///
/// Only for a message that was opened with remote images allowed (by the
/// policy, a Load images click, or the conversation opt-in): nothing is ever
/// downloaded ahead of time. The neighbour pre-render and the prefetch read
/// this table only (`RemoteImageResolver.cachedBody`), never the network.
///
/// What is stored: one row per image URL of one message, the bytes as
/// served (raster only, checked by ImageIO; never SVG), the MIME type
/// sniffed from the bytes, the byte count and a "last used" mark. Not the
/// URL: only its SHA-256 (`RemoteImageHTML.urlKey`). Not the rewritten HTML:
/// that is rebuilt from the stored body and these bytes off the main actor.
///
/// Key: account + message + URL digest. Per message by design: the same
/// URL in two messages (or two accounts) is stored twice, so deleting one
/// message deletes exactly its images and nothing answers across messages
/// or accounts. No revalidation: mail does not change, so an image is used
/// until its message goes or it is evicted.
///
/// Deleted means gone: rows cascade with their message and account, so a
/// sync delete, a local prune, a discarded draft or an account removal
/// deletes them under the same `secure_delete` and WAL scrub as the mail.
/// Account removal also deletes them by name, and the launch sweep removes
/// orphans.
///
/// Bounded: `totalBudgetBytes` overall (its own budget, apart from the
/// inline-image cache), least recently used message first, and
/// `RemoteImageFetchPolicy.maxMessageBytes` per message.
enum RemoteImageCache {
    static let tableName = "remoteImage"

    /// Total remote image bytes kept. Separate from
    /// `InlineImageCache.totalBudgetBytes`: newsletters would otherwise
    /// evict the `cid:` images of personal mail (which cost a Gmail request
    /// each to get back), and each table's LRU stays a single-table query.
    static let totalBudgetBytes = 200 * 1_024 * 1_024

    /// A message's "last used" mark is refreshed at most this often.
    static let touchInterval: TimeInterval = 86_400

    struct Image: Equatable, Sendable {
        var urlKey: String
        var mimeType: String
        var data: Data
    }

    /// One message's newly fetched images and refusals, waiting to be
    /// written.
    struct Pending: Equatable, Sendable {
        var messageId: String
        var accountId: String
        var images: [Image]
        /// URL digests the app will not fetch again for this message (a rule
        /// refused them, the server answered with something unusable, or
        /// they fall past the message's byte cap). Stored as marker rows
        /// (empty `mimeType` and `data`, no URL), so the message can be
        /// complete and reopen from the cache; they go with the message.
        var refused: [String] = []
    }

    /// `mimeType` of a refusal marker row.
    static let refusedMarker = ""

    // MARK: Schema

    static func createTable(_ db: Database) throws {
        try db.create(table: tableName) { t in
            t.column("messageId", .text).notNull()
                .references("message", onDelete: .cascade)
            t.column("accountId", .text).notNull().indexed()
                .references("account", onDelete: .cascade)
            t.column("urlKey", .text).notNull()
            t.column("mimeType", .text).notNull()
            t.column("byteCount", .integer).notNull()
            t.column("lastUsedAt", .double).notNull()
            // Last: the small columns stay in the row's own page.
            t.column("data", .blob).notNull()
            t.primaryKey(["messageId", "accountId", "urlKey"])
        }
        // Covering index for the cascade from `message`, the budget sum and
        // the eviction's GROUP BY (same shape as `inlineImage`'s).
        try db.create(index: "remoteImage_on_messageId_lastUsedAt_byteCount",
                      on: tableName, columns: ["messageId", "lastUsedAt", "byteCount"])
    }

    /// Stored MIME types: the four raster types the fetcher accepts.
    static func isStorableMIME(_ mime: String) -> Bool {
        RemoteImageFetchPolicy.acceptedTypes.values.contains(mime)
    }

    // MARK: Reads

    /// The cached images of `messageId` (of `accountId`) among `urlKeys`.
    static func images(_ db: Database, messageId: String, accountId: String,
                       urlKeys: [String]) throws -> [String: Image] {
        guard !urlKeys.isEmpty else { return [:] }
        var out: [String: Image] = [:]
        for chunk in chunks(urlKeys) {
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT urlKey, mimeType, data FROM remoteImage
                    WHERE messageId = ? AND accountId = ? AND mimeType != ''
                      AND urlKey IN (\(marks(chunk.count)))
                    """,
                arguments: StatementArguments([messageId, accountId]) + StatementArguments(chunk))
            for row in rows {
                let mime: String = row["mimeType"]
                let data: Data = row["data"]
                guard isStorableMIME(mime), !data.isEmpty else { continue }
                let key: String = row["urlKey"]
                out[key] = Image(urlKey: key, mimeType: mime, data: data)
            }
        }
        return out
    }

    /// URL digests settled for one message (an image or a refusal marker):
    /// an index-only read (the primary key), no image bytes.
    static func storedKeys(_ db: Database, messageId: String, accountId: String) throws -> Set<String> {
        Set(try String.fetchAll(db, sql: """
            SELECT urlKey FROM remoteImage WHERE messageId = ? AND accountId = ?
            """, arguments: [messageId, accountId]))
    }

    /// URL digests with a refusal marker for one message.
    static func refusedKeys(_ db: Database, messageId: String, accountId: String) throws -> Set<String> {
        Set(try String.fetchAll(db, sql: """
            SELECT urlKey FROM remoteImage WHERE messageId = ? AND accountId = ? AND mimeType = ?
            """, arguments: [messageId, accountId, refusedMarker]))
    }

    static func totalBytes(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(byteCount), 0) FROM remoteImage") ?? 0
    }

    static func messageBytes(_ db: Database, messageId: String) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COALESCE(SUM(byteCount), 0) FROM remoteImage WHERE messageId = ?
            """, arguments: [messageId]) ?? 0
    }

    static func staleMessageIds(_ db: Database, _ messageIds: [String],
                                cutoff: Date) throws -> [String] {
        var out: [String] = []
        for chunk in chunks(messageIds) {
            out += try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT messageId FROM remoteImage
                    WHERE messageId IN (\(marks(chunk.count))) AND lastUsedAt < ?
                    """,
                arguments: StatementArguments(chunk)
                    + StatementArguments([cutoff.timeIntervalSinceReferenceDate]))
        }
        return out
    }

    // MARK: Writes

    /// Adds one message's newly fetched images. Nothing is written unless the
    /// message still exists under that account (checked in this transaction,
    /// so a message deleted while the write waited is never brought back).
    /// Images that would take the message past its cap are skipped. Returns
    /// how many rows were written.
    @discardableResult
    static func store(_ db: Database, _ pending: Pending, now: Date) throws -> Int {
        guard !pending.images.isEmpty || !pending.refused.isEmpty,
              try Bool.fetchOne(db, sql: """
                  SELECT 1 FROM message WHERE id = ? AND accountId = ?
                  """, arguments: [pending.messageId, pending.accountId]) == true
        else { return 0 }
        var used = try messageBytes(db, messageId: pending.messageId)
        let stamp = now.timeIntervalSinceReferenceDate
        var written = 0
        for image in pending.images {
            guard !image.data.isEmpty, isStorableMIME(image.mimeType),
                  image.data.count <= RemoteImageFetchPolicy.maxImageBytes else { continue }
            let existing = try Int.fetchOne(db, sql: """
                SELECT byteCount FROM remoteImage
                WHERE messageId = ? AND accountId = ? AND urlKey = ?
                """, arguments: [pending.messageId, pending.accountId, image.urlKey])
            if existing != nil { continue }
            guard used + image.data.count <= RemoteImageFetchPolicy.maxMessageBytes else { continue }
            try db.execute(sql: """
                INSERT INTO remoteImage (messageId, accountId, urlKey, mimeType, byteCount,
                    lastUsedAt, data)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [pending.messageId, pending.accountId, image.urlKey,
                                 image.mimeType, image.data.count, stamp, image.data])
            used += image.data.count
            written += 1
        }
        for key in pending.refused {
            try db.execute(sql: """
                INSERT OR IGNORE INTO remoteImage (messageId, accountId, urlKey, mimeType,
                    byteCount, lastUsedAt, data)
                VALUES (?, ?, ?, ?, 0, ?, ?)
                """, arguments: [pending.messageId, pending.accountId, key, refusedMarker,
                                 stamp, Data()])
        }
        if written > 0 {
            // The message's other images count as used now too.
            try db.execute(sql: "UPDATE remoteImage SET lastUsedAt = ? WHERE messageId = ?",
                           arguments: [stamp, pending.messageId])
        }
        return written
    }

    static func touch(_ db: Database, messageIds: [String], now: Date) throws {
        let stamp = now.timeIntervalSinceReferenceDate
        let cutoff = stamp - touchInterval
        for chunk in chunks(messageIds) {
            try db.execute(
                sql: """
                    UPDATE remoteImage SET lastUsedAt = ?
                    WHERE messageId IN (\(marks(chunk.count))) AND lastUsedAt < ?
                    """,
                arguments: StatementArguments([stamp]) + StatementArguments(chunk)
                    + StatementArguments([cutoff]))
        }
    }

    /// Deletes whole messages, least recently used first, until the total is
    /// within `budget`. Returns the evicted message ids.
    @discardableResult
    static func evict(_ db: Database, budget: Int) throws -> [String] {
        var total = try totalBytes(db)
        guard total > budget else { return [] }
        let groups = try Row.fetchAll(db, sql: """
            SELECT messageId, SUM(byteCount) AS bytes, MAX(lastUsedAt) AS used
            FROM remoteImage GROUP BY messageId
            ORDER BY used ASC, messageId ASC
            """)
        var victims: [String] = []
        for group in groups {
            guard total > budget else { break }
            victims.append(group["messageId"])
            total -= group["bytes"] as Int
        }
        for chunk in chunks(victims) {
            try db.execute(
                sql: "DELETE FROM remoteImage WHERE messageId IN (\(marks(chunk.count)))",
                arguments: StatementArguments(chunk))
        }
        return victims
    }

    static func forget(_ db: Database, account accountId: String) throws {
        try db.execute(sql: "DELETE FROM remoteImage WHERE accountId = ?", arguments: [accountId])
    }

    /// Every cached remote image (a "clear image cache" action).
    static func removeAll(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM remoteImage")
    }

    /// Rows whose account or message is gone (the launch sweep).
    static func purgeOrphans(_ db: Database) throws {
        try db.execute(sql: """
            DELETE FROM remoteImage
            WHERE accountId NOT IN (SELECT id FROM account)
               OR messageId NOT IN (SELECT id FROM message)
            """)
    }

    private static func chunks(_ ids: [String], size: Int = 500) -> [[String]] {
        stride(from: 0, to: ids.count, by: size).map {
            Array(ids[$0..<min($0 + size, ids.count)])
        }
    }

    private static func marks(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }
}

/// Owns the writes to the remote-image cache, with the same discipline as
/// `InlineImageStore`: batched `flushDelay` after the first result, one
/// transaction per stored message, then one for the "used" marks and the
/// eviction; `shutDown` (the app's termination path, before the pool
/// closes) drops what is queued and cancels and awaits a running write.
///
/// Refusals are stored too (`Pending.refused`), so a reopened message is
/// not asked for them again by the app; those images load live in the web
/// view as before. Network failures are not stored: they are retried.
actor RemoteImageStore {
    private let db: any DatabaseWriter
    private let budget: Int
    private let flushDelayNanoseconds: UInt64
    private let now: @Sendable () -> Date
    private var pendingStores: [String: RemoteImageCache.Pending] = [:]
    /// The batch being written: still answered by the reads until its
    /// transactions commit, so an image is never fetched again in between.
    private var writingStores: [String: RemoteImageCache.Pending] = [:]

    /// Queued or being written, for one message of one account.
    private func unwritten(_ messageId: String, _ accountId: String) -> [RemoteImageCache.Pending] {
        [pendingStores[messageId], writingStores[messageId]].compactMap { $0 }
            .filter { $0.accountId == accountId }
    }
    private var pendingTouches: Set<String> = []
    private var timerTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var isClosed = false

    private(set) var writeTransactionCount = 0
    private(set) var batchesStarted = 0
    private(set) var batchesFinished = 0

    init(db: any DatabaseWriter,
         budget: Int = RemoteImageCache.totalBudgetBytes,
         flushDelayNanoseconds: UInt64 = 750_000_000,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.db = db
        self.budget = budget
        self.flushDelayNanoseconds = flushDelayNanoseconds
        self.now = now
    }

    /// Cached images of one message among `urlKeys`: those still queued for
    /// writing first (so an image fetched a moment ago is never fetched
    /// again), then the database. A database error is a miss.
    func cachedImages(messageId: String, accountId: String,
                      urlKeys: [String]) async -> [String: RemoteImageCache.Image] {
        guard !urlKeys.isEmpty, !isClosed else { return [:] }
        var out: [String: RemoteImageCache.Image] = [:]
        let wanted = Set(urlKeys)
        for queued in unwritten(messageId, accountId) {
            for image in queued.images where wanted.contains(image.urlKey) {
                out[image.urlKey] = image
            }
        }
        let rest = urlKeys.filter { out[$0] == nil }
        guard !rest.isEmpty else { return out }
        let db = db
        let stored = (try? await db.read { db in
            try RemoteImageCache.images(db, messageId: messageId, accountId: accountId,
                                        urlKeys: rest)
        }) ?? [:]
        out.merge(stored) { queued, _ in queued }
        return out
    }

    /// URL digests this message has cached (queued or stored), without
    /// reading any image. Empty on any error.
    func storedKeys(messageId: String, accountId: String) async -> Set<String> {
        guard !isClosed else { return [] }
        var out: Set<String> = []
        for queued in unwritten(messageId, accountId) {
            out.formUnion(queued.images.map(\.urlKey))
            out.formUnion(queued.refused)
        }
        let db = db
        let stored = (try? await db.read { db in
            try RemoteImageCache.storedKeys(db, messageId: messageId, accountId: accountId)
        }) ?? []
        return out.union(stored)
    }

    /// Refused URL digests of one message (queued or stored).
    func refusedKeys(messageId: String, accountId: String) async -> Set<String> {
        var out = Set(unwritten(messageId, accountId).flatMap(\.refused))
        let db = db
        out.formUnion((try? await db.read { db in
            try RemoteImageCache.refusedKeys(db, messageId: messageId, accountId: accountId)
        }) ?? [])
        return out
    }

    func remember(_ pending: RemoteImageCache.Pending) {
        guard !isClosed, !pending.images.isEmpty || !pending.refused.isEmpty else { return }
        var merged = pendingStores[pending.messageId] ?? RemoteImageCache.Pending(
            messageId: pending.messageId, accountId: pending.accountId, images: [])
        guard merged.accountId == pending.accountId else { return }
        let known = Set(merged.images.map(\.urlKey))
        merged.images += pending.images.filter { !known.contains($0.urlKey) }
        let knownRefused = Set(merged.refused)
        merged.refused += pending.refused.filter { !knownRefused.contains($0) && !known.contains($0) }
        pendingStores[pending.messageId] = merged
        scheduleFlush()
    }

    /// Images the reading pane just showed from the cache. Prefetch and
    /// pre-render must not call this.
    func noteUsed(_ messageIds: [String]) {
        guard !isClosed, !messageIds.isEmpty else { return }
        pendingTouches.formUnion(messageIds)
        scheduleFlush()
    }

    /// "messageId|url" being fetched now.
    private var inFlight: Set<String> = []

    /// Of `urls`, those no other resolve of this message is fetching now,
    /// marked as in flight; the caller `release`s them when done.
    func claim(messageId: String, urls: [String]) -> [String] {
        urls.filter { inFlight.insert(messageId + "|" + $0).inserted }
    }

    func release(messageId: String, urls: [String]) {
        for url in urls { inFlight.remove(messageId + "|" + url) }
    }

    /// Deletes every cached remote image and refusal.
    func clearAll() async {
        pendingStores = [:]
        pendingTouches = []
        timerTask?.cancel()
        timerTask = nil
        while let running = writeTask {
            await running.value
            if writeTask == running { writeTask = nil }
        }
        writingStores = [:]
        guard !isClosed else { return }
        _ = try? await db.write { db in try RemoteImageCache.removeAll(db) }
    }

    func flush() async {
        timerTask?.cancel()
        timerTask = nil
        await write()
    }

    func shutDown() async {
        isClosed = true
        pendingStores = [:]
        pendingTouches = []
        let timer = timerTask
        timer?.cancel()
        await timer?.value
        timerTask = nil
        while let running = writeTask {
            running.cancel()
            await running.value
            if writeTask == running { writeTask = nil }
        }
        writingStores = [:]
    }

    var queuedMessageCount: Int { pendingStores.count }
    var isWriting: Bool { writeTask != nil }

    private func scheduleFlush() {
        guard timerTask == nil, !isClosed else { return }
        let delay = flushDelayNanoseconds
        timerTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            await self?.timerFired()
        }
    }

    private func timerFired() async {
        timerTask = nil
        await write()
    }

    private func countTransaction() { writeTransactionCount += 1 }
    private func batchDidFinish() { batchesFinished += 1 }

    private func write() async {
        while let running = writeTask {
            await running.value
            if writeTask == running { writeTask = nil }
        }
        guard !isClosed, !pendingStores.isEmpty || !pendingTouches.isEmpty else { return }
        let stores = pendingStores.values.sorted { $0.messageId < $1.messageId }
        let touches = pendingTouches.subtracting(pendingStores.keys).sorted()
        writingStores = pendingStores
        pendingStores = [:]
        pendingTouches = []
        let stamp = now()
        let budget = budget
        let db = db
        batchesStarted += 1
        let task = Task<Void, Never> { [weak self] in
            var stored = false
            for pending in stores {
                guard !Task.isCancelled else { break }
                await self?.countTransaction()
                let count = (try? await db.write { db in
                    try RemoteImageCache.store(db, pending, now: stamp)
                }) ?? 0
                stored = stored || count > 0
            }
            var stale: [String] = []
            if !touches.isEmpty, !Task.isCancelled {
                let cutoff = stamp.addingTimeInterval(-RemoteImageCache.touchInterval)
                stale = (try? await db.read { db in
                    try RemoteImageCache.staleMessageIds(db, touches, cutoff: cutoff)
                }) ?? []
            }
            if stored || !stale.isEmpty, !Task.isCancelled {
                await self?.countTransaction()
                let marks = stale
                _ = try? await db.write { db in
                    try RemoteImageCache.touch(db, messageIds: marks, now: stamp)
                    try RemoteImageCache.evict(db, budget: budget)
                }
            }
            await self?.batchDidFinish()
        }
        writeTask = task
        await task.value
        if writeTask == task { writeTask = nil }
        writingStores = [:]
        if !pendingStores.isEmpty || !pendingTouches.isEmpty { scheduleFlush() }
    }
}
