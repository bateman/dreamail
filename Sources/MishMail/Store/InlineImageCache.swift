import CryptoKit
import Foundation
import GRDB

/// Inline (`cid:`) images of messages, kept in the encrypted database so a
/// conversation whose images were resolved once paints them at once on a
/// later open, after a relaunch too, with no Gmail attachment request.
///
/// What is stored: the bytes of each image part a message's HTML references
/// as `src="cid:…"`, once per part (not the base64-inlined HTML: the reading
/// pane rebuilds that from the stored body and these bytes, off the main
/// actor). Remote (http/https) images are never stored here.
///
/// Key: the part's attachment row (`attachmentId`, unique and never reused:
/// the column is AUTOINCREMENT) plus its message, account, Content-ID and a
/// digest of the body it was resolved from. A sender chooses Content-IDs, so
/// a Content-ID alone is never a key: a lookup only returns rows of the asked
/// message and account whose attachment row still carries that Content-ID.
///
/// Deleted means gone: every row cascades with its attachment row, its
/// message and its account, so whatever deletes those (a sync delete, a
/// local prune, a discarded draft, an account removal, a content re-fetch
/// that rewrites the attachment rows) deletes the images too, under the
/// same `secure_delete` and WAL scrub as the rest of the mail. The paths that
/// purge message content also delete these rows by name.
///
/// Bounded: `totalBudgetBytes` overall, least recently used message first,
/// and `perMessageBytes` per message.
enum InlineImageCache {
    static let tableName = "inlineImage"

    /// Total image bytes kept. Eviction removes whole messages, least
    /// recently used first, until the total is back under this.
    static let totalBudgetBytes = 200 * 1_024 * 1_024

    /// Image bytes of one message, together. The in-memory rule
    /// (`CIDInlineCachePolicy.maximumBytes`) caps the base64-inlined HTML at
    /// 4 MiB; base64 grows bytes by 4/3, so 3 MiB of images is what fits
    /// that cap. A larger message re-downloads its images, as before.
    static let perMessageBytes = 3 * 1_024 * 1_024

    struct Part: Equatable, Sendable {
        var attachmentId: Int64
        /// Normalized (`CIDImageInliner.normalize`).
        var contentId: String
        var mimeType: String
        var data: Data
    }

    /// One message's complete resolve result, waiting to be written.
    struct Pending: Equatable, Sendable {
        var messageId: String
        var accountId: String
        var bodyDigest: String
        var parts: [Part]
    }

    // MARK: Schema

    static func createTable(_ db: Database) throws {
        try db.create(table: tableName) { t in
            t.primaryKey("attachmentId", .integer)
                .references("attachment", onDelete: .cascade)
            t.column("messageId", .text).notNull().indexed()
                .references("message", onDelete: .cascade)
            t.column("accountId", .text).notNull().indexed()
                .references("account", onDelete: .cascade)
            t.column("bodyDigest", .text).notNull()
            t.column("contentId", .text).notNull()
            t.column("mimeType", .text).notNull()
            t.column("byteCount", .integer).notNull()
            t.column("lastUsedAt", .double).notNull().indexed()
            // Last: the small columns stay in the row's own page, so the
            // budget sum reads no image bytes and a "used" mark dirties only
            // that page, not the image's overflow pages.
            t.column("data", .blob).notNull()
        }
    }

    // MARK: Keys

    /// Content revision of a body: a body that changed no longer matches
    /// the images resolved from it.
    static func bodyDigest(_ html: String) -> String {
        SHA256.hash(data: Data(html.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: Reads

    /// Cached images of one message's current body, keyed by normalized
    /// Content-ID. Only rows of this message and account, resolved from this
    /// very body, whose attachment row still belongs to the message and still
    /// carries that Content-ID.
    static func parts(_ db: Database, messageId: String, accountId: String,
                      bodyHTML: String) throws -> [String: Part] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT i.attachmentId, i.contentId, i.mimeType, i.data,
                   a.contentId AS rowContentId
            FROM inlineImage i
            JOIN attachment a ON a.id = i.attachmentId AND a.messageId = i.messageId
            WHERE i.messageId = ? AND i.accountId = ? AND i.bodyDigest = ?
            """, arguments: [messageId, accountId, bodyDigest(bodyHTML)])
        var out: [String: Part] = [:]
        for row in rows {
            let cid: String = row["contentId"]
            guard let rowCID: String = row["rowContentId"],
                  CIDImageInliner.normalize(rowCID) == cid else { continue }
            out[cid] = Part(attachmentId: row["attachmentId"], contentId: cid,
                            mimeType: row["mimeType"], data: row["data"])
        }
        return out
    }

    /// For each message whose (hydrated) HTML references `cid:` images: its
    /// cached parts, only when every referenced image is cached. A partial
    /// set is never served: the pane resolves the message as usual instead.
    static func completeParts(_ db: Database,
                              for messages: [Message]) throws -> [String: [String: Part]] {
        var out: [String: [String: Part]] = [:]
        for message in messages {
            guard let html = message.bodyHTML,
                  CIDImageInliner.containsCIDReferences(html) else { continue }
            let refs = CIDImageInliner.referencedIDs(in: html)
            guard !refs.isEmpty else { continue }
            let found = try parts(db, messageId: message.id,
                                  accountId: message.accountId, bodyHTML: html)
            guard refs.isSubset(of: Set(found.keys)) else { continue }
            out[message.id] = found.filter { refs.contains($0.key) }
        }
        return out
    }

    /// Total image bytes stored.
    static func totalBytes(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(byteCount), 0) FROM inlineImage") ?? 0
    }

    // MARK: Writes

    /// Store one message's complete result, replacing what it had. Nothing
    /// is written unless everything still matches, checked in this
    /// transaction: the message (of that account) and its body as resolved,
    /// and every part's attachment row with its Content-ID. A message deleted
    /// or rewritten while the write waited is therefore never brought back.
    @discardableResult
    static func store(_ db: Database, _ pending: Pending, now: Date) throws -> Bool {
        guard !pending.parts.isEmpty,
              pending.parts.reduce(0, { $0 + $1.data.count }) <= perMessageBytes,
              try Bool.fetchOne(db, sql: """
                  SELECT 1 FROM message WHERE id = ? AND accountId = ?
                  """, arguments: [pending.messageId, pending.accountId]) == true,
              let html = try String.fetchOne(db, sql: """
                  SELECT bodyHTML FROM message_body WHERE messageId = ?
                  """, arguments: [pending.messageId]),
              bodyDigest(html) == pending.bodyDigest
        else { return false }
        for part in pending.parts {
            guard !part.data.isEmpty,
                  let rowCID = try String.fetchOne(db, sql: """
                      SELECT contentId FROM attachment WHERE id = ? AND messageId = ?
                      """, arguments: [part.attachmentId, pending.messageId]),
                  CIDImageInliner.normalize(rowCID) == part.contentId
            else { return false }
        }
        try forget(db, messageId: pending.messageId)
        let stamp = now.timeIntervalSinceReferenceDate
        for part in pending.parts {
            try db.execute(sql: """
                INSERT INTO inlineImage (attachmentId, messageId, accountId, bodyDigest,
                    contentId, mimeType, byteCount, lastUsedAt, data)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [part.attachmentId, pending.messageId, pending.accountId,
                                 pending.bodyDigest, part.contentId, part.mimeType,
                                 part.data.count, stamp, part.data])
        }
        return true
    }

    /// Marks messages' images as used now (least-recently-used order).
    static func touch(_ db: Database, messageIds: [String], now: Date) throws {
        let stamp = now.timeIntervalSinceReferenceDate
        for chunk in chunks(messageIds) {
            try db.execute(
                sql: "UPDATE inlineImage SET lastUsedAt = ? WHERE messageId IN (\(marks(chunk.count)))",
                arguments: StatementArguments([stamp]) + StatementArguments(chunk))
        }
    }

    /// Deletes whole messages, least recently used first, until the total is
    /// within `budget`. A real delete: `secure_delete` zeroes the bytes and
    /// the deletion schedules the WAL scrub. Returns the evicted message ids.
    @discardableResult
    static func evict(_ db: Database, budget: Int) throws -> [String] {
        var total = try totalBytes(db)
        guard total > budget else { return [] }
        let groups = try Row.fetchAll(db, sql: """
            SELECT messageId, SUM(byteCount) AS bytes, MAX(lastUsedAt) AS used
            FROM inlineImage GROUP BY messageId
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
                sql: "DELETE FROM inlineImage WHERE messageId IN (\(marks(chunk.count)))",
                arguments: StatementArguments(chunk))
        }
        return victims
    }

    static func forget(_ db: Database, messageId: String) throws {
        try db.execute(sql: "DELETE FROM inlineImage WHERE messageId = ?", arguments: [messageId])
    }

    static func forget(_ db: Database, account accountId: String) throws {
        try db.execute(sql: "DELETE FROM inlineImage WHERE accountId = ?", arguments: [accountId])
    }

    /// Rows whose account, message or attachment row is gone. The foreign
    /// keys already cascade; this is the launch sweep's belt and braces.
    static func purgeOrphans(_ db: Database) throws {
        try db.execute(sql: """
            DELETE FROM inlineImage
            WHERE accountId NOT IN (SELECT id FROM account)
               OR messageId NOT IN (SELECT id FROM message)
               OR attachmentId NOT IN (SELECT id FROM attachment)
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

/// Which resolve results may be written to the persistent cache. The same
/// rule as the in-memory `CIDInlineCachePolicy`: only a complete result, so
/// an image that failed to download is retried on the next open instead of
/// being frozen as a broken image.
enum InlineImageCachePolicy {
    static func shouldStore(references: Set<String>,
                            parts: [String: InlineImageCache.Part],
                            didRefetch: Bool) -> Bool {
        guard !didRefetch, !references.isEmpty,
              references.isSubset(of: Set(parts.keys)) else { return false }
        let used = parts.filter { references.contains($0.key) }
        guard used.values.allSatisfy({
            !$0.data.isEmpty && $0.attachmentId != CIDPartResolver.unsavedAttachmentId
        }) else { return false }
        return used.values.reduce(0) { $0 + $1.data.count } <= InlineImageCache.perMessageBytes
    }
}

/// Resolves the `cid:` image parts of one message: from the persistent cache
/// first, from Gmail (`fetch`) only for what the cache does not hold.
enum CIDPartResolver {
    struct Outcome: Sendable {
        /// Normalized Content-ID → part, for every reference resolved.
        var parts: [String: InlineImageCache.Part]
        /// How many parts came from `fetch` (an attachment request each).
        var fetchedCount: Int
    }

    /// `Part.attachmentId` of a part whose attachment row has no id.
    static let unsavedAttachmentId: Int64 = 0

    /// A cached part is used only for the attachment row it was stored for.
    /// Non-image parts are skipped (never fetched, never stored).
    static func resolve(
        references: Set<String>,
        attachmentsByCID: [String: AttachmentRow],
        cached: [String: InlineImageCache.Part],
        fetch: @Sendable (AttachmentRow) async throws -> Data
    ) async -> Outcome {
        var out = Outcome(parts: [:], fetchedCount: 0)
        for cid in references.sorted() {
            guard let att = attachmentsByCID[cid],
                  att.mimeType.lowercased().hasPrefix("image/") else { continue }
            // A just-parsed row whose write did not land has no id yet: it
            // still resolves, but can neither hit nor be stored.
            let attachmentId = att.id ?? unsavedAttachmentId
            if let hit = cached[cid], att.id != nil, hit.attachmentId == attachmentId,
               !hit.data.isEmpty {
                out.parts[cid] = hit
                continue
            }
            guard !Task.isCancelled else { break }
            out.fetchedCount += 1
            do {
                let data = try await fetch(att)
                guard !data.isEmpty else { continue }
                out.parts[cid] = InlineImageCache.Part(
                    attachmentId: attachmentId, contentId: cid,
                    mimeType: att.mimeType, data: data)
            } catch {
                // Left unresolved; the other images can still load.
                continue
            }
        }
        return out
    }
}

/// Owns the writes to the persistent inline-image cache: batched, off the
/// main actor, and stopped cleanly at quit.
///
/// Results and "used" marks queue here and go to the database together in
/// one write transaction, `flushDelay` after the first of them. Each
/// transaction is atomic, so a quit or crash during a write leaves either
/// all of it or none of it. `shutDown` (called by the app's termination
/// path before the pool closes) drops what is queued, cancels the pending
/// or running write (GRDB rolls a cancelled write back) and awaits it.
actor InlineImageStore {
    private let db: any DatabaseWriter
    private let budget: Int
    private let flushDelayNanoseconds: UInt64
    private let now: @Sendable () -> Date
    private var pendingStores: [String: InlineImageCache.Pending] = [:]
    private var pendingTouches: Set<String> = []
    /// Sleeping until the next batched write.
    private var timerTask: Task<Void, Never>?
    /// The write transaction in flight, if any.
    private var writeTask: Task<Void, Never>?
    private var isClosed = false

    init(db: any DatabaseWriter,
         budget: Int = InlineImageCache.totalBudgetBytes,
         flushDelayNanoseconds: UInt64 = 750_000_000,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.db = db
        self.budget = budget
        self.flushDelayNanoseconds = flushDelayNanoseconds
        self.now = now
    }

    /// Cached images of one message's current body (see
    /// `InlineImageCache.parts`). Empty on any error: a miss, never a failure.
    nonisolated func cachedParts(messageId: String, accountId: String,
                                 bodyHTML: String) async -> [String: InlineImageCache.Part] {
        (try? await db.read { db in
            try InlineImageCache.parts(db, messageId: messageId,
                                       accountId: accountId, bodyHTML: bodyHTML)
        }) ?? [:]
    }

    /// Queue a complete resolve result. The caller checked
    /// `InlineImageCachePolicy`; the write checks again that the message,
    /// body and attachment rows are still the ones it was resolved from.
    func remember(messageId: String, accountId: String, bodyHTML: String,
                  parts: [InlineImageCache.Part]) {
        guard !isClosed else { return }
        pendingStores[messageId] = InlineImageCache.Pending(
            messageId: messageId, accountId: accountId,
            bodyDigest: InlineImageCache.bodyDigest(bodyHTML),
            parts: parts.sorted { $0.attachmentId < $1.attachmentId })
        scheduleFlush()
    }

    /// Mark messages whose images were just served from the cache.
    func noteUsed(_ messageIds: [String]) {
        guard !isClosed, !messageIds.isEmpty else { return }
        pendingTouches.formUnion(messageIds)
        scheduleFlush()
    }

    /// Write what is queued now instead of at the timer.
    func flush() async {
        timerTask?.cancel()
        timerTask = nil
        await write()
    }

    /// Stop for good: queued work is dropped, a pending or running write is
    /// cancelled (GRDB rolls a cancelled write back) and awaited. Call
    /// before the pool closes.
    func shutDown() async {
        isClosed = true
        pendingStores = [:]
        pendingTouches = []
        let timer = timerTask
        let running = writeTask
        timer?.cancel()
        running?.cancel()
        await timer?.value
        await running?.value
        timerTask = nil
        writeTask = nil
    }

    var queuedMessageCount: Int { pendingStores.count }

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

    /// One transaction for everything queued. Writes run one at a time.
    private func write() async {
        if let running = writeTask { await running.value }
        guard !isClosed, !pendingStores.isEmpty || !pendingTouches.isEmpty else { return }
        let stores = pendingStores.values.sorted { $0.messageId < $1.messageId }
        let touches = pendingTouches.subtracting(pendingStores.keys).sorted()
        pendingStores = [:]
        pendingTouches = []
        let stamp = now()
        let budget = budget
        let db = db
        // A failed or cancelled write rolls back as a whole; the results are
        // only a cache, so they are not queued again.
        let task = Task<Void, Never> {
            _ = try? await db.write { db in
                for pending in stores {
                    try InlineImageCache.store(db, pending, now: stamp)
                }
                try InlineImageCache.touch(db, messageIds: touches, now: stamp)
                try InlineImageCache.evict(db, budget: budget)
            }
        }
        writeTask = task
        await task.value
        if writeTask == task { writeTask = nil }
        if !pendingStores.isEmpty || !pendingTouches.isEmpty { scheduleFlush() }
    }
}
